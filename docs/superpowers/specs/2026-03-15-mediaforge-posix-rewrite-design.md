# Mediaforge POSIX Rewrite — Design Specification

## Overview

Rewrite `mediaforge.sh` (an FFmpeg-from-source build script, based on markus-perl/ffmpeg-build-script) from a Bash-dependent monolith into a fully POSIX-compliant (`#!/usr/bin/env sh`) multi-file build system with a modular recipe framework.

### Goals

- Full POSIX shell compliance — must run under dash, ash, busybox sh
- Portable across Linux (Arch, Debian/Ubuntu, Alpine), macOS, FreeBSD, BusyBox environments
- Modular architecture with per-package recipe files
- Hybrid declarative/imperative recipe model
- Fix all bugs and safety issues identified in the original analysis
- Clean GPL/nonfree codec tier separation
- Improved error handling with trap-based cleanup

### Non-Goals

- Dependency DAG / automatic build ordering (overkill for ~40 packages)
- Parallel package builds
- Windows/MSYS support
- Auto-installing build dependencies via package managers

---

## Project Structure

```
mediaforge/
├── mediaforge.sh              # entry point: arg parsing, orchestration
├── lib/
│   ├── platform.sh            # OS/arch detection, exported variables
│   ├── framework.sh           # build engine: run_recipe(), phase runner
│   ├── download.sh            # download(), extract helpers
│   ├── utils.sh               # execute(), command_exists(), make_dir(), remove_dir()
│   ├── cleanup.sh             # trap handlers, error reporting
│   └── install.sh             # binary install logic with sudo detection
├── packages/
│   ├── _order.conf            # build order: one recipe path per line
│   ├── tools/                 # build toolchain (giflib, pkg-config, yasm, nasm, zlib, m4, autoconf, automake, libtool, cmake)
│   ├── crypto/                # crypto libs (openssl, gmp, nettle, gnutls)
│   ├── video/                 # video codecs (dav1d, svtav1, rav1e, x264, x265, libvpx, xvidcore, vid_stab, av1, zimg)
│   ├── audio/                 # audio codecs (lv2 chain, opencore, lame, opus, libogg, libvorbis, libtheora, fdk_aac, soxr)
│   ├── image/                 # image libs (libtiff, libpng, libjxl, libwebp)
│   ├── hwaccel/               # hw acceleration (vulkan-headers, glslang, nv-codec, amf, opencl)
│   └── other/                 # other libs (gettext, libsdl, freetype2, vapoursynth, srt, zvbi, libzmq)
└── packages/ffmpeg.sh         # final FFmpeg build (special, not a regular recipe)
```

### Build Order

`packages/_order.conf` is a plain text file listing recipe paths relative to the script directory, one per line. Blank lines and `#` comments are skipped. Example:

```
packages/tools/giflib.sh
packages/tools/pkg-config.sh
# ... etc
packages/video/x264.sh
packages/audio/opus.sh
packages/ffmpeg.sh
```

The driver reads this file sequentially with `while read`.

---

## Platform Detection (`lib/platform.sh`)

Single source of truth for all OS/arch information. Sourced once at startup.

### Detected Variables

| Variable | Source | Example values |
|---|---|---|
| `OS_TYPE` | `uname -s` | `Linux`, `Darwin`, `FreeBSD` |
| `OS_ARCH` | `uname -m` | `x86_64`, `arm64`, `aarch64` |
| `IS_DARWIN` | derived | `true` / `false` |
| `IS_LINUX` | derived | `true` / `false` |
| `IS_FREEBSD` | derived | `true` / `false` |
| `IS_MACOS_SILICON` | derived (Darwin + arm64) | `true` / `false` |
| `MULTIARCH` | `dpkg-architecture` or `gcc -dumpmachine` | `x86_64-linux-gnu`, empty |
| `MJOBS` | `$NUMJOBS` > `/proc/cpuinfo` > `sysctl` > `nproc` > `4` | integer |

Boolean variables are shell strings `true`/`false`, used as `if $IS_DARWIN; then`.

### pkg-config Path

Constructed dynamically using `$MULTIARCH` instead of hardcoded `x86_64-linux-gnu`:

```sh
PKG_CONFIG_PATH="$WORKSPACE/lib/pkgconfig:/usr/local/lib/pkgconfig"
if [ -n "$MULTIARCH" ]; then
  PKG_CONFIG_PATH="$PKG_CONFIG_PATH:/usr/lib/$MULTIARCH/pkgconfig"
fi
# ... standard fallback paths
```

---

## Recipe Framework (`lib/framework.sh`)

### Recipe Contract

Every recipe file can declare these variables:

```sh
# Required
PKG_NAME="opus"
PKG_VERSION="1.6"
PKG_URL="https://downloads.xiph.org/releases/opus/opus-${PKG_VERSION}.tar.gz"

# Optional metadata
PKG_FILENAME=""              # override auto-detected download filename
PKG_DIRNAME=""               # override auto-detected extract directory
PKG_FFMPEG_OPT=""            # ffmpeg configure flag(s), space-separated
PKG_GPL=false                # only built when --gpl is passed
PKG_NONFREE=false            # only built when --nonfree is passed
PKG_REQUIRES_CMD=""          # space-separated required commands (e.g. "cargo python3")
PKG_REQUIRES_MESON=false     # needs meson + ninja
PKG_LINUX_ONLY=false         # skip on non-Linux
PKG_SKIP_ON_ARCH=""          # skip on this arch (e.g. "arm64")
PKG_SKIP_EXTRACT=false       # for patch files or header-only installs
PKG_CONFIGURE_FLAGS=""       # passed to ./configure
PKG_CMAKE=false              # use cmake instead of configure
PKG_CMAKE_FLAGS=""           # passed to cmake
```

### Phase Functions

Recipes can override any phase. Defaults:

| Phase | Default behavior |
|---|---|
| `pkg_prepare()` | no-op |
| `pkg_configure()` | `./configure --prefix="$WORKSPACE" --disable-shared --enable-static $PKG_CONFIGURE_FLAGS` or cmake equivalent |
| `pkg_build()` | `make -j "$MJOBS"` |
| `pkg_install()` | `make install` |
| `pkg_post_install()` | no-op |

### `run_recipe()` Flow

1. Reset all `PKG_*` variables and phase functions to defaults (`reset_recipe()`)
2. Source the recipe file
3. Check guards:
   - `PKG_GPL=true` but `$GPL` not set — skip
   - `PKG_NONFREE=true` but `$NONFREE` not set — skip
   - `PKG_REQUIRES_CMD` — check each command, warn and skip if missing
   - `PKG_REQUIRES_MESON=true` — check meson + ninja, skip if missing
   - `PKG_LINUX_ONLY=true` but not Linux — skip
   - `PKG_SKIP_ON_ARCH` matches `$OS_ARCH` — skip
   - Done-file matches version — skip (unless `--latest`)
4. Set `_CURRENT_PACKAGE="$PKG_NAME"` (for trap error reporting)
5. Download and extract (unless `PKG_SKIP_EXTRACT`)
6. Run phases: `pkg_prepare` > `pkg_configure` > `pkg_build` > `pkg_install` > `pkg_post_install`
7. Write done-file
8. Accumulate `PKG_FFMPEG_OPT` into `CONFIGURE_OPTIONS` if non-empty

### Variable Scoping

POSIX `sh` has no `local`. All internal variables use `_` prefix convention (`_url`, `_file`, `_rc`) to avoid collisions with recipe variables.

### Recipe Examples

**Simple recipe** — `packages/audio/opus.sh`:
```sh
PKG_NAME="opus"
PKG_VERSION="1.6"
PKG_URL="https://downloads.xiph.org/releases/opus/opus-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libopus"
```

**Complex recipe** — `packages/video/x265.sh`:
```sh
PKG_NAME="x265"
PKG_VERSION="4.1"
PKG_URL="https://bitbucket.org/multicoreware/x265_git/downloads/x265_${PKG_VERSION}.tar.gz"
PKG_FILENAME="x265-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libx265"
PKG_GPL=true
PKG_CMAKE=true

pkg_build() {
  cd build/linux || die "Failed to cd to build/linux"
  rm -rf 8bit 10bit 12bit 2>/dev/null
  mkdir -p 8bit 10bit 12bit
  # ... multi-bitdepth build with platform-specific ar/libtool
  if $IS_DARWIN; then
    execute "$MACOS_LIBTOOL" -static -o libx265.a ...
  else
    execute ar -M <<EOF
CREATE libx265.a
...
EOF
  fi
}
```

---

## Utilities (`lib/utils.sh`)

### Logging

```sh
log()  { printf '[mediaforge] %s\n' "$*"; }
warn() { printf '[mediaforge] WARNING: %s\n' "$*" >&2; }
die()  { printf '[mediaforge] FATAL: %s\n' "$*" >&2; exit 1; }
```

All output uses `printf`, never `echo` (portability).

### Command Execution

```sh
execute() {
  log "$ $*"
  _output=$("$@" 2>&1)
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    printf '%s\n' "$_output"
    die "Command failed (exit $_rc): $*"
  fi
}
```

### Other Helpers

- `command_exists()` — uses `command -v`, not `which`
- `library_exists()` — uses `pkg-config --exists` return code (fixed from broken original)
- `make_dir()` / `remove_dir()` — directory helpers with error checking
- `build()` / `build_done()` — done-file gating with version comparison

---

## Download & Extract (`lib/download.sh`)

```sh
download() {
  _url="$1"
  _file="${2:-${_url##*/}}"
  _dir="$3"
  # Auto-detect dir from tarball name using case/esac (not regex)
  # curl -L -sS (silent + show-error, not --silent)
  # Retry once after 10 seconds on failure
  # Extract with tar -xf (no -v, it was redirected to /dev/null anyway)
  # die() on failure instead of broken subshell (exit 1)
}
```

Key POSIX fixes:
- `case` pattern matching instead of `[[ =~ ]]` for tarball type detection
- `curl -sS` shows errors while suppressing progress
- `die()` instead of `(exit 1)` subshell bug

---

## Cleanup & Traps (`lib/cleanup.sh`)

```sh
on_exit() {
  _exit_code=$?
  if [ "$_exit_code" -ne 0 ]; then
    warn "Build failed during: ${_CURRENT_PACKAGE:-unknown}"
    warn "Successfully built packages are preserved."
    warn "Fix the issue and re-run to resume."
  fi
  cd "$CWD" 2>/dev/null
  exit "$_exit_code"
}

setup_traps() {
  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}
```

No `.git` move/restore — the ffmpeg build uses `GIT_DIR=/dev/null/nonexistent` instead.

---

## Driver Script (`mediaforge.sh`)

### Shebang

```sh
#!/usr/bin/env sh
set -e
```

### Argument Parsing

Proper `case`/`esac` with `while [ $# -gt 0 ]; do` loop. Each flag is a separate case branch (no chained `if` blocks).

### CLI Flags

| Flag | Effect |
|---|---|
| `-h`, `--help` | Show usage |
| `--version` | Print version |
| `-b`, `--build` | Start build |
| `--gpl` | Enable GPL codecs (x264, x265, xvidcore, vid.stab) |
| `--nonfree` | Enable GPL + non-free codecs (implies --gpl; adds fdk-aac, openssl, srt, zvbi) |
| `--disable-lv2` | Skip LV2 libraries |
| `-c`, `--cleanup` | Remove working dirs |
| `--latest` | Rebuild outdated packages |
| `--small` | Small binary, no manpages |
| `--full-static` | Full static binary (Linux only) |
| `--skip-install` | Don't install to system |
| `--auto-install` | Install without prompting |

### Environment Variable Overrides

| Variable | Purpose |
|---|---|
| `NUMJOBS` | Override parallel job count |
| `CUDA_COMPUTE_CAPABILITY` | CUDA arch (default: 52) |
| `SKIPINSTALL` | Equivalent to `--skip-install` |
| `AUTOINSTALL` | Equivalent to `--auto-install` |
| `SKIPRAV1E` | Skip rav1e build |

### Orchestration Flow

1. Source `lib/*.sh`
2. Parse arguments
3. Pre-flight checks (make, g++, curl)
4. Platform-specific setup (Apple Silicon, macOS libtool)
5. Create workspace directories, set PATH and PKG_CONFIG_PATH
6. Read `_order.conf`, call `run_recipe()` for each entry
7. Source `packages/ffmpeg.sh` (special build)
8. Source `lib/install.sh` (install prompt)

---

## FFmpeg Build (`packages/ffmpeg.sh`)

Not a regular recipe — it consumes `$CONFIGURE_OPTIONS` accumulated from all packages.

### .git Workaround

Instead of physically moving `.git` directories:
```sh
GIT_DIR=/dev/null/nonexistent ./configure ...
```

This prevents FFmpeg's `ffbuild/version.sh` from detecting the project's git repository.

### NVIDIA Flags

NVCC flags contain spaces in values (`--nvccflags=-gencode arch=compute_52,code=sm_52 -O2`). These are stored in a separate `$NVCC_FLAGS` variable and passed quoted separately in the configure call, avoiding the word-splitting issue with the space-delimited `$CONFIGURE_OPTIONS` string.

### `--extra-version`

Only set on Darwin (as in original) to avoid breaking cmake version detection in downstream tools.

---

## Install Logic (`lib/install.sh`)

### Install Location Detection

| Priority | Condition | Path |
|---|---|---|
| 1 | macOS | `/usr/local` |
| 2 | `$HOME/.local` exists | `$HOME/.local` |
| 3 | `/usr/local` exists | `/usr/local` |
| 4 | fallback | `/usr` |

### Sudo Detection

```sh
case "$INSTALL_FOLDER" in
  /usr|/usr/*) SUDO=sudo ;;
  *) SUDO="" ;;
esac
```

Only uses sudo for system paths. Uses `printf` + `read -r` for the install prompt (`read -p` is not POSIX).

---

## POSIX Compliance Checklist

All Bashisms eliminated:

| Bashism | POSIX replacement |
|---|---|
| `[[ ]]` | `[ ]` with proper quoting |
| `==` in tests | `=` |
| `(( ))` arithmetic | `[ $# -gt 0 ]` |
| `=~` regex | `case` pattern matching |
| Bash arrays `()` | space-delimited strings |
| `+=` append | `VAR="$VAR new"` |
| `$OSTYPE` | `uname -s` with boolean vars |
| `function` keyword | `name() { }` |
| `source` | `.` |
| `echo -e` | `printf` |
| `read -p` | `printf` + `read -r` |
| `which` | `command -v` |
| `local` | `_` prefixed variables |
| `sed -i` | `sed > tmp && mv tmp orig` |

---

## Bugs Fixed From Original

1. **Broken subshell exit** — `(exit 1)` replaced with `die()` / `{ exit 1; }`
2. **Broken `library_exists()`** — was testing `-x` on pkg-config output; now uses return code
3. **Unquoted variables** — all expansions quoted except intentional word-splitting (`$CONFIGURE_OPTIONS`)
4. **`curl --silent` hiding errors** — replaced with `-sS`
5. **`sed -i` portability** — replaced with temp file + mv pattern
6. **Hardcoded x86_64 paths** — dynamic `$MULTIARCH` detection
7. **`which` usage** — replaced with `command -v`
8. **Unsafe `.git` rename** — replaced with `GIT_DIR` env var
9. **Silent `cd` failures** — all `cd` calls followed by `|| die "..."`
10. **Option parsing regex bugs** — `-b` matching `--verbose` etc. fixed with proper `case`
11. **Hardcoded Python 3.9 path** — removed
12. **`pip3 install` auto-behavior** — replaced with warning/skip
13. **`CPPFLAGS` cleared without restore** — fixed
14. **Double slash in path** — fixed

---

## Dropped Behaviors

- `pip3 install meson/ninja` — replaced with warning to install via system package manager
- `.git` directory move/restore — replaced with `GIT_DIR` env var
- Hardcoded `~/Library/Python/3.9/bin` path addition
- `echo -e` usage

## Changed Behaviors

- `--enable-gpl-and-non-free` split into `--gpl` and `--nonfree`
- Unknown CLI flags now produce an error instead of being silently ignored
- All log output prefixed with `[mediaforge]`
- Error messages include the failing package name and command
