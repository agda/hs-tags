hTags - Generate tags for Haskell code
======================================

Generate `tags` (ctags) or `TAGS` (etags) file for a bunch of Haskell files.
These files are used by editors (e.g. `TAGS` by Emacs) to implement _jump-to-definition_ (e.g. `M-.` in Emacs).

In contrast to [hasktags](http://hackage.haskell.org/package/hasktags), `hTags` uses the GHC Haskell parser to read the Haskell files and find definition sites.

Example use:
```
find src -name "*.*hs" | xargs \
  hTags --cabal Foo.cabal -i dist/build/autogen/cabal_macros.h -e
```
Creates Emacs `TAGS` from Haskell files residing in folder `src/` of the project as defined in `Foo.cabal`, using preprocessor definitions from `dist/build/autogen/cabal_macros.h`.

Command line reference:
```
hTags
                --help              Show help.
  -c[FILE]      --ctags[=FILE]      Generate ctags (default file=tags)
  -e[FILE]      --etags[=FILE]      Generate etags (default file=TAGS)
  -i FILE       --include=FILE      File to #include
  -I DIRECTORY                      Directory in the include path
                --cabal=CABAL FILE  Cabal configuration to load additional
                                    language options from
                                    (library options are used)
```

Some related projects:

- [hasktags](http://hackage.haskell.org/package/hasktags):
  popular ctags and etags generator, using its own parser.

- [fast-tags](https://hackage.haskell.org/package/fast-tags):
  ctags and etags, fast, incremental, using its own parser.

- [ghc-tags-plugin](https://hackage.haskell.org/package/ghc-tags-plugin):
  ctags and etags emitted during compilation by a ghc-plugin.

- [hothasktags](https://hackage.haskell.org/package/hothasktags)
  (_unmaintained_?):
  ctags generator, using the [haskell-src-exts](https://hackage.haskell.org/package/haskell-src-exts) parser.

- [htags](https://hackage.haskell.org/package/htags):
  ctags for Haskell 98, using the [haskell-src](https://hackage.haskell.org/package/haskell-src) parser.

- [codex](https://hackage.haskell.org/package/codex):
  ctags and etags for dependencies, using
  [hasktags](http://hackage.haskell.org/package/hasktags).