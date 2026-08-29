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
* Every option:          ./mediaforge.sh help

`build` INSTALLS when it finishes. It ends by running the install step, which
prompts with the interactive prefix menu. Pass -I (--no-install) to build only,
and install as a separate step afterwards:

    ./mediaforge.sh build --enable-nonfree --enable-static --no-install
    ./mediaforge.sh install --prefix=$HOME/.local/mediaforge

Note that --prefix applies to the standalone install command, not to build's
trailing auto-install, which always uses the menu.

The build needs a POSIX shell, make, g++ (clang++ on macOS) and curl. Optional
tools enable individual recipes rather than gating the build.

Documentation
-------------

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
