mediaforge
==========

mediaforge builds FFmpeg and the 110 libraries it links against from source,
one POSIX shell file per dependency. Everything lands in a build tree under the
working directory; nothing outside it is touched until an explicit install step.

Quick Start
-----------

* Free codecs only:      ./mediaforge.sh build
* Add GPL codecs:        ./mediaforge.sh build --enable-gpl
* Add non-free codecs:   ./mediaforge.sh build --enable-nonfree
* Static binary (Linux): ./mediaforge.sh build --enable-nonfree --enable-static
* Build with symbols:    ./mediaforge.sh build --debug=symbols
* Every option:          ./mediaforge.sh help

`build` INSTALLS when it finishes, prompting with the interactive prefix menu.
Pass -I (--no-install) to build only, then install separately -- note --prefix
applies to that standalone install, never to build's trailing one:

    ./mediaforge.sh build --enable-nonfree --enable-static --no-install
    ./mediaforge.sh install --prefix=$HOME/.local/mediaforge

The build needs a POSIX shell, make, g++ (clang++ on macOS) and curl. Optional
tools enable individual recipes rather than gating the build.

Commands
--------

* build            compile FFmpeg and the libraries it links against
* install          copy a finished build to a prefix, recording a manifest
* uninstall        delete what that manifest lists
* clean            remove the build tree and unpacked sources; `--all` also
                   discards the downloaded archives and git clones
* check-updates    compare pinned versions against upstream releases
* makesum          record or refresh the .hash sidecar for a recipe
* check-shadowers  report .pc files that would shadow the system's
* reconcile        check each build stamp against the artifacts it vouches for
* list-profiles    list the version profiles in profiles/
* help             print every option

Debug builds
------------

--debug compiles the whole tree with symbols, at one of three levels: symbols
(-O2, no measurable slowdown), balanced (-Og), or full (-O0, the bare --debug).

It asks one thing of you. The debug info is split into .dwo files beside the
objects under packages/, and those are never installed, so those trees have to
survive or a debugger can no longer step into the prefix -- while every binary
still runs, so nothing looks wrong. clean warns before it takes them.

Levels, measured sizes, and the exact failure: "Debug builds and split DWARF"
in the wiki.

Documentation
-------------

Guides, worked examples and the reasoning behind a default are in the wiki:
https://github.com/crippledgeek/mediaforge/wiki

The reference is in this repository, so it matches the commit you have checked
out and needs no network:

* Build requirements: Documentation/requirements.md
* Usage and options: Documentation/usage.md
* Installing, and which prefix to use: Documentation/install.md
* Checksum verification: Documentation/checksums.md
* Enabled libraries: Documentation/libraries.md
* How it works: Documentation/internals.md
* Building and troubleshooting: BUILDING.md
* Writing a recipe: CONTRIBUTING.md
* License: LICENSE (MIT)

Do Not
------

* Do NOT run install with sudo against a prefix in your home directory. The
  installer elevates itself only when the prefix requires it; running the whole
  thing as root leaves root-owned files behind, and there is no chown-on-finish
  step by design. See Documentation/install.md.
* Do NOT install into a shared prefix if anything downstream uses pkg-config.
  mediaforge ships 94 transitive .pc files that will shadow the system's.
  Use an isolated prefix instead: --prefix=$HOME/.local/mediaforge.

Where Things Are
----------------

* mediaforge.sh -- the entry point: option parsing and the subcommands
* lib/ -- the framework: fetch, verify, build phases, install, resolve
* recipes/ -- one file per dependency, grouped by category
* patches/ -- third-party build fixes, applied in pkg_prepare
* profiles/ -- dependency versions pinned per FFmpeg release
* tests/ -- the suite; sh tests/run.sh runs it

Reporting a Problem
-------------------

Include the mediaforge command line, the failing recipe, and the tail of the
log the run names. A build that fails inside a dependency usually fails the
same way outside mediaforge; say whether you tried it.
