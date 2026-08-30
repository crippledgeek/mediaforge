Usage
=====

Every subcommand and option. `./mediaforge.sh help` prints the same
surface; this file is the long form.

```
Usage: mediaforge.sh <command> [options]

Commands:
  build              Build FFmpeg and dependencies
  clean              Remove all build artifacts
  install            Install built binaries and libraries
  uninstall          Remove installed files
  check-updates      Check for newer dependency versions
  makesum            Fetch recipe sources and record their sha256/size sidecars
  check-shadowers    Audit workspace .pc files for system-version shadowing
  reconcile          Check build stamps against the artifacts they vouch for
  list-profiles      List available version profiles
  help               Show help
  version            Show version

Build options:
  -g, --enable-gpl          Enable GPL-licensed codecs
  -G, --enable-nonfree      Enable non-free codecs (implies GPL)
  -L, --disable-lv2         Skip LV2 plugin chain
  -s, --enable-static       Full static binary (Linux only)
  -m, --enable-small        Minimal build
      --enable-lto          Enable LTO in recipes that support it
                            (default: off; archives may break on GCC major bumps)
      --disable-lto         Force LTO off (default)
      --debug[=LEVEL]       Build with debug info (symbols|balanced|full)
                            Bare --debug means full. Forces LTO off.
  -p, --profile=X.Y         Use version profile
  -j, --jobs=N              Parallel job count (default: auto)
  -u, --rebuild-outdated    Rebuild stale dependencies
  -I, --no-install          Skip post-build install
  -y, --yes                 Non-interactive mode
      --menu                Interactive selector (whiptail or POSIX fallback)
  -v, --verbose             Show build commands (-vv for more)
  -q, --quiet               Errors only
  -n, --dry-run             Show what would build
  -k, --keep-going          Continue on recipe failure
      --allow-tmpfs         Build even when the working directory is on a
                            RAM-backed filesystem (refused by default)

Codec / backend selectors (mutually exclusive within each group):
  --tls=BACKEND             TLS backend: openssl|gnutls|mbedtls|libressl|none
                            (default: gnutls)
  --aac=IMPL                AAC encoder: fdk_aac|native
                            (default: native; nonfree -> fdk_aac)
  --h264=IMPL               H.264 encoder: x264|openh264 (default: x264)
  --h265=IMPL               H.265 encoder: x265|kvazaar (default: x265)
  --av1-enc=IMPL            AV1 encoder: svtav1|rav1e|av1 (default: svtav1)
  --spirv=IMPL              SPIR-V compiler: glslang|shaderc
                            (default: glslang)
  --flite-audio=BACKEND     flite audio output: none|alsa|pulseaudio|oss|sun
                            (default: none; FFmpeg filter does not invoke it)
  --openssldir=PATH         Compiled-in trust store for the openssl/libressl
                            arms (absolute). Default: probe the host for a
                            directory holding cert.pem, else the build prefix.

Recipe overrides:
  --disable=PKG             Disable a recipe by name (repeatable, comma-separated ok)
  --enable=PKG              Force-enable a recipe that defaults to off
  --list-pkgs               Print every recipe with category and mutex group
  --clean-choices           Delete the stored choice matrix and exit

Makesum options (used by the makesum subcommand):
  --allow-tmpfs             Fetch even when the working directory is on a
                            RAM-backed filesystem (refused by default)
  --profile=X.Y             Record digests against a specific version profile
  --update                  Overwrite an existing digest that no longer matches
  --build                   Run a real build with recording enabled, to reach
                            sub-build downloads (forwards remaining args to
                            build; no package filter)

Checksum verification (loud; never persisted to the stored choice matrix):
  --skip-checksum           Disable verification for EVERY recipe
  --skip-checksum=PKG       Disable verification for one recipe by name
                            (repeatable, comma-separated ok)

Install/uninstall options:
  --prefix=PATH             Install/uninstall location (default: interactive prompt)
  -y, --yes                 Non-interactive mode
```

### Debug builds

`--debug[=LEVEL]` builds every dependency and FFmpeg itself with debug
information. Three levels, with costs measured on this tree (lame, dav1d and
SVT-AV1 built at each):

| Level | Optimization | Assertions | Runtime cost | Archive size |
|---|---|---|---|---|
| `symbols` | `-O2 -g3` | off | none measurable | ~2x |
| `balanced` | `-Og -g3` | **on** | ~2x slower | ~2x |
| `full` (bare `--debug`) | `-O0 -g3` | **on** | 4-5x slower | ~3x |

Those figures come from building three packages — lame, dav1d and SVT-AV1 — at
each level on one machine and timing one fixture each. Treat them as the right
order of magnitude, not a promise. "Archive size" is the multiple applied to the
static `.a` files; the final `ffmpeg` binary grows more, since it links all of
them.

`symbols` is what distributions ship as debuginfo: identical performance, but a
crash gives a real backtrace with file and line. It is also the only level that
stays behaviourally identical to a release build — the other two enable
assertions, which can change behaviour.

All three set `-fno-omit-frame-pointer`, so backtraces are reliable even at
`symbols`, and `-g3` rather than `-g2`, which keeps macro definitions available
in the debugger.

The level reaches all four places a build's posture is decided: the composed
`CFLAGS` for autotools recipes, `CMAKE_BUILD_TYPE` for cmake ones, `buildtype`
plus `b_ndebug` for meson ones (meson does not tie `NDEBUG` to buildtype the way
cmake does), and FFmpeg's own `--enable-debug` / `--disable-stripping` — without
that last one the final binary is stripped whatever the ~110 libraries did.

`--debug` forces LTO off and says so: LTO discards the per-function debug info
that makes stepping work.

**A workspace remembers the level it was built at.** Build stamps record only a
recipe's name and version, so nothing about a build's *flags* is captured — a
release build followed by `--debug` would rebuild nothing but FFmpeg and produce
a debug binary linked against stripped, optimized archives, which compiles,
links and runs while every library's stack traces are wrong. mediaforge refuses
that instead: change the level on a populated workspace and it stops, telling
you to `./mediaforge.sh clean` (or remove `workspace/.stamps`) first.

**`--enable-small` overrides the level for FFmpeg itself.** FFmpeg's configure
picks its optimization in the order small → optimizations → none, so `libav*`
compiles at `-Os` while the ~110 dependencies still honour the debug level.
mediaforge warns when both are given.

### Examples

```sh
# Build with short flags
./mediaforge.sh build -Gs                # nonfree + static
./mediaforge.sh build -g -j 4            # GPL, 4 jobs
./mediaforge.sh build -n                  # dry run

# Debug builds
./mediaforge.sh build --debug             # -O0 -g3, assertions on (4-5x slower)
./mediaforge.sh build --debug=symbols     # -O2 -g3, no measurable slowdown
./mediaforge.sh build --debug=balanced    # -Og -g3, assertions on (~2x slower)

# Version profiles
./mediaforge.sh list-profiles
./mediaforge.sh build --profile=7.1
./mediaforge.sh build --profile=6.1 --rebuild-outdated

# Install/uninstall
./mediaforge.sh install                   # interactive menu
./mediaforge.sh install --prefix=/opt/ffmpeg
./mediaforge.sh install --prefix=$HOME/.local/mediaforge  # isolated user prefix
./mediaforge.sh uninstall                 # discovers installs via manifest
./mediaforge.sh uninstall --prefix=/opt/ffmpeg

# Update checking
./mediaforge.sh check-updates
./mediaforge.sh check-updates --profile=7.1
GITHUB_TOKEN=ghp_xxx ./mediaforge.sh check-updates

# Audit pkgconfig drift (after build, before release)
./mediaforge.sh check-shadowers              # warn-only, exit 0
./mediaforge.sh check-shadowers --strict     # exit 1 on new shadowers (CI)

# Check the build stamps against the workspace they vouch for
./mediaforge.sh reconcile                    # exit 1 if any stamp has lost its artifact
./mediaforge.sh reconcile --quiet            # report only problems
./mediaforge.sh reconcile --prune            # drop the drifted stamps and exit 0

# Record/update checksum sidecars
./mediaforge.sh makesum                      # every recipe, plus the FFmpeg tarball
./mediaforge.sh makesum zlib openssl         # just these recipes
./mediaforge.sh makesum --profile=7.1        # against a specific profile's pinned versions
./mediaforge.sh makesum --update             # overwrite a digest that no longer matches

# Clean
./mediaforge.sh clean
```

## Build stamps and reconcile

A build stamp in `workspace/.stamps/` records that a recipe was built. Since GH-59
it also records **what** it built: one `workspace`-relative path per line, naming
the files that recipe's install produced. That is the same idea as FreeBSD's
`pkg-plist`, pkgsrc's `PLIST` or Portage's `CONTENTS`, and it exists so a stamp is
evidence rather than a claim.

`reconcile` compares the two and reports each stamp as:

| state | meaning |
|---|---|
| `verified` | every path the stamp names is present |
| `DRIFTED` | the stamp names a path that is gone |
| `unverifiable` | the stamp carries no manifest |

**`DRIFTED` is the one that matters.** A stamp that outlives its artifact makes the
next build *skip* a recipe it never actually built, and the failure then surfaces at
FFmpeg's configure or link step, nowhere near the recipe that caused it. `build`
therefore drops drifted stamps automatically before it starts, so those recipes are
rebuilt rather than skipped; `reconcile` is the read-only view of the same check,
and `--prune` performs the drop on its own.

`unverifiable` is not a problem. It means the stamp has no manifest to check —
either it was written before GH-59, or it belongs to one of the recipes that
installs with a plain `cp` (`gsm`, `ladspa`, `amf`, `bzip2`, `quirc`, `meson`,
`vapoursynth`, `flite`),
which stages nothing because `DESTDIR` only redirects installs performed by make,
ninja and cmake. Those recipes behave exactly as they always have; they simply
cannot be verified this way.

`build --dry-run` reports drift and drops nothing, since its contract is to show
what would build without touching anything.

The reverse direction — a `.pc` sitting in the workspace with no stamp — is reported
as `lost stamp` and does not affect the exit status. It costs a needless rebuild,
which is wasteful rather than incorrect.

## Where the build may be written

mediaforge derives both working directories from the directory you run it in --
`packages/` for downloads and sources, `workspace/` for what they install into
-- so the build lands wherever you were standing. A full tree measures about
**34GB** (25GB of packages, 9.1GB of workspace, measured on a complete
`--enable-nonfree --enable-static` build), which is more than most `/tmp` mounts
hold.

That matters because `/tmp` is usually tmpfs, which is RAM. A build that fills a
disk fails the build; a build that fills a tmpfs exhausts memory, and the OOM
killer starts choosing processes that have nothing to do with mediaforge. So
building from a RAM-backed directory is **refused**:

    $ cd /tmp/scratch && mediaforge.sh build
    [mediaforge] FATAL: /tmp/scratch is on a RAM-backed filesystem. ...

Pass `--allow-tmpfs` if the mount really is large enough; it warns and proceeds.
On a disk-backed directory with less than 40GB free, mediaforge warns and builds
anyway -- a smaller selection genuinely fits, so that one is your call.

The filesystem type is read with `df -T`, falling back to `stat -f`. macOS has
neither in that form -- its `df -T` is a type *filter* taking a list rather than
a column selector, and its `stat -f` takes a format string -- so there the type
is simply unknown and only the free-space warning applies. macOS keeps `/tmp` on
disk, so the RAM case does not arise there.

## Compiler cache

**The default is to use ccache when it is installed**, and to build without one
when it is not. `--ccache` demands it: asking for a cache that is not installed
is an error, not a silent no-op. `--no-ccache` turns it off everywhere:

    ./mediaforge.sh build --debug=full           # cached, if ccache is installed
    ./mediaforge.sh build --ccache               # cached, or refuse to build
    ./mediaforge.sh build --no-ccache            # never cached

It works by putting a directory of compiler-named symlinks ahead of PATH, so a
recipe that sets its own CC still gets the cache. Two things are worth knowing
before relying on it:

  * meson recipes find ccache by themselves, whichever way the flag is set.
    That is why the default is on: it was never "no cache" -- it was ccache for
    the meson recipes and not for the rest (autotools, cmake and bare make;
    cargo is not cached either way, since ccache does not cache rustc).
    `--no-ccache` therefore exports CCACHE_DISABLE, which is what reaches a
    ccache mediaforge did not put there.
  * an exported CCACHE_DISABLE wins over the default. If your shell already
    turns ccache off host-wide, the default leaves it off and says so, rather
    than re-enabling a cache you disabled. `--ccache` is the one thing that
    overrides it: an explicit flag beats an inherited variable, in that
    direction only.
  * ccache hashes the compiler flags, so a debug build shares nothing with a
    non-debug one. The first build at a given level populates the cache and
    the second is fast. A full -O0 -g3 tree is large; raise the cache ceiling
    (ccache -M) first or it will evict everything else in it.

## Version Profiles

Profiles pin all ~80 dependency versions to a known-good set for a specific FFmpeg release:

| Profile | FFmpeg | Release |
|---------|--------|---------|
| `8.0.1` | 8.0.1  | 2025    |
| `7.1`   | 7.1    | Sep 2024 |
| `7.0`   | 7.0    | Apr 2024 |
| `6.1`   | 6.1    | Nov 2023 |

Without `--profile`, recipes use their built-in default versions (equivalent to the 8.0.1 profile).
