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

# Record/update checksum sidecars
./mediaforge.sh makesum                      # every recipe, plus the FFmpeg tarball
./mediaforge.sh makesum zlib openssl         # just these recipes
./mediaforge.sh makesum --profile=7.1        # against a specific profile's pinned versions
./mediaforge.sh makesum --update             # overwrite a digest that no longer matches

# Clean
./mediaforge.sh clean
```

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
    the meson recipes and not for the other four build systems. `--no-ccache`
    therefore exports CCACHE_DISABLE, which is what reaches a ccache mediaforge
    did not put there.
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
