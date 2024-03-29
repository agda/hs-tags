{-# LANGUAGE CPP                      #-}
{-# LANGUAGE NondecreasingIndentation #-}
{-# LANGUAGE PatternSynonyms          #-}
{-# LANGUAGE ScopedTypeVariables      #-}

module Main where

import Control.Arrow ((&&&))
import Control.Exception
import Control.Monad
import Control.Monad.Trans
import Data.Char
import qualified Data.Traversable as T
import Data.List
import Data.Maybe
import Data.Version ( showVersion )
import System.Environment
import System.IO
import qualified System.IO.Strict as Strict
import System.Exit
import System.FilePath
import System.Directory
import System.Process
import System.Console.GetOpt

import qualified GHC.Paths as GHC

import GHC
  ( DynFlags
  , HsModule
  , Located
  , RealSrcLoc
  , includePaths
  , getSession
  , getSessionDynFlags
  , setSessionDynFlags
  , runGhc
  )
#if MIN_VERSION_ghc(8,4,0)
import GHC (GhcPs)
#else
import GHC (RdrName)
#endif

-- In ghc-9.0, hierarchical modules were introduced,
-- so most modules got renamed.
#if MIN_VERSION_ghc(9,0,0)

import GHC.Data.FastString   ( mkFastString )
import GHC.Data.StringBuffer ( hGetStringBuffer )
import GHC.Driver.Monad      ( GhcT(..), Ghc(..) )
import GHC.Driver.Phases     ( pattern Cpp, pattern HsSrcFile )
import GHC.Driver.Pipeline   ( preprocess )
import GHC.Driver.Session    ( includePathsGlobal, opt_P, parseDynamicFilePragma, sOpt_P, toolSettings )
import GHC.Parser            ( parseModule )
import GHC.Parser.Lexer      ( P(..), ParseResult(..), PState, mkPState, getErrorMessages )
import GHC.Settings          ( toolSettings_opt_P )
import GHC.Types.SrcLoc      ( mkRealSrcLoc, noLoc, unLoc )

-- THESE MODULES cannot be imported, it seems:
-- import GHC.Driver.Errors ( printBagOfErrors )
-- import GHC.Types.SourceError (throwErrors)
-- import GHC.Parser.Errors.Ppr (pprError)
-- import GHC.Utils.Error.ErrorMessages

#else

import DriverPhases   ( pattern Cpp, pattern HsSrcFile )
import DriverPipeline ( preprocess )
import DynFlags       ( opt_P, sOpt_P, settings, parseDynamicFilePragma )
import FastString     ( mkFastString )
import GhcMonad       ( GhcT(..), Ghc(..) )
import Lexer          ( P(..), ParseResult(..), PState, mkPState )
import Parser         ( parseModule )
import SrcLoc         ( mkRealSrcLoc, noLoc, unLoc )
import StringBuffer   ( hGetStringBuffer )

#if MIN_VERSION_ghc(8,6,1)
import DynFlags       ( includePathsGlobal )
#endif

#if MIN_VERSION_ghc(8,10,1)
import GHC            ( toolSettings )
import ToolSettings   ( toolSettings_opt_P )
import Lexer          ( getErrorMessages )
import ErrUtils       ( printBagOfErrors )
#else
import ErrUtils       ( mkPlainErrMsg )
#endif

#endif

import Language.Haskell.Extension as LHE
import Distribution.PackageDescription.Configuration (flattenPackageDescription)
import Distribution.PackageDescription hiding (options)
#if MIN_VERSION_Cabal(2,2,0)
import qualified Distribution.PackageDescription.Parsec as PkgDescParse
import Distribution.PackageDescription.Parsec hiding (ParseResult)
#else
import qualified Distribution.PackageDescription.Parse as PkgDescParse
import Distribution.PackageDescription.Parse hiding (ParseResult)
#endif

import Tags
import Paths_hs_tags ( version )

instance MonadTrans GhcT where
  lift m = GhcT $ const m

fileLoc :: FilePath -> RealSrcLoc
fileLoc file = mkRealSrcLoc (mkFastString file) 1 0

filePState :: DynFlags -> FilePath -> IO PState
filePState dflags file = do
  buf <- hGetStringBuffer file
  return $
    mkPState dflags buf (fileLoc file)


#if MIN_VERSION_ghc(9,0,0)
pMod :: P (Located HsModule)
#elif MIN_VERSION_ghc(8,4,0)
pMod :: P (Located (HsModule GhcPs))
#else
pMod :: P (Located (HsModule RdrName))
#endif
pMod = parseModule

parse :: PState -> P a -> ParseResult a
parse st p = unP p st

goFile :: FilePath -> Ghc [Tag]
goFile file = do
  liftIO $ hPutStrLn stderr $ "Processing " ++ file
  env <- getSession
#if MIN_VERSION_ghc(8,8,1)
  r <- liftIO $
       preprocess env file Nothing (Just $ Cpp HsSrcFile)
  let (dflags, srcFile) = case r of
                            Left _  -> error $ "preprocessing " ++ file
                            Right x -> x
#else
  (dflags, srcFile) <- liftIO $
      preprocess env (file, Just $ Cpp HsSrcFile)
#endif
  st <- liftIO $ filePState dflags srcFile
  case parse st pMod of
    POk _ m         -> return $ removeDuplicates $ tags $ unLoc m
#if MIN_VERSION_ghc(9,0,0)
    PFailed pState -> liftIO $ do
      -- Andreas, 2021-03-03, how can we print the errors with ghc-9.0?
      -- @printBagOfErrors@ does not seem to be exported,
      -- neither @pprError@...
      -- throwErrors $ fmap pprError $ getErrorMessages pState dflags
      hPutStrLn stderr "PARSE ERROR"
#elif MIN_VERSION_ghc(8,10,1)
    PFailed pState -> liftIO $ do
      printBagOfErrors dflags $ getErrorMessages pState dflags
#elif MIN_VERSION_ghc(8,4,0)
    PFailed _ loc err -> liftIO $ do
      print (mkPlainErrMsg dflags loc err)
#else
    PFailed loc err -> liftIO $ do
      print (mkPlainErrMsg dflags loc err)
#endif
      exitWith $ ExitFailure 1

runCmd :: String -> IO String
runCmd cmd = do
  (_, h, _, _) <- runInteractiveCommand cmd
  hGetContents h

-- XXX This is a quick hack; it will certainly work if the language description
-- is not conditional. Otherwise we'll need to figure out both the flags and the
-- build configuration to call `finalizePackageDescriptionSource`.
configurePackageDescription ::
  GenericPackageDescription -> PackageDescription
configurePackageDescription = flattenPackageDescription

extractLangSettings ::
  GenericPackageDescription
  -> ([Extension], Maybe LHE.Language)
extractLangSettings gpd =
  maybe ([], Nothing)
  ((defaultExtensions &&& defaultLanguage) . libBuildInfo)
  ((library . configurePackageDescription) gpd)

extToOpt :: Extension -> String
extToOpt (UnknownExtension e) = "-X" ++ e
extToOpt (EnableExtension e)  = "-X" ++ show e
extToOpt (DisableExtension e) = "-XNo" ++ show e

langToOpt :: LHE.Language -> String
langToOpt l = "-X" ++ show l

cabalConfToOpts :: GenericPackageDescription -> [String]
cabalConfToOpts desc = langOpts ++ extOpts
  where
    (exts, maybeLang) = extractLangSettings desc
    extOpts = map extToOpt exts
    langOpts = langToOpt <$> maybeToList maybeLang

usage :: IO ()
usage = do
    printUsage stdout
    exitSuccess

main :: IO ()
main = do
  opts <- getOptions
  if optHelp opts then usage else do

  let agdaReadPackageDescription =
#if MIN_VERSION_Cabal(2,0,0)
        readGenericPackageDescription
#else
        readPackageDescription
#endif

  pkgDesc <- T.mapM (agdaReadPackageDescription minBound) $ optCabalPath opts
  do
            ts <- runGhc (Just GHC.libdir) $ do
              dynFlags <- getSessionDynFlags
              let dynFlags' =
                    dynFlags {
#if MIN_VERSION_ghc(8,10,1)
                    toolSettings = (toolSettings dynFlags) {
                        toolSettings_opt_P = concatMap (\i -> [i, "-include"]) (optIncludes opts) ++
                                             opt_P dynFlags
                        }
#else
                    settings = (settings dynFlags) {
                        sOpt_P = concatMap (\i -> [i, "-include"]) (optIncludes opts) ++
                                 opt_P dynFlags
                        }
#endif

#if MIN_VERSION_ghc(8,6,1)
                    , includePaths =
                        let includeSpecs = includePaths dynFlags
                        in  includeSpecs { includePathsGlobal = optIncludePath opts ++ includePathsGlobal includeSpecs }
#else
                    , includePaths = optIncludePath opts ++ includePaths dynFlags
#endif
                    }
              (dynFlags'', _, _) <- parseDynamicFilePragma dynFlags' $ map noLoc $ concatMap cabalConfToOpts (maybeToList pkgDesc)
              setSessionDynFlags dynFlags''
              mapM (\f -> liftM2 ((,,) f) (liftIO $ Strict.readFile f)
                                          (goFile f)) $
                         optFiles opts
            when (optCTags opts) $
              let sts = sort $ concatMap (\(_, _, t) -> t) ts in
              writeFile (optCTagsFile opts) $ unlines $ map show sts
            when (optETags opts) $
              writeFile (optETagsFile opts) $ showETags ts

getOptions :: IO Options
getOptions = do
  args <- getArgs
  case getOpt Permute options args of
    ([], [], []) -> do
      printUsage stdout
      exitSuccess
    (opts, files, []) -> return $ foldr ($) (defaultOptions files) opts
    (_, _, errs) -> do
      hPutStr stderr $ unlines errs
      printUsage stderr
      exitWith $ ExitFailure 1

printUsage h = do
  prog <- getProgName
  let header = unwords [ prog, "version", showVersion version ]
  hPutStrLn h $ usageInfo header options

data Options = Options
  { optCTags       :: Bool
  , optETags       :: Bool
  , optCTagsFile   :: String
  , optETagsFile   :: String
  , optHelp        :: Bool
  , optIncludes    :: [FilePath]
  , optFiles       :: [FilePath]
  , optIncludePath :: [FilePath]
  , optCabalPath   :: Maybe FilePath
  }

defaultOptions :: [FilePath] -> Options
defaultOptions files = Options
  { optCTags       = False
  , optETags       = False
  , optCTagsFile   = "tags"
  , optETagsFile   = "TAGS"
  , optHelp        = False
  , optIncludes    = []
  , optFiles       = files
  , optIncludePath = []
  , optCabalPath   = Nothing
  }

options :: [OptDescr (Options -> Options)]
options =
  [ Option []    ["help"]    (NoArg setHelp)  "Show help."
  , Option ['c'] ["ctags"]   (OptArg setCTagsFile "FILE") "Generate ctags (default file=tags)"
  , Option ['e'] ["etags"]   (OptArg setETagsFile "FILE") "Generate etags (default file=TAGS)"
  , Option ['i'] ["include"] (ReqArg addInclude   "FILE") "File to #include"
  , Option ['I'] []          (ReqArg addIncludePath "DIRECTORY") "Directory in the include path"
  , Option []    ["cabal"]   (ReqArg addCabal "CABAL FILE") "Cabal configuration to load additional language options from (library options are used)"
  ]
  where
    setHelp             o = o { optHelp        = True }
    setCTags            o = o { optCTags       = True }
    setETags            o = o { optETags       = True }
    setCTagsFile   file o = o { optCTagsFile   = fromMaybe "tags" file, optCTags = True }
    setETagsFile   file o = o { optETagsFile   = fromMaybe "TAGS" file, optETags = True }
    addInclude     file o = o { optIncludes    = file : optIncludes o }
    addIncludePath dir  o = o { optIncludePath = dir : optIncludePath o}
    addCabal       file o = o { optCabalPath   = Just file }
