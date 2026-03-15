# Mediaforge POSIX Rewrite Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the monolithic Bash FFmpeg build script into a POSIX-compliant multi-file build system with a modular recipe framework.

**Architecture:** Driver script (`mediaforge.sh`) sources library files from `lib/` and iterates over recipe files in `recipes/` via `_order.conf`. Each recipe declares metadata variables and optionally overrides phase functions. A framework engine (`lib/framework.sh`) handles the build lifecycle: guard checks, download, extract, configure, build, install, done-file management.

**Tech Stack:** POSIX `sh`, `curl`, `tar`, `make`, `cmake`, `meson`/`ninja`, `pkg-config`, standard Unix tools.

**Spec:** `docs/superpowers/specs/2026-03-15-mediaforge-posix-rewrite-design.md`

**Original script:** `ffmpeg-build-scripts/mediaforge.sh`

---

## Chunk 1: Core Library Files

### Task 1: Create `lib/utils.sh`

**Files:**
- Create: `lib/utils.sh`

- [ ] **Step 1: Create `lib/utils.sh` with logging functions**

```sh
#!/bin/sh
# Core utility functions for mediaforge

# Logging
log()  { printf '[mediaforge] %s\n' "$*"; }
warn() { printf '[mediaforge] WARNING: %s\n' "$*" >&2; }
die()  { printf '[mediaforge] FATAL: %s\n' "$*" >&2; exit 1; }
```

- [ ] **Step 2: Add command execution helpers**

```sh
# Execute a command with logging and error checking
execute() {
  log "$ $*"
  _output=$("$@" 2>&1)
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    printf '%s\n' "$_output"
    die "Command failed (exit $_rc): $*"
  fi
}

# Execute a command that reads from stdin (e.g., here-documents)
execute_stdin() {
  log "$ $* < (stdin)"
  _output=$("$@" 2>&1)
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    printf '%s\n' "$_output"
    die "Command failed (exit $_rc): $*"
  fi
}
```

- [ ] **Step 3: Add existence checks and directory helpers**

```sh
# Command existence check (POSIX — no 'which')
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# pkg-config library check (fixed: uses return code, not -x on output)
library_exists() {
  pkg-config --exists "$1" 2>/dev/null
}

# Directory helpers
make_dir() {
  remove_dir "$1"
  mkdir -p "$1" || die "Failed to create directory $1"
}

remove_dir() {
  if [ -d "$1" ]; then
    rm -rf "$1"
  fi
}
```

- [ ] **Step 4: Add build gating and done-file functions**

```sh
# Build gating — check done-file
# Returns 0 (true) if package should be built, 1 (false) if already done
build() {
  _pkg="$1"
  _ver="$2"

  log ""
  log "Building $_pkg - version $_ver"
  log "======================="

  if [ -f "$PACKAGES/$_pkg.done" ]; then
    _done_ver=$(cat "$PACKAGES/$_pkg.done")
    if [ "$_done_ver" = "$_ver" ]; then
      log "$_pkg version $_ver already built. Remove $PACKAGES/$_pkg.done to rebuild."
      return 1
    elif [ "$LATEST" = true ]; then
      log "$_pkg is outdated, rebuilding with version $_ver"
      return 0
    else
      log "$_pkg is outdated but will not be rebuilt. Use --latest to rebuild."
      return 1
    fi
  fi

  return 0
}

# Mark package as built
build_done() {
  printf '%s\n' "$2" > "$PACKAGES/$1.done"
}

# Print compiler flags
print_flags() {
  log "CFLAGS: $CFLAGS"
  log "CXXFLAGS: $CXXFLAGS"
  log "LDFLAGS: $LDFLAGS"
  log "LDEXEFLAGS: $LDEXEFLAGS"
}
```

- [ ] **Step 5: Verify POSIX compliance**

Run: `shellcheck -s sh lib/utils.sh`
Expected: No errors (warnings about `_` prefix variables are acceptable)

- [ ] **Step 6: Commit**

```bash
git add lib/utils.sh
git commit -m "Add lib/utils.sh — core utility functions"
```

---

### Task 2: Create `lib/platform.sh`

**Files:**
- Create: `lib/platform.sh`

- [ ] **Step 1: Create `lib/platform.sh` with OS/arch detection**

```sh
#!/bin/sh
# Platform detection — single source of truth for OS/arch info

OS_TYPE=$(uname -s)
OS_ARCH=$(uname -m)

IS_DARWIN=false
IS_LINUX=false
IS_FREEBSD=false
IS_MACOS_SILICON=false

case "$OS_TYPE" in
  Darwin)
    IS_DARWIN=true
    if [ "$OS_ARCH" = "arm64" ]; then
      IS_MACOS_SILICON=true
    fi
    ;;
  Linux)   IS_LINUX=true ;;
  FreeBSD) IS_FREEBSD=true ;;
esac

# Multiarch triplet for pkg-config paths
MULTIARCH=""
if command_exists dpkg-architecture; then
  MULTIARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null) || MULTIARCH=""
fi
if [ -z "$MULTIARCH" ] && command_exists gcc; then
  MULTIARCH=$(gcc -dumpmachine 2>/dev/null) || MULTIARCH=""
fi
```

- [ ] **Step 2: Add job count detection**

```sh
# Parallel job count detection
# $NUMJOBS env var overrides automatic detection
detect_jobs() {
  if [ -n "$NUMJOBS" ]; then
    printf '%s' "$NUMJOBS"
  elif [ -f /proc/cpuinfo ]; then
    grep -c processor /proc/cpuinfo
  elif [ "$IS_DARWIN" = true ]; then
    sysctl -n machdep.cpu.thread_count
  elif command_exists nproc; then
    nproc
  else
    printf '4'
  fi
}

MJOBS=$(detect_jobs)
```

- [ ] **Step 3: Verify POSIX compliance**

Run: `shellcheck -s sh lib/platform.sh`
Expected: No errors (SC2034 warnings for unused vars are fine — they're used by other files)

- [ ] **Step 4: Commit**

```bash
git add lib/platform.sh
git commit -m "Add lib/platform.sh — OS/arch detection"
```

---

### Task 3: Create `lib/download.sh`

**Files:**
- Create: `lib/download.sh`

- [ ] **Step 1: Create `lib/download.sh` with download function**

```sh
#!/bin/sh
# Download and extract helpers

# download URL [FILENAME [DIRNAME]]
download() {
  _url="$1"
  _file="${2:-${_url##*/}}"
  _dir="$3"

  # Auto-detect target dir from tarball name if not specified
  if [ -z "$_dir" ]; then
    case "$_file" in
      *.tar.gz)  _dir="${_file%.tar.gz}" ;;
      *.tar.xz)  _dir="${_file%.tar.xz}" ;;
      *.tar.bz2) _dir="${_file%.tar.bz2}" ;;
      *)         _dir="${_file%.*}" ;;
    esac
  fi

  # Download if not cached
  if [ ! -f "$PACKAGES/$_file" ]; then
    log "Downloading $_url"
    if ! curl -L -sS -o "$PACKAGES/$_file" "$_url"; then
      rm -f "$PACKAGES/$_file"
      warn "Download failed. Retrying in 10 seconds..."
      sleep 10
      if ! curl -L -sS -o "$PACKAGES/$_file" "$_url"; then
        rm -f "$PACKAGES/$_file"
        die "Failed to download $_url"
      fi
    fi
    log "Download complete"
  else
    log "$_file already cached"
  fi

  # Skip extraction for patch files
  case "$_file" in
    *patch*) return 0 ;;
  esac

  # Extract
  remove_dir "$PACKAGES/$_dir"
  mkdir -p "$PACKAGES/$_dir" || die "Failed to create $PACKAGES/$_dir"

  if [ -n "$3" ]; then
    _strip=""
  else
    _strip="--strip-components 1"
  fi

  # shellcheck disable=SC2086
  if ! tar -xf "$PACKAGES/$_file" -C "$PACKAGES/$_dir" $_strip 2>/dev/null; then
    die "Failed to extract $_file"
  fi

  log "Extracted $_file"
  cd "$PACKAGES/$_dir" || die "Failed to enter $PACKAGES/$_dir"
}
```

- [ ] **Step 2: Verify POSIX compliance**

Run: `shellcheck -s sh lib/download.sh`
Expected: SC2086 warning on `$_strip` (intentional word-splitting, already disabled)

- [ ] **Step 3: Commit**

```bash
git add lib/download.sh
git commit -m "Add lib/download.sh — download and extract helpers"
```

---

### Task 4: Create `lib/cleanup.sh`

**Files:**
- Create: `lib/cleanup.sh`

- [ ] **Step 1: Create `lib/cleanup.sh` with trap handlers**

```sh
#!/bin/sh
# Trap handlers and cleanup

# Track state for trap handler
_CURRENT_PACKAGE=""

# Called by framework when starting a package
set_current_package() {
  _CURRENT_PACKAGE="$1"
}

# Main trap handler — runs on EXIT, INT, TERM
on_exit() {
  _exit_code=$?

  if [ "$_exit_code" -ne 0 ]; then
    warn "Build failed during: ${_CURRENT_PACKAGE:-unknown}"
    warn "Successfully built packages are preserved (done-files intact)."
    warn "Fix the issue and re-run to resume from the failed package."
  fi

  # Restore working directory
  cd "$CWD" 2>/dev/null

  exit "$_exit_code"
}

# User cleanup (--cleanup flag)
full_cleanup() {
  remove_dir "$PACKAGES"
  remove_dir "$WORKSPACE"
  log "Cleanup done."
}

# Register traps
setup_traps() {
  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}
```

- [ ] **Step 2: Verify POSIX compliance**

Run: `shellcheck -s sh lib/cleanup.sh`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add lib/cleanup.sh
git commit -m "Add lib/cleanup.sh — trap handlers and cleanup"
```

---

### Task 5: Create `lib/framework.sh`

**Files:**
- Create: `lib/framework.sh`

- [ ] **Step 1: Create `lib/framework.sh` with reset_recipe()**

```sh
#!/bin/sh
# Build engine — recipe loading and phase execution

# Default phase functions
default_configure() {
  if [ "$PKG_CMAKE" = true ]; then
    # shellcheck disable=SC2086
    execute cmake -DCMAKE_INSTALL_PREFIX="$WORKSPACE" \
      -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF \
      $PKG_CMAKE_FLAGS .
  else
    # shellcheck disable=SC2086
    execute ./configure --prefix="$WORKSPACE" \
      --disable-shared --enable-static \
      $PKG_CONFIGURE_FLAGS
  fi
}

default_build() {
  execute make -j "$MJOBS"
}

default_install() {
  execute make install
}

default_noop() {
  :
}

# Reset all PKG_* variables and phase functions between recipes
reset_recipe() {
  PKG_NAME=""
  PKG_VERSION=""
  PKG_URL=""
  PKG_FILENAME=""
  PKG_DIRNAME=""
  PKG_FFMPEG_OPT=""
  PKG_GPL=false
  PKG_NONFREE=false
  PKG_REQUIRES_CMD=""
  PKG_REQUIRES_MESON=false
  PKG_LINUX_ONLY=false
  PKG_SKIP_ON_ARCH=""
  PKG_SKIP_EXTRACT=false
  PKG_SKIP_IF_NONFREE=false
  PKG_DISABLED=false
  PKG_CONFIGURE_FLAGS=""
  PKG_CMAKE=false
  PKG_CMAKE_FLAGS=""

  # Reset phase functions to defaults
  pkg_prepare()      { default_noop; }
  pkg_configure()    { default_configure; }
  pkg_build()        { default_build; }
  pkg_install()      { default_install; }
  pkg_post_install() { default_noop; }
}
```

- [ ] **Step 2: Add guard checking logic**

```sh
# Check whether a recipe should be skipped based on guards
# Returns 0 if recipe should run, 1 if it should be skipped
check_guards() {
  # Disabled guard (e.g., SKIPRAV1E=yes)
  if [ "$PKG_DISABLED" = true ]; then
    log "Skipping $PKG_NAME (disabled)"
    return 1
  fi

  # Skip-if-nonfree guard (gmp/nettle/gnutls vs openssl mutual exclusion)
  if [ "$PKG_SKIP_IF_NONFREE" = true ] && [ "$NONFREE" = true ]; then
    log "Skipping $PKG_NAME (nonfree path uses alternative)"
    return 1
  fi

  # GPL guard
  if [ "$PKG_GPL" = true ] && [ "$GPL" != true ]; then
    log "Skipping $PKG_NAME (requires --gpl)"
    return 1
  fi

  # Nonfree guard
  if [ "$PKG_NONFREE" = true ] && [ "$NONFREE" != true ]; then
    log "Skipping $PKG_NAME (requires --nonfree)"
    return 1
  fi

  # Required commands guard
  if [ -n "$PKG_REQUIRES_CMD" ]; then
    for _cmd in $PKG_REQUIRES_CMD; do
      if ! command_exists "$_cmd"; then
        warn "$_cmd not found — skipping $PKG_NAME"
        return 1
      fi
    done
  fi

  # Meson guard
  if [ "$PKG_REQUIRES_MESON" = true ]; then
    if ! command_exists meson || ! command_exists ninja; then
      warn "meson/ninja not found — skipping $PKG_NAME"
      return 1
    fi
  fi

  # Linux-only guard
  if [ "$PKG_LINUX_ONLY" = true ] && [ "$IS_LINUX" != true ]; then
    log "Skipping $PKG_NAME (Linux only)"
    return 1
  fi

  # Architecture guard
  if [ -n "$PKG_SKIP_ON_ARCH" ] && [ "$OS_ARCH" = "$PKG_SKIP_ON_ARCH" ]; then
    log "Skipping $PKG_NAME (not supported on $OS_ARCH)"
    return 1
  fi

  # LV2 disable guard
  # The entire LV2 dependency chain (serd, pcre, zix, sord, sratom, lilv)
  # is embedded in the single lv2.sh recipe, so guarding on PKG_NAME="lv2"
  # correctly skips all sub-dependencies.
  if [ "$DISABLE_LV2" = true ] && [ "$PKG_NAME" = "lv2" ]; then
    log "Skipping $PKG_NAME (--disable-lv2)"
    return 1
  fi

  return 0
}
```

- [ ] **Step 3: Add run_recipe() function**

```sh
# Run a single recipe file through the build lifecycle
run_recipe() {
  _recipe_path="$1"

  if [ ! -f "$_recipe_path" ]; then
    die "Recipe not found: $_recipe_path"
  fi

  # Reset state
  reset_recipe

  # Source the recipe to load its variables and phase overrides
  . "$_recipe_path"

  # Validate required fields (PKG_URL may be empty if PKG_SKIP_EXTRACT is true)
  if [ -z "$PKG_NAME" ] || [ -z "$PKG_VERSION" ]; then
    die "Recipe $_recipe_path missing required fields (PKG_NAME, PKG_VERSION)"
  fi
  if [ -z "$PKG_URL" ] && [ "$PKG_SKIP_EXTRACT" != true ]; then
    die "Recipe $_recipe_path missing PKG_URL (set PKG_SKIP_EXTRACT=true for header-only packages)"
  fi

  # Check guards
  if ! check_guards; then
    # Still accumulate ffmpeg option if the package was previously built
    if [ -n "$PKG_FFMPEG_OPT" ] && [ -f "$PACKAGES/$PKG_NAME.done" ]; then
      CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS $PKG_FFMPEG_OPT"
    fi
    return 0
  fi

  # Check done-file (build returns 1 if already built)
  if ! build "$PKG_NAME" "$PKG_VERSION"; then
    # Already built — accumulate ffmpeg option and skip
    if [ -n "$PKG_FFMPEG_OPT" ]; then
      CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS $PKG_FFMPEG_OPT"
    fi
    return 0
  fi

  # Set current package for trap handler
  set_current_package "$PKG_NAME"

  # Save compiler flags
  _saved_cflags="$CFLAGS"
  _saved_cxxflags="$CXXFLAGS"
  _saved_ldflags="$LDFLAGS"
  _saved_cppflags="$CPPFLAGS"
  _saved_dir=$(pwd)

  # Download and extract
  if [ "$PKG_SKIP_EXTRACT" != true ]; then
    _dl_file=""
    _dl_dir=""
    if [ -n "$PKG_FILENAME" ]; then
      _dl_file="$PKG_FILENAME"
    fi
    if [ -n "$PKG_DIRNAME" ]; then
      _dl_dir="$PKG_DIRNAME"
    fi
    download "$PKG_URL" "$_dl_file" "$_dl_dir"
  fi

  # Run phases
  pkg_prepare
  pkg_configure
  pkg_build
  pkg_install
  pkg_post_install

  # Mark as done
  build_done "$PKG_NAME" "$PKG_VERSION"

  # Accumulate ffmpeg configure option
  if [ -n "$PKG_FFMPEG_OPT" ]; then
    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS $PKG_FFMPEG_OPT"
  fi

  # Restore compiler flags
  CFLAGS="$_saved_cflags"
  CXXFLAGS="$_saved_cxxflags"
  LDFLAGS="$_saved_ldflags"
  CPPFLAGS="$_saved_cppflags"

  # Restore working directory
  cd "$_saved_dir" || die "Failed to restore working directory"

  set_current_package ""
}
```

- [ ] **Step 4: Verify POSIX compliance**

Run: `shellcheck -s sh lib/framework.sh`
Expected: SC2086 warnings on intentional word-splitting (disabled with comments)

- [ ] **Step 5: Commit**

```bash
git add lib/framework.sh
git commit -m "Add lib/framework.sh — recipe engine with phase runner"
```

---

### Task 6: Create `lib/install.sh`

**Files:**
- Create: `lib/install.sh`

- [ ] **Step 1: Create `lib/install.sh`**

```sh
#!/bin/sh
# Install ffmpeg binaries to system

# Determine install location
INSTALL_FOLDER="/usr"
if [ "$IS_DARWIN" = true ]; then
  INSTALL_FOLDER="/usr/local"
elif [ -d "$HOME/.local" ]; then
  INSTALL_FOLDER="$HOME/.local"
elif [ -d "/usr/local" ]; then
  INSTALL_FOLDER="/usr/local"
fi

# Decide whether to install
INSTALL_NOW=0
if [ "$AUTOINSTALL" = "yes" ]; then
  INSTALL_NOW=1
  log "Auto-installing binaries (--auto-install)."
elif [ "$SKIPINSTALL" = "yes" ]; then
  log "Skipping install (--skip-install)."
else
  printf '[mediaforge] Install binaries to %s? Existing binaries will be replaced. [Y/n] ' "$INSTALL_FOLDER"
  read -r response
  case "$response" in
    ""|[yY]|[yY][eE][sS])
      INSTALL_NOW=1
      ;;
  esac
fi

if [ "$INSTALL_NOW" = 1 ]; then
  # Determine if we need sudo
  SUDO=""
  case "$INSTALL_FOLDER" in
    /usr|/usr/*)
      if command_exists "sudo"; then
        SUDO=sudo
      fi
      ;;
  esac

  $SUDO cp "$WORKSPACE/bin/ffmpeg" "$INSTALL_FOLDER/bin/ffmpeg"
  $SUDO cp "$WORKSPACE/bin/ffprobe" "$INSTALL_FOLDER/bin/ffprobe"
  $SUDO cp "$WORKSPACE/bin/ffplay" "$INSTALL_FOLDER/bin/ffplay"

  if [ "$MANPAGES" = 1 ]; then
    $SUDO mkdir -p "$INSTALL_FOLDER/share/man/man1"
    $SUDO cp "$WORKSPACE/share/man/man1"/ff* "$INSTALL_FOLDER/share/man/man1/"
    if command_exists "mandb"; then
      $SUDO mandb -q
    fi
  fi

  log "FFmpeg installed to $INSTALL_FOLDER"
fi
```

- [ ] **Step 2: Verify POSIX compliance**

Run: `shellcheck -s sh lib/install.sh`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add lib/install.sh
git commit -m "Add lib/install.sh — binary install logic"
```

---

## Chunk 2: Driver Script and FFmpeg Build

### Task 7: Create `mediaforge.sh` driver

**Files:**
- Create: `mediaforge.sh`

- [ ] **Step 1: Create `mediaforge.sh` with header and library sourcing**

```sh
#!/usr/bin/env sh

SCRIPT_VERSION="2.0"
FFMPEG_VERSION="8.0.1"
PROGNAME=$(basename "$0")

# Resolve script's own directory (portable)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

CWD=$(pwd)
PACKAGES="$CWD/packages"
WORKSPACE="$CWD/workspace"

# Source libraries (order matters — utils first, platform needs command_exists)
. "$SCRIPT_DIR/lib/utils.sh"
. "$SCRIPT_DIR/lib/platform.sh"
. "$SCRIPT_DIR/lib/download.sh"
. "$SCRIPT_DIR/lib/cleanup.sh"
. "$SCRIPT_DIR/lib/framework.sh"

# Compiler flags
CFLAGS="-I$WORKSPACE/include"
CXXFLAGS="-I$WORKSPACE/include"
LDFLAGS="-L$WORKSPACE/lib"
LDEXEFLAGS=""
EXTRALIBS="-ldl -lpthread -lm -lz"
CONFIGURE_OPTIONS=""

# Feature flags
GPL=false
NONFREE=false
DISABLE_LV2=false
LATEST=false
MANPAGES=1
SKIPINSTALL=""
AUTOINSTALL=""
```

- [ ] **Step 2: Add usage function**

```sh
usage() {
  printf 'Usage: %s [OPTIONS]\n' "$PROGNAME"
  printf 'Options:\n'
  printf '  -h, --help                     Display usage information\n'
  printf '      --version                  Display version information\n'
  printf '  -b, --build                    Start the build process\n'
  printf '      --gpl                      Enable GPL-licensed codecs (x264, x265, etc.)\n'
  printf '      --nonfree                  Enable GPL + non-free codecs (implies --gpl)\n'
  printf '      --disable-lv2              Disable LV2 libraries\n'
  printf '  -c, --cleanup                  Remove all working dirs\n'
  printf '      --latest                   Build latest version if newer available\n'
  printf '      --small                    Prioritize small size; skip manpages\n'
  printf '      --full-static              Full static binary (Linux only)\n'
  printf '      --skip-install             Do not install binaries to system\n'
  printf '      --auto-install             Install binaries without prompting\n'
  printf '\n'
}
```

- [ ] **Step 3: Add argument parsing**

```sh
bflag=""
cflag=""

log "mediaforge v$SCRIPT_VERSION"
log "========================="

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --version)
      printf '%s\n' "$SCRIPT_VERSION"
      exit 0
      ;;
    -b|--build)
      bflag=yes
      ;;
    --gpl)
      GPL=true
      CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --enable-gpl"
      ;;
    --nonfree)
      NONFREE=true
      if [ "$GPL" != true ]; then
        GPL=true
        CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --enable-gpl"
      fi
      CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --enable-nonfree"
      ;;
    --disable-lv2)
      DISABLE_LV2=true
      ;;
    -c|--cleanup)
      cflag=yes
      ;;
    --latest)
      LATEST=true
      ;;
    --small)
      CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --enable-small --disable-doc"
      MANPAGES=0
      ;;
    --full-static)
      if [ "$IS_DARWIN" = true ]; then
        die "Full static binaries can only be built on Linux."
      fi
      LDEXEFLAGS="-static -fPIC"
      CFLAGS="$CFLAGS -fPIC"
      CXXFLAGS="$CXXFLAGS -fPIC"
      ;;
    --skip-install)
      if [ "$AUTOINSTALL" = "yes" ]; then
        die "--skip-install cannot be used with --auto-install"
      fi
      SKIPINSTALL=yes
      ;;
    --auto-install)
      if [ "$SKIPINSTALL" = "yes" ]; then
        die "--auto-install cannot be used with --skip-install"
      fi
      AUTOINSTALL=yes
      ;;
    *)
      warn "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

# Must specify an action
if [ -z "$bflag" ]; then
  if [ "$cflag" = "yes" ]; then
    full_cleanup
    exit 0
  fi
  usage
  exit 1
fi
```

- [ ] **Step 4: Add pre-flight checks and orchestration**

```sh
# Setup traps
setup_traps

# Pre-flight checks
command_exists "make" || die "make not installed"
command_exists "g++"  || die "g++ not installed"
command_exists "curl" || die "curl not installed"

command_exists "cargo"   || warn "cargo not installed — rav1e will be skipped"
command_exists "python3" || warn "python3 not installed — dav1d and lv2 will be skipped"

# Platform-specific setup
if [ "$IS_MACOS_SILICON" = true ]; then
  export ARCH=arm64
  export MACOSX_DEPLOYMENT_TARGET=11.0
  CXX=$(command -v clang++)
  export CXX
  command_exists "clang++" || die "clang++ not installed. Please install Xcode."
  log "Apple Silicon detected ($(sw_vers -productVersion))"
fi

MACOS_LIBTOOL=""
if [ "$IS_DARWIN" = true ]; then
  CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --enable-videotoolbox"
  MACOS_LIBTOOL="$(command -v libtool)"
fi

# Setup paths
mkdir -p "$PACKAGES" || die "Failed to create $PACKAGES"
mkdir -p "$WORKSPACE" || die "Failed to create $WORKSPACE"
export PATH="$WORKSPACE/bin:$PATH"

# Build pkg-config path dynamically
PKG_CONFIG_PATH="$WORKSPACE/lib/pkgconfig:/usr/local/lib/pkgconfig"
if [ -n "$MULTIARCH" ]; then
  PKG_CONFIG_PATH="$PKG_CONFIG_PATH:/usr/lib/$MULTIARCH/pkgconfig"
  PKG_CONFIG_PATH="$PKG_CONFIG_PATH:/usr/local/lib/$MULTIARCH/pkgconfig"
fi
PKG_CONFIG_PATH="$PKG_CONFIG_PATH:/usr/local/share/pkgconfig:/usr/lib/pkgconfig"
PKG_CONFIG_PATH="$PKG_CONFIG_PATH:/usr/share/pkgconfig:/usr/lib64/pkgconfig"
export PKG_CONFIG_PATH

log "Using $MJOBS parallel jobs"
if [ "$GPL" = true ]; then
  log "GPL codecs enabled"
fi
if [ "$NONFREE" = true ]; then
  log "Non-free codecs enabled"
fi
if [ -n "$LDEXEFLAGS" ]; then
  log "Full static mode"
fi

# Run all package recipes in order
while IFS= read -r _recipe || [ -n "$_recipe" ]; do
  case "$_recipe" in
    ""|\#*) continue ;;
  esac
  run_recipe "$SCRIPT_DIR/$_recipe"
done < "$SCRIPT_DIR/recipes/_order.conf"

# Read extra flags from accumulator files (written by recipes like lv2)
if [ -f "$WORKSPACE/.extra_cflags" ]; then
  while IFS= read -r _flag || [ -n "$_flag" ]; do
    CFLAGS="$CFLAGS $_flag"
  done < "$WORKSPACE/.extra_cflags"
fi

# Build FFmpeg
. "$SCRIPT_DIR/recipes/ffmpeg.sh"

# Install
. "$SCRIPT_DIR/lib/install.sh"

exit 0
```

- [ ] **Step 5: Make executable**

Run: `chmod +x mediaforge.sh`

- [ ] **Step 6: Verify POSIX compliance**

Run: `shellcheck -s sh mediaforge.sh`
Expected: No errors

- [ ] **Step 7: Commit**

```bash
git add mediaforge.sh
git commit -m "Add mediaforge.sh — main driver script"
```

---

### Task 8: Create `recipes/ffmpeg.sh`

**Files:**
- Create: `recipes/ffmpeg.sh`

- [ ] **Step 1: Create `recipes/ffmpeg.sh`**

```sh
#!/bin/sh
# Final FFmpeg build — consumes CONFIGURE_OPTIONS from all recipes

EXTRA_VERSION=""
if [ "$IS_DARWIN" = true ]; then
  EXTRA_VERSION="$FFMPEG_VERSION"
fi

log ""
log "Building FFmpeg $FFMPEG_VERSION"
log "======================="

download "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n${FFMPEG_VERSION}.tar.gz" \
  "FFmpeg-release-${FFMPEG_VERSION}.tar.gz"

print_flags

# Handle NVIDIA flags separately (may contain spaces)
_nvcc_opt=""
if [ -n "$NVCC_FLAGS" ]; then
  _nvcc_opt="$NVCC_FLAGS"
fi

# Prevent ffmpeg's version.sh from detecting the project's .git
# shellcheck disable=SC2086
GIT_DIR=/nonexistent \
execute ./configure $CONFIGURE_OPTIONS \
  $_nvcc_opt \
  --disable-debug \
  --disable-shared \
  --enable-pthreads \
  --enable-static \
  --enable-version3 \
  --extra-cflags="$CFLAGS" \
  --extra-ldexeflags="$LDEXEFLAGS" \
  --extra-ldflags="$LDFLAGS" \
  --extra-libs="$EXTRALIBS" \
  --pkgconfigdir="$WORKSPACE/lib/pkgconfig" \
  --pkg-config-flags="--static" \
  --prefix="$WORKSPACE" \
  --extra-version="$EXTRA_VERSION"

execute make -j "$MJOBS"
execute make install

# Verify the binary
if command_exists "file"; then
  _binary_type=$(file "$WORKSPACE/bin/ffmpeg" | sed 's/^.*: //')
  log ""
  log "Built binary: $_binary_type"
fi

log ""
log "Build complete. Binaries available at:"
log "  ffmpeg:  $WORKSPACE/bin/ffmpeg"
log "  ffprobe: $WORKSPACE/bin/ffprobe"
log "  ffplay:  $WORKSPACE/bin/ffplay"
```

- [ ] **Step 2: Verify POSIX compliance**

Run: `shellcheck -s sh recipes/ffmpeg.sh`
Expected: SC2086 on intentional word-splitting

- [ ] **Step 3: Commit**

```bash
git add recipes/ffmpeg.sh
git commit -m "Add recipes/ffmpeg.sh — final FFmpeg build"
```

---

## Chunk 3: Tool Recipes

All tool recipes go in `recipes/tools/`. These are the build toolchain packages.

Reference: original script lines 370-511.

### Task 9: Create tool recipes

**Files:**
- Create: `recipes/tools/giflib.sh`
- Create: `recipes/tools/pkg-config.sh`
- Create: `recipes/tools/yasm.sh`
- Create: `recipes/tools/nasm.sh`
- Create: `recipes/tools/zlib.sh`
- Create: `recipes/tools/m4.sh`
- Create: `recipes/tools/autoconf.sh`
- Create: `recipes/tools/automake.sh`
- Create: `recipes/tools/libtool.sh`
- Create: `recipes/tools/cmake.sh`

- [ ] **Step 1: Create `recipes/tools/giflib.sh`**

giflib has a custom build — no configure, patched Makefile. Needs full override.

```sh
PKG_NAME="giflib"
PKG_VERSION="5.2.2"
PKG_URL="https://sources.voidlinux.org/giflib-${PKG_VERSION}/giflib-${PKG_VERSION}.tar.gz"

pkg_configure() {
  # giflib has no configure — patch Makefile directly
  cd "$PACKAGES/giflib-${PKG_VERSION}" || die "Failed to cd to giflib"
  sed 's/$(MAKE) -C doc//g' Makefile > Makefile.tmp && mv Makefile.tmp Makefile
  sed 's/install: all install-bin install-include install-lib install-man/install: all install-bin install-include install-lib/g' Makefile > Makefile.tmp && mv Makefile.tmp Makefile
}

pkg_build() {
  execute make
}

pkg_install() {
  execute make PREFIX="$WORKSPACE" install
}
```

- [ ] **Step 2: Create `recipes/tools/pkg-config.sh`**

pkg-config needs GCC 15+ fix for bundled GLib and Darwin-specific CFLAGS.

```sh
PKG_NAME="pkg-config"
PKG_VERSION="0.29.2"
PKG_URL="https://pkgconfig.freedesktop.org/releases/pkg-config-${PKG_VERSION}.tar.gz"
PKG_CONFIGURE_FLAGS="--silent --with-pc-path=$WORKSPACE/lib/pkgconfig --with-internal-glib"

pkg_prepare() {
  # GCC 15+ fix: rename 'bool' field in bundled GLib
  sed 's/gboolean bool;/gboolean bool_val;/g' glib/glib/goption.c > glib/glib/goption.c.tmp \
    && mv glib/glib/goption.c.tmp glib/glib/goption.c
  sed 's/change->prev\.bool/change->prev.bool_val/g' glib/glib/goption.c > glib/glib/goption.c.tmp \
    && mv glib/glib/goption.c.tmp glib/glib/goption.c

  if [ "$IS_DARWIN" = true ]; then
    CFLAGS="$CFLAGS -Wno-int-conversion -Wno-error=int-conversion"
    export CFLAGS
  fi
}
```

- [ ] **Step 3: Create simple tool recipes (yasm, nasm, zlib, m4, autoconf, automake, libtool)**

These all follow the standard configure/make/install pattern — pure declarative.

`recipes/tools/yasm.sh`:
```sh
PKG_NAME="yasm"
PKG_VERSION="1.3.0"
PKG_URL="https://github.com/yasm/yasm/releases/download/v${PKG_VERSION}/yasm-${PKG_VERSION}.tar.gz"
PKG_CONFIGURE_FLAGS=""
```

`recipes/tools/nasm.sh`:
```sh
PKG_NAME="nasm"
PKG_VERSION="2.16.01"
PKG_URL="https://www.nasm.us/pub/nasm/releasebuilds/${PKG_VERSION}/nasm-${PKG_VERSION}.tar.xz"
```

`recipes/tools/zlib.sh`:
```sh
PKG_NAME="zlib"
PKG_VERSION="1.3.1"
PKG_URL="https://github.com/madler/zlib/releases/download/v${PKG_VERSION}/zlib-${PKG_VERSION}.tar.gz"

pkg_configure() {
  execute ./configure --static --prefix="$WORKSPACE"
}
```

`recipes/tools/m4.sh`:
```sh
PKG_NAME="m4"
PKG_VERSION="1.4.19"
PKG_URL="https://ftpmirror.gnu.org/gnu/m4/m4-${PKG_VERSION}.tar.gz"
PKG_CONFIGURE_FLAGS=""
```

`recipes/tools/autoconf.sh`:
```sh
PKG_NAME="autoconf"
PKG_VERSION="2.72"
PKG_URL="https://ftpmirror.gnu.org/gnu/autoconf/autoconf-${PKG_VERSION}.tar.gz"
PKG_CONFIGURE_FLAGS=""
```

`recipes/tools/automake.sh`:
```sh
PKG_NAME="automake"
PKG_VERSION="1.17"
PKG_URL="https://ftpmirror.gnu.org/gnu/automake/automake-${PKG_VERSION}.tar.gz"
PKG_CONFIGURE_FLAGS=""
```

`recipes/tools/libtool.sh`:
```sh
PKG_NAME="libtool"
PKG_VERSION="2.4.7"
PKG_URL="https://ftpmirror.gnu.org/libtool/libtool-${PKG_VERSION}.tar.gz"
```

- [ ] **Step 4: Create `recipes/tools/cmake.sh`**

cmake needs CXXFLAGS backup and custom configure flags.

```sh
PKG_NAME="cmake"
PKG_VERSION="3.31.7"
PKG_URL="https://github.com/Kitware/CMake/releases/download/v${PKG_VERSION}/cmake-${PKG_VERSION}.tar.gz"

pkg_configure() {
  CXXFLAGS="$CXXFLAGS -std=c++11"
  export CXXFLAGS
  execute ./configure --prefix="$WORKSPACE" --parallel="$MJOBS" -- -DCMAKE_USE_OPENSSL=OFF
}
```

- [ ] **Step 5: Verify all tool recipes**

Run: `for f in recipes/tools/*.sh; do shellcheck -s sh "$f"; done`
Expected: No errors

- [ ] **Step 6: Commit**

```bash
git add recipes/tools/
git commit -m "Add tool recipes: giflib, pkg-config, yasm, nasm, zlib, m4, autoconf, automake, libtool, cmake"
```

---

## Chunk 4: Crypto and Video Recipes

### Task 10: Create crypto recipes

**Files:**
- Create: `recipes/crypto/openssl.sh`
- Create: `recipes/crypto/gmp.sh`
- Create: `recipes/crypto/nettle.sh`
- Create: `recipes/crypto/gnutls.sh`
- Create: `recipes/other/gettext.sh`

Reference: original lines 457-500.

- [ ] **Step 1: Create crypto recipes**

`recipes/other/gettext.sh`:
```sh
PKG_NAME="gettext"
PKG_VERSION="0.22.5"
PKG_URL="https://ftpmirror.gnu.org/gettext/gettext-${PKG_VERSION}.tar.gz"
PKG_NONFREE=true
```

`recipes/crypto/openssl.sh`:
```sh
PKG_NAME="openssl"
PKG_VERSION="3.5.4"
PKG_URL="https://github.com/openssl/openssl/archive/refs/tags/openssl-${PKG_VERSION}.tar.gz"
PKG_FILENAME="openssl-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-openssl"
PKG_NONFREE=true

pkg_configure() {
  execute ./Configure --prefix="$WORKSPACE" --openssldir="$WORKSPACE" --libdir="lib" \
    --with-zlib-include="$WORKSPACE/include/" --with-zlib-lib="$WORKSPACE/lib" \
    no-shared zlib
}

pkg_install() {
  execute make install_sw
}
```

`recipes/crypto/gmp.sh`:
```sh
PKG_NAME="gmp"
PKG_VERSION="6.3.0"
PKG_URL="https://ftpmirror.gnu.org/gnu/gmp/gmp-${PKG_VERSION}.tar.xz"
```

`recipes/crypto/nettle.sh`:
```sh
PKG_NAME="nettle"
PKG_VERSION="3.10.2"
PKG_URL="https://ftpmirror.gnu.org/gnu/nettle/nettle-${PKG_VERSION}.tar.gz"
PKG_CONFIGURE_FLAGS="--disable-openssl --disable-documentation --libdir=$WORKSPACE/lib"

pkg_configure() {
  # shellcheck disable=SC2086
  execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static \
    $PKG_CONFIGURE_FLAGS CPPFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
}
```

`recipes/crypto/gnutls.sh`:
```sh
PKG_NAME="gnutls"
PKG_VERSION="3.8.11"
PKG_URL="https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-${PKG_VERSION}.tar.xz"
PKG_SKIP_ON_ARCH="arm64"

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static \
    --disable-doc --disable-tools --disable-cxx --disable-tests \
    --disable-gtk-doc-html --disable-libdane --disable-nls \
    --enable-local-libopts --disable-guile --with-included-libtasn1 \
    --with-included-unistring --without-p11-kit \
    CPPFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
}
```

openssl + gettext are gated by `PKG_NONFREE=true`. gmp, nettle, gnutls use `PKG_SKIP_IF_NONFREE=true` to implement the mutual exclusion (they provide the TLS stack as an alternative to openssl).

Update `recipes/crypto/gmp.sh` — add `PKG_SKIP_IF_NONFREE=true`:
```sh
PKG_NAME="gmp"
PKG_VERSION="6.3.0"
PKG_URL="https://ftpmirror.gnu.org/gnu/gmp/gmp-${PKG_VERSION}.tar.xz"
PKG_SKIP_IF_NONFREE=true
```

Update `recipes/crypto/nettle.sh` — add `PKG_SKIP_IF_NONFREE=true` after the `PKG_URL` line.

Update `recipes/crypto/gnutls.sh` — add `PKG_SKIP_IF_NONFREE=true` after the `PKG_URL` line.

The `PKG_SKIP_IF_NONFREE` and `PKG_DISABLED` guards were already added to `reset_recipe()` and `check_guards()` in Task 5.

- [ ] **Step 3: Verify crypto recipes**

Run: `for f in recipes/crypto/*.sh; do shellcheck -s sh "$f"; done`
Expected: No errors

- [ ] **Step 4: Commit**

```bash
git add recipes/crypto/ lib/framework.sh
git commit -m "Add crypto recipes: gettext, openssl, gmp, nettle, gnutls with mutual exclusion"
```

---

### Task 11: Create video recipes

**Files:**
- Create: `recipes/video/dav1d.sh`
- Create: `recipes/video/svtav1.sh`
- Create: `recipes/video/rav1e.sh`
- Create: `recipes/video/x264.sh`
- Create: `recipes/video/x265.sh`
- Create: `recipes/video/libvpx.sh`
- Create: `recipes/video/xvidcore.sh`
- Create: `recipes/video/vid_stab.sh`
- Create: `recipes/video/av1.sh`
- Create: `recipes/video/zimg.sh`

Reference: original lines 549-743.

- [ ] **Step 1: Create meson-based video recipes (dav1d)**

`recipes/video/dav1d.sh`:
```sh
PKG_NAME="dav1d"
PKG_VERSION="1.5.3"
PKG_URL="https://code.videolan.org/videolan/dav1d/-/archive/${PKG_VERSION}/dav1d-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libdav1d"
PKG_REQUIRES_CMD="python3"
PKG_REQUIRES_MESON=true

pkg_configure() {
  _cflagsbackup="$CFLAGS"
  if [ "$IS_MACOS_SILICON" = true ]; then
    export CFLAGS="-arch arm64"
  fi
  make_dir build
  execute meson build --prefix="$WORKSPACE" --buildtype=release \
    --default-library=static --libdir="$WORKSPACE/lib"
  if [ "$IS_MACOS_SILICON" = true ]; then
    export CFLAGS="$_cflagsbackup"
  fi
}

pkg_build() {
  execute ninja -C build
}

pkg_install() {
  execute ninja -C build install
}
```

- [ ] **Step 2: Create cmake/cargo video recipes (svtav1, rav1e)**

`recipes/video/svtav1.sh`:
```sh
PKG_NAME="svtav1"
PKG_VERSION="3.1.2"
PKG_URL="https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v${PKG_VERSION}/SVT-AV1-v${PKG_VERSION}.tar.gz"
PKG_FILENAME="svtav1-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libsvtav1"
PKG_CMAKE=true

pkg_configure() {
  cd "$PACKAGES/svtav1-${PKG_VERSION}/Build/linux" || die "Failed to cd to SVT-AV1 build dir"
  execute cmake -DCMAKE_INSTALL_PREFIX="$WORKSPACE" -DENABLE_SHARED=off \
    -DBUILD_SHARED_LIBS=OFF ../.. -G"Unix Makefiles" -DCMAKE_BUILD_TYPE=Release
}

pkg_post_install() {
  execute cp SvtAv1Enc.pc "$WORKSPACE/lib/pkgconfig/"
}
```

`recipes/video/rav1e.sh` — uses `PKG_DISABLED` for `SKIPRAV1E` env var support:

```sh
PKG_NAME="rav1e"
PKG_VERSION="0.8.1"
PKG_URL="https://github.com/xiph/rav1e/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-librav1e"
PKG_REQUIRES_CMD="cargo"

if [ "$SKIPRAV1E" = "yes" ]; then
  PKG_DISABLED=true
fi

pkg_prepare() {
  log "If you get 'requires rustc x.xx or newer', try 'rustup update'"
  execute cargo install cargo-c
}

pkg_configure() {
  export RUSTFLAGS="-C target-cpu=native"
}

pkg_build() {
  :
}

pkg_install() {
  execute cargo cinstall --prefix="$WORKSPACE" --libdir=lib \
    --library-type=staticlib --crt-static --release
}
```

- [ ] **Step 4: Create GPL video recipes (x264, x265, xvidcore, vid_stab)**

`recipes/video/x264.sh`:
```sh
PKG_NAME="x264"
PKG_VERSION="0480cb05"
PKG_URL="https://code.videolan.org/videolan/x264/-/archive/${PKG_VERSION}/x264-${PKG_VERSION}.tar.gz"
PKG_FILENAME="x264-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libx264"
PKG_GPL=true

pkg_configure() {
  if [ "$IS_LINUX" = true ]; then
    execute ./configure --prefix="$WORKSPACE" --enable-static --enable-pic \
      CXXFLAGS="-fPIC $CXXFLAGS"
  else
    execute ./configure --prefix="$WORKSPACE" --enable-static --enable-pic
  fi
}

pkg_post_install() {
  execute make install-lib-static
}
```

`recipes/video/x265.sh`:
```sh
PKG_NAME="x265"
PKG_VERSION="4.1"
PKG_URL="https://bitbucket.org/multicoreware/x265_git/downloads/x265_${PKG_VERSION}.tar.gz"
PKG_FILENAME="x265-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libx265"
PKG_GPL=true

pkg_configure() {
  :
}

pkg_build() {
  cd build/linux || die "Failed to cd to build/linux"
  rm -rf 8bit 10bit 12bit 2>/dev/null
  mkdir -p 8bit 10bit 12bit

  cd 12bit || die "Failed to cd to 12bit"
  execute cmake ../../../source -DCMAKE_INSTALL_PREFIX="$WORKSPACE" \
    -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF -DHIGH_BIT_DEPTH=ON \
    -DENABLE_HDR10_PLUS=ON -DEXPORT_C_API=OFF -DENABLE_CLI=OFF -DMAIN12=ON
  execute make -j "$MJOBS"

  cd ../10bit || die "Failed to cd to 10bit"
  execute cmake ../../../source -DCMAKE_INSTALL_PREFIX="$WORKSPACE" \
    -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF -DHIGH_BIT_DEPTH=ON \
    -DENABLE_HDR10_PLUS=ON -DEXPORT_C_API=OFF -DENABLE_CLI=OFF
  execute make -j "$MJOBS"

  cd ../8bit || die "Failed to cd to 8bit"
  ln -sf ../10bit/libx265.a libx265_main10.a
  ln -sf ../12bit/libx265.a libx265_main12.a
  execute cmake ../../../source -DCMAKE_INSTALL_PREFIX="$WORKSPACE" \
    -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF \
    -DEXTRA_LIB="x265_main10.a;x265_main12.a;-ldl" \
    -DEXTRA_LINK_FLAGS=-L. -DLINKED_10BIT=ON -DLINKED_12BIT=ON
  execute make -j "$MJOBS"

  mv libx265.a libx265_main.a

  if [ "$IS_DARWIN" = true ]; then
    execute "$MACOS_LIBTOOL" -static -o libx265.a \
      libx265_main.a libx265_main10.a libx265_main12.a 2>/dev/null
  else
    execute_stdin ar -M <<EOF
CREATE libx265.a
ADDLIB libx265_main.a
ADDLIB libx265_main10.a
ADDLIB libx265_main12.a
SAVE
END
EOF
  fi
}

pkg_install() {
  execute make install
}

pkg_post_install() {
  if [ -n "$LDEXEFLAGS" ]; then
    sed 's/-lgcc_s/-lgcc_eh/g' "$WORKSPACE/lib/pkgconfig/x265.pc" \
      > "$WORKSPACE/lib/pkgconfig/x265.pc.tmp" \
      && mv "$WORKSPACE/lib/pkgconfig/x265.pc.tmp" "$WORKSPACE/lib/pkgconfig/x265.pc"
  fi
}
```

`recipes/video/xvidcore.sh`:
```sh
PKG_NAME="xvidcore"
PKG_VERSION="1.3.7"
PKG_URL="https://downloads.xvid.com/downloads/xvidcore-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libxvid"
PKG_GPL=true

pkg_configure() {
  cd build/generic || die "Failed to cd to build/generic"
  execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static
}

pkg_post_install() {
  if [ -f "$WORKSPACE/lib/libxvidcore.4.dylib" ]; then
    rm -f "$WORKSPACE/lib/libxvidcore.4.dylib"
  fi
  if [ -f "$WORKSPACE/lib/libxvidcore.so" ]; then
    rm -f "$WORKSPACE"/lib/libxvidcore.so*
  fi
}
```

`recipes/video/vid_stab.sh`:
```sh
PKG_NAME="vid_stab"
PKG_VERSION="1.1.1"
PKG_URL="https://github.com/georgmartius/vid.stab/archive/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="vid.stab-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libvidstab"
PKG_GPL=true
PKG_CMAKE=true
PKG_CMAKE_FLAGS="-DUSE_OMP=OFF -DENABLE_SHARED=off"

pkg_prepare() {
  if [ "$IS_MACOS_SILICON" = true ]; then
    curl -L -sS -o fix_cmake_quoting.patch \
      "https://raw.githubusercontent.com/Homebrew/formula-patches/5bf1a0e0cfe666ee410305cece9c9c755641bfdf/libvidstab/fix_cmake_quoting.patch"
    patch -p1 < fix_cmake_quoting.patch
  fi
}
```

- [ ] **Step 5: Create remaining video recipes (libvpx, av1, zimg)**

`recipes/video/libvpx.sh`:
```sh
PKG_NAME="libvpx"
PKG_VERSION="1.15.2"
PKG_URL="https://github.com/webmproject/libvpx/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="libvpx-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libvpx"

pkg_prepare() {
  if [ "$IS_DARWIN" = true ]; then
    log "Applying Darwin patch"
    sed "s/,--version-script//g" build/make/Makefile > build/make/Makefile.tmp \
      && mv build/make/Makefile.tmp build/make/Makefile
    sed "s/-Wl,--no-undefined -Wl,-soname/-Wl,-undefined,error -Wl,-install_name/g" \
      build/make/Makefile > build/make/Makefile.tmp \
      && mv build/make/Makefile.tmp build/make/Makefile
  fi
}

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" --disable-unit-tests --disable-shared \
    --disable-examples --as=yasm --enable-vp9-highbitdepth
}
```

`recipes/video/av1.sh`:
```sh
PKG_NAME="av1"
PKG_VERSION="d772e334cc724105040382a977ebb10dfd393293"
PKG_URL="https://aomedia.googlesource.com/aom/+archive/${PKG_VERSION}.tar.gz"
PKG_FILENAME="av1.tar.gz"
PKG_DIRNAME="av1"
PKG_FFMPEG_OPT="--enable-libaom"

pkg_configure() {
  make_dir "$PACKAGES/aom_build"
  cd "$PACKAGES/aom_build" || die "Failed to cd to aom_build"
  if [ "$IS_MACOS_SILICON" = true ]; then
    execute cmake -DENABLE_TESTS=0 -DENABLE_EXAMPLES=0 \
      -DCMAKE_INSTALL_PREFIX="$WORKSPACE" -DCMAKE_INSTALL_LIBDIR=lib \
      -DCONFIG_RUNTIME_CPU_DETECT=0 "$PACKAGES/av1"
  else
    execute cmake -DENABLE_TESTS=0 -DENABLE_EXAMPLES=0 \
      -DCMAKE_INSTALL_PREFIX="$WORKSPACE" -DCMAKE_INSTALL_LIBDIR=lib \
      "$PACKAGES/av1"
  fi
}
```

`recipes/video/zimg.sh`:
```sh
PKG_NAME="zimg"
PKG_VERSION="3.0.6"
PKG_URL="https://github.com/sekrit-twc/zimg/archive/refs/tags/release-${PKG_VERSION}.tar.gz"
PKG_FILENAME="zimg-${PKG_VERSION}.tar.gz"
PKG_DIRNAME="zimg"
PKG_FFMPEG_OPT="--enable-libzimg"

pkg_prepare() {
  cd "zimg-release-${PKG_VERSION}" || die "Failed to cd to zimg source"
  execute "$WORKSPACE/bin/libtoolize" -i -f -q
  execute ./autogen.sh --prefix="$WORKSPACE"
}
```

- [ ] **Step 6: Verify all video recipes**

Run: `for f in recipes/video/*.sh; do shellcheck -s sh "$f"; done`
Expected: No errors (SC2086 on intentional word-splitting acceptable)

- [ ] **Step 7: Commit**

```bash
git add recipes/video/ lib/framework.sh
git commit -m "Add video recipes: dav1d, svtav1, rav1e, x264, x265, libvpx, xvidcore, vid_stab, av1, zimg"
```

---

## Chunk 5: Audio, Image, HWAccel, and Other Recipes

### Task 12: Create audio recipes

**Files:**
- Create: `recipes/audio/lv2.sh`
- Create: `recipes/audio/opencore.sh`
- Create: `recipes/audio/lame.sh`
- Create: `recipes/audio/opus.sh`
- Create: `recipes/audio/libogg.sh`
- Create: `recipes/audio/libvorbis.sh`
- Create: `recipes/audio/libtheora.sh`
- Create: `recipes/audio/fdk_aac.sh`
- Create: `recipes/audio/soxr.sh`

Reference: original lines 748-888.

- [ ] **Step 1: Create LV2 mega-recipe**

LV2 and its dependencies (serd, pcre, zix, sord, sratom, lilv, waflib) are tightly coupled. Bundle them into one recipe with a custom build that chains all sub-builds.

`recipes/audio/lv2.sh`:
```sh
PKG_NAME="lv2"
PKG_VERSION="1.18.10"
PKG_URL="https://lv2plug.in/spec/lv2-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-lv2"
PKG_REQUIRES_CMD="python3"
PKG_REQUIRES_MESON=true

pkg_configure() {
  # Build lv2 itself
  execute meson build --prefix="$WORKSPACE" --buildtype=release \
    --default-library=static --libdir="$WORKSPACE/lib"
}

pkg_build() {
  execute ninja -C build
}

pkg_install() {
  execute ninja -C build install

  # Now build all LV2 sub-dependencies
  _lv2_saved_dir=$(pwd)

  # waflib
  if build "waflib" "b600c92"; then
    download "https://gitlab.com/drobilla/autowaf/-/archive/b600c92/autowaf-b600c92.tar.gz" "autowaf.tar.gz"
    build_done "waflib" "b600c92"
  fi

  # serd
  if build "serd" "0.32.6"; then
    download "https://gitlab.com/drobilla/serd/-/archive/v0.32.6/serd-v0.32.6.tar.gz" "serd-v0.32.6.tar.gz"
    execute meson build --prefix="$WORKSPACE" --buildtype=release \
      --default-library=static --libdir="$WORKSPACE/lib"
    execute ninja -C build
    execute ninja -C build install
    build_done "serd" "0.32.6"
  fi

  # pcre
  if build "pcre" "8.45"; then
    download "https://altushost-swe.dl.sourceforge.net/project/pcre/pcre/8.45/pcre-8.45.tar.gz" "pcre-8.45.tar.gz"
    execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static
    execute make -j "$MJOBS"
    execute make install
    build_done "pcre" "8.45"
  fi

  # zix
  if build "zix" "0.8.0"; then
    download "https://gitlab.com/drobilla/zix/-/archive/v0.8.0/zix-v0.8.0.tar.gz" "zix-v0.8.0.tar.gz"
    execute meson setup build --prefix="$WORKSPACE" --buildtype=release \
      --default-library=static --libdir="$WORKSPACE/lib"
    cd build || die "Failed to cd to zix build"
    execute meson configure -Dc_args="-march=native" -Dprefix="$WORKSPACE" -Dlibdir="$WORKSPACE/lib"
    execute meson compile
    execute meson install
    build_done "zix" "0.8.0"
  fi

  # sord
  if build "sord" "0.16.20"; then
    download "https://gitlab.com/drobilla/sord/-/archive/v0.16.20/sord-v0.16.20.tar.gz" "sord-v0.16.20.tar.gz"
    execute meson build --prefix="$WORKSPACE" --buildtype=release \
      --default-library=static --libdir="$WORKSPACE/lib"
    execute ninja -C build
    execute ninja -C build install
    build_done "sord" "0.16.20"
  fi

  # sratom
  if build "sratom" "0.6.20"; then
    download "https://gitlab.com/lv2/sratom/-/archive/v0.6.20/sratom-v0.6.20.tar.gz" "sratom-v0.6.20.tar.gz"
    execute meson build --prefix="$WORKSPACE" -Ddocs=disabled --buildtype=release \
      --default-library=static --libdir="$WORKSPACE/lib"
    execute ninja -C build
    execute ninja -C build install
    build_done "sratom" "0.6.20"
  fi

  # lilv
  if build "lilv" "0.26.2"; then
    download "https://gitlab.com/lv2/lilv/-/archive/v0.26.2/lilv-v0.26.2.tar.gz" "lilv-v0.26.2.tar.gz"
    execute meson build --prefix="$WORKSPACE" -Ddocs=disabled --buildtype=release \
      --default-library=static --libdir="$WORKSPACE/lib" -Dcpp_std=c++11
    execute ninja -C build
    execute ninja -C build install
    build_done "lilv" "0.26.2"
  fi

  cd "$_lv2_saved_dir" || die "Failed to restore dir after lv2 sub-builds"
}

pkg_post_install() {
  # Add lilv include path for ffmpeg
  printf '%s\n' "-I$WORKSPACE/include/lilv-0" >> "$WORKSPACE/.extra_cflags"
}
```

- [ ] **Step 2: Create simple audio recipes**

`recipes/audio/opencore.sh`:
```sh
PKG_NAME="opencore"
PKG_VERSION="0.1.6"
PKG_URL="https://deac-ams.dl.sourceforge.net/project/opencore-amr/opencore-amr/opencore-amr-${PKG_VERSION}.tar.gz"
PKG_FILENAME="opencore-amr-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libopencore_amrnb --enable-libopencore_amrwb"
```

`recipes/audio/lame.sh`:
```sh
PKG_NAME="lame"
PKG_VERSION="3.100"
PKG_URL="https://sourceforge.net/projects/lame/files/lame/${PKG_VERSION}/lame-${PKG_VERSION}.tar.gz/download?use_mirror=gigenet"
PKG_FILENAME="lame-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libmp3lame"
```

`recipes/audio/opus.sh`:
```sh
PKG_NAME="opus"
PKG_VERSION="1.6"
PKG_URL="https://downloads.xiph.org/releases/opus/opus-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libopus"
```

`recipes/audio/libogg.sh`:
```sh
PKG_NAME="libogg"
PKG_VERSION="1.3.6"
PKG_URL="https://ftp.osuosl.org/pub/xiph/releases/ogg/libogg-${PKG_VERSION}.tar.xz"
```

`recipes/audio/libvorbis.sh`:
```sh
PKG_NAME="libvorbis"
PKG_VERSION="1.3.7"
PKG_URL="https://ftp.osuosl.org/pub/xiph/releases/vorbis/libvorbis-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libvorbis"

pkg_prepare() {
  sed "s/-force_cpusubtype_ALL//g" configure.ac > configure.ac.tmp \
    && mv configure.ac.tmp configure.ac
  execute ./autogen.sh --prefix="$WORKSPACE"
}

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" \
    --with-ogg-libraries="$WORKSPACE/lib" \
    --with-ogg-includes="$WORKSPACE/include/" \
    --enable-static --disable-shared --disable-oggtest
}
```

`recipes/audio/libtheora.sh`:
```sh
PKG_NAME="libtheora"
PKG_VERSION="1.2.0"
PKG_URL="https://ftp.osuosl.org/pub/xiph/releases/theora/libtheora-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libtheora"

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" \
    --with-ogg-libraries="$WORKSPACE/lib" \
    --with-ogg-includes="$WORKSPACE/include/" \
    --with-vorbis-libraries="$WORKSPACE/lib" \
    --with-vorbis-includes="$WORKSPACE/include/" \
    --enable-static --disable-shared \
    --disable-oggtest --disable-vorbistest \
    --disable-examples --disable-spec
}
```

`recipes/audio/fdk_aac.sh`:
```sh
PKG_NAME="fdk_aac"
PKG_VERSION="2.0.3"
PKG_URL="https://sourceforge.net/projects/opencore-amr/files/fdk-aac/fdk-aac-${PKG_VERSION}.tar.gz/download?use_mirror=gigenet"
PKG_FILENAME="fdk-aac-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libfdk-aac"
PKG_NONFREE=true
PKG_CONFIGURE_FLAGS="--enable-pic"
```

`recipes/audio/soxr.sh`:
```sh
PKG_NAME="soxr"
PKG_VERSION="0.1.3"
PKG_URL="https://sourceforge.net/projects/soxr/files/soxr-${PKG_VERSION}-Source.tar.xz/download?use_mirror=gigenet"
PKG_FILENAME="soxr-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-libsoxr"
PKG_CMAKE=true

pkg_configure() {
  mkdir build && cd build || die "Failed to create/enter soxr build dir"
  execute cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$WORKSPACE" \
    -DBUILD_SHARED_LIBS:bool=off -DWITH_OPENMP:bool=off \
    -DBUILD_TESTS:bool=off -Wno-dev ..
}
```

- [ ] **Step 3: Commit audio recipes**

```bash
git add recipes/audio/
git commit -m "Add audio recipes: lv2 chain, opencore, lame, opus, libogg, libvorbis, libtheora, fdk_aac, soxr"
```

---

### Task 13: Create image recipes

**Files:**
- Create: `recipes/image/libtiff.sh`
- Create: `recipes/image/libpng.sh`
- Create: `recipes/image/libjxl.sh`
- Create: `recipes/image/libwebp.sh`

Reference: original lines 894-938.

- [ ] **Step 1: Create image recipes**

`recipes/image/libtiff.sh`:
```sh
PKG_NAME="libtiff"
PKG_VERSION="4.7.1"
PKG_URL="https://download.osgeo.org/libtiff/tiff-${PKG_VERSION}.tar.xz"
PKG_CONFIGURE_FLAGS="--disable-dependency-tracking --disable-lzma --disable-webp --disable-zstd --without-x"
```

`recipes/image/libpng.sh`:
```sh
PKG_NAME="libpng"
PKG_VERSION="1.6.53"
PKG_URL="https://sourceforge.net/projects/libpng/files/libpng16/${PKG_VERSION}/libpng-${PKG_VERSION}.tar.gz"
PKG_FILENAME="libpng-${PKG_VERSION}.tar.gz"

pkg_configure() {
  export LDFLAGS="$LDFLAGS"
  export CPPFLAGS="$CFLAGS"
  execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static
}
```

`recipes/image/libjxl.sh`:
```sh
PKG_NAME="libjxl"
PKG_VERSION="0.11.1"
PKG_URL="https://github.com/libjxl/libjxl/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="libjxl-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libjxl"

pkg_prepare() {
  # Fix pkg-config for threads lib
  sed "s/-ljxl_threads/-ljxl_threads @JPEGXL_THREADS_PUBLIC_LIBS@/g" \
    lib/threads/libjxl_threads.pc.in > lib/threads/libjxl_threads.pc.in.tmp \
    && mv lib/threads/libjxl_threads.pc.in.tmp lib/threads/libjxl_threads.pc.in

  # Add thread public libs
  _nl='
'
  sed "s/set(JPEGXL_REQUIRES_TYPE \"Requires\")/set(JPEGXL_REQUIRES_TYPE \"Requires\")${_nl}  set(JPEGXL_THREADS_PUBLIC_LIBS \"-lm \${PKGCONFIG_CXX_LIB}\")/g" \
    lib/jxl_threads.cmake > lib/jxl_threads.cmake.tmp \
    && mv lib/jxl_threads.cmake.tmp lib/jxl_threads.cmake

  execute ./deps.sh
}

pkg_configure() {
  execute cmake -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX="$WORKSPACE" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_BINDIR=bin \
    -DCMAKE_INSTALL_INCLUDEDIR=include -DENABLE_SHARED=off -DENABLE_STATIC=ON \
    -DCMAKE_BUILD_TYPE=Release -DJPEGXL_ENABLE_BENCHMARK=OFF \
    -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF \
    -DJPEGXL_ENABLE_JPEGLI_LIBJPEG=OFF -DJPEGXL_ENABLE_JPEGLI=ON \
    -DJPEGXL_TEST_TOOLS=OFF -DJPEGXL_ENABLE_JNI=OFF \
    -DBUILD_TESTING=OFF .
}
```

`recipes/image/libwebp.sh`:
```sh
PKG_NAME="libwebp"
PKG_VERSION="1.6.0"
PKG_URL="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${PKG_VERSION}.tar.gz"
PKG_FILENAME="libwebp-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libwebp"

pkg_configure() {
  make_dir build
  cd build || die "Failed to cd to libwebp build dir"
  execute cmake -DCMAKE_INSTALL_PREFIX="$WORKSPACE" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_BINDIR=bin \
    -DCMAKE_INSTALL_INCLUDEDIR=include -DENABLE_SHARED=OFF -DENABLE_STATIC=ON \
    -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
    -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF ../
}
```

- [ ] **Step 2: Commit image recipes**

```bash
git add recipes/image/
git commit -m "Add image recipes: libtiff, libpng, libjxl, libwebp"
```

---

### Task 14: Create hwaccel recipes

**Files:**
- Create: `recipes/hwaccel/vulkan-headers.sh`
- Create: `recipes/hwaccel/glslang.sh`
- Create: `recipes/hwaccel/nv-codec.sh`
- Create: `recipes/hwaccel/vaapi.sh`
- Create: `recipes/hwaccel/amf.sh`
- Create: `recipes/hwaccel/opencl.sh`

Reference: original lines 1022-1093.

- [ ] **Step 1: Create hwaccel recipes**

`recipes/hwaccel/vulkan-headers.sh`:
```sh
PKG_NAME="vulkan-headers"
PKG_VERSION="1.4.338"
PKG_URL="https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="Vulkan-Headers-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-vulkan"

pkg_configure() {
  execute cmake -DCMAKE_INSTALL_PREFIX="$WORKSPACE" -B build/
}

pkg_build() {
  :
}

pkg_install() {
  execute cmake --install build --prefix "$WORKSPACE"
}
```

`recipes/hwaccel/glslang.sh`:
```sh
PKG_NAME="glslang"
PKG_VERSION="16.1.0"
PKG_URL="https://github.com/KhronosGroup/glslang/archive/refs/tags/${PKG_VERSION}.tar.gz"
PKG_FILENAME="glslang-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libglslang"
PKG_REQUIRES_CMD="python3"

pkg_prepare() {
  execute ./update_glslang_sources.py
}

pkg_configure() {
  execute cmake -DCMAKE_BUILD_TYPE=Release -DENABLE_SHARED=OFF \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX="$WORKSPACE" .
}
```

`recipes/hwaccel/nv-codec.sh`:
```sh
PKG_NAME="nv-codec"
PKG_VERSION="11.1.5.3"
PKG_URL="https://github.com/FFmpeg/nv-codec-headers/releases/download/n${PKG_VERSION}/nv-codec-headers-${PKG_VERSION}.tar.gz"
PKG_LINUX_ONLY=true
PKG_REQUIRES_CMD="nvcc"

pkg_configure() {
  :
}

pkg_build() {
  execute make PREFIX="$WORKSPACE"
}

pkg_install() {
  execute make PREFIX="$WORKSPACE" install
}

pkg_post_install() {
  # Use accumulator files since framework restores CFLAGS/LDFLAGS after each recipe
  printf '%s\n' "-I/usr/local/cuda/include" >> "$WORKSPACE/.extra_cflags"
  printf '%s\n' "-L/usr/local/cuda/lib64" >> "$WORKSPACE/.extra_ldflags"

  # CONFIGURE_OPTIONS is not saved/restored, so direct modification persists
  CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --enable-cuda-nvcc --enable-cuvid --enable-nvdec --enable-nvenc --enable-cuda-llvm --enable-ffnvcodec"

  # NVCC_FLAGS is also not saved/restored — it persists for ffmpeg.sh
  _cuda_cc="${CUDA_COMPUTE_CAPABILITY:-52}"
  NVCC_FLAGS="--nvccflags=-gencode arch=compute_${_cuda_cc},code=sm_${_cuda_cc} -O2"
}
```

`recipes/hwaccel/vaapi.sh`:
```sh
PKG_NAME="vaapi"
PKG_VERSION="1"
PKG_URL=""
PKG_FFMPEG_OPT="--enable-vaapi"
PKG_LINUX_ONLY=true
PKG_SKIP_EXTRACT=true

pkg_configure() { :; }
pkg_build() { :; }
pkg_install() { :; }

# Only enable if libva exists and not in full-static mode
pkg_prepare() {
  if [ -n "$LDEXEFLAGS" ]; then
    log "Skipping vaapi (incompatible with --full-static)"
    PKG_FFMPEG_OPT=""
    return 0
  fi
  if ! library_exists "libva"; then
    log "Skipping vaapi (libva not found)"
    PKG_FFMPEG_OPT=""
    return 0
  fi
}
```

`recipes/hwaccel/amf.sh`:
```sh
PKG_NAME="amf"
PKG_VERSION="1.5.0"
PKG_URL="https://github.com/GPUOpen-LibrariesAndSDKs/AMF/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="AMF-${PKG_VERSION}.tar.gz"
PKG_DIRNAME="AMF-${PKG_VERSION}"
PKG_FFMPEG_OPT="--enable-amf"
PKG_LINUX_ONLY=true

pkg_configure() { :; }
pkg_build() { :; }

pkg_install() {
  rm -rf "$WORKSPACE/include/AMF"
  mkdir -p "$WORKSPACE/include/AMF" || die "Failed to create AMF include dir"
  cp -r "$PACKAGES/AMF-${PKG_VERSION}/AMF-${PKG_VERSION}/amf/public/include/"* \
    "$WORKSPACE/include/AMF/"
}
```

`recipes/hwaccel/opencl.sh`:
```sh
PKG_NAME="opencl"
PKG_VERSION="2025.07.22"
PKG_URL="https://github.com/KhronosGroup/OpenCL-Headers/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="OpenCL-Headers-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-opencl"
PKG_LINUX_ONLY=true

pkg_configure() {
  execute cmake -DCMAKE_INSTALL_PREFIX="$WORKSPACE" -B build/
}

pkg_build() {
  execute cmake --build build --target install
}

pkg_install() {
  # Now build ICD loader
  if build "opencl-icd-loader" "$PKG_VERSION"; then
    download "https://github.com/KhronosGroup/OpenCL-ICD-Loader/archive/refs/tags/v${PKG_VERSION}.tar.gz" \
      "OpenCL-ICD-Loader-${PKG_VERSION}.tar.gz"
    execute cmake -DCMAKE_PREFIX_PATH="$WORKSPACE" -DCMAKE_INSTALL_PREFIX="$WORKSPACE" \
      -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF -B build/
    execute cmake --build build --target install
    build_done "opencl-icd-loader" "$PKG_VERSION"
  fi
}
```

- [ ] **Step 2: Commit hwaccel recipes**

```bash
git add recipes/hwaccel/
git commit -m "Add hwaccel recipes: vulkan-headers, glslang, nv-codec, vaapi, amf, opencl"
```

---

### Task 15: Create other recipes

**Files:**
- Create: `recipes/other/libsdl.sh`
- Create: `recipes/other/freetype2.sh`
- Create: `recipes/other/vapoursynth.sh`
- Create: `recipes/other/srt.sh`
- Create: `recipes/other/zvbi.sh`
- Create: `recipes/other/libzmq.sh`

Reference: original lines 944-1016.

- [ ] **Step 1: Create other recipes**

`recipes/other/libsdl.sh`:
```sh
PKG_NAME="libsdl"
PKG_VERSION="2.32.10"
PKG_URL="https://github.com/libsdl-org/SDL/releases/download/release-${PKG_VERSION}/SDL2-${PKG_VERSION}.tar.gz"
```

`recipes/other/freetype2.sh`:
```sh
PKG_NAME="FreeType2"
PKG_VERSION="2.14.1"
PKG_URL="https://downloads.sourceforge.net/freetype/freetype-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-libfreetype"
```

`recipes/other/vapoursynth.sh`:
```sh
PKG_NAME="VapourSynth"
PKG_VERSION="73"
PKG_URL="https://github.com/vapoursynth/vapoursynth/archive/R${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-vapoursynth"
PKG_SKIP_EXTRACT=false

pkg_configure() { :; }
pkg_build() { :; }

pkg_install() {
  mkdir -p "$WORKSPACE/include/vapoursynth" || die "Failed to create vapoursynth include dir"
  cp -r "include/." "$WORKSPACE/include/vapoursynth/"
}
```

`recipes/other/srt.sh`:
```sh
PKG_NAME="srt"
PKG_VERSION="1.5.4"
PKG_URL="https://github.com/Haivision/srt/archive/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="srt-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libsrt"
PKG_NONFREE=true

pkg_configure() {
  export OPENSSL_ROOT_DIR="$WORKSPACE"
  export OPENSSL_LIB_DIR="$WORKSPACE/lib"
  export OPENSSL_INCLUDE_DIR="$WORKSPACE/include/"
  execute cmake . -DCMAKE_INSTALL_PREFIX="$WORKSPACE" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_BINDIR=bin \
    -DCMAKE_INSTALL_INCLUDEDIR=include -DENABLE_SHARED=OFF \
    -DENABLE_STATIC=ON -DENABLE_APPS=OFF -DUSE_STATIC_LIBSTDCXX=ON
}

pkg_install() {
  execute make install
}

pkg_post_install() {
  if [ -n "$LDEXEFLAGS" ]; then
    sed 's/-lgcc_s/-lgcc_eh/g' "$WORKSPACE/lib/pkgconfig/srt.pc" \
      > "$WORKSPACE/lib/pkgconfig/srt.pc.tmp" \
      && mv "$WORKSPACE/lib/pkgconfig/srt.pc.tmp" "$WORKSPACE/lib/pkgconfig/srt.pc"
  fi
}
```

`recipes/other/zvbi.sh`:
```sh
PKG_NAME="zvbi"
PKG_VERSION="0.2.44"
PKG_URL="https://github.com/zapping-vbi/zvbi/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="zvbi-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libzvbi"
PKG_NONFREE=true

pkg_prepare() {
  execute ./autogen.sh --prefix="$WORKSPACE"
}

pkg_configure() {
  execute ./configure CFLAGS="-I$WORKSPACE/include/libpng16 $CFLAGS" \
    --prefix="$WORKSPACE" --enable-static --disable-shared
}
```

`recipes/other/libzmq.sh`:
```sh
PKG_NAME="libzmq"
PKG_VERSION="4.3.5"
PKG_URL="https://github.com/zeromq/libzmq/releases/download/v${PKG_VERSION}/zeromq-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libzmq"

pkg_prepare() {
  if [ "$IS_DARWIN" = true ]; then
    export XML_CATALOG_FILES=/usr/local/etc/xml/catalog
  fi
}

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static
}

pkg_build() {
  # Fix C++ standards issue in proxy.cpp
  sed "s/stats_proxy stats = {0}/stats_proxy stats = {{{0, 0}, {0, 0}}, {{0, 0}, {0, 0}}}/g" \
    src/proxy.cpp > src/proxy.cpp.tmp && mv src/proxy.cpp.tmp src/proxy.cpp
  execute make -j "$MJOBS"
}
```

- [ ] **Step 2: Commit other recipes**

```bash
git add recipes/other/
git commit -m "Add other recipes: libsdl, freetype2, vapoursynth, srt, zvbi, libzmq"
```

---

## Chunk 6: Build Order and Final Integration

### Task 16: Create `recipes/_order.conf`

**Files:**
- Create: `recipes/_order.conf`

- [ ] **Step 1: Create the build order file**

This must match the dependency order from the original script exactly.

```
# Build tools
recipes/tools/giflib.sh
recipes/tools/pkg-config.sh
recipes/tools/yasm.sh
recipes/tools/nasm.sh
recipes/tools/zlib.sh
recipes/tools/m4.sh
recipes/tools/autoconf.sh
recipes/tools/automake.sh
recipes/tools/libtool.sh

# Crypto (mutual exclusion handled by recipe guards)
recipes/other/gettext.sh
recipes/crypto/openssl.sh
recipes/crypto/gmp.sh
recipes/crypto/nettle.sh
recipes/crypto/gnutls.sh

# Build tools (needs crypto done first for cmake)
recipes/tools/cmake.sh

# Video codecs
recipes/video/dav1d.sh
recipes/video/svtav1.sh
recipes/video/rav1e.sh
recipes/video/x264.sh
recipes/video/x265.sh
recipes/video/libvpx.sh
recipes/video/xvidcore.sh
recipes/video/vid_stab.sh
recipes/video/av1.sh
recipes/video/zimg.sh

# Audio codecs
recipes/audio/lv2.sh
recipes/audio/opencore.sh
recipes/audio/lame.sh
recipes/audio/opus.sh
recipes/audio/libogg.sh
recipes/audio/libvorbis.sh
recipes/audio/libtheora.sh
recipes/audio/fdk_aac.sh
recipes/audio/soxr.sh

# Image libraries
recipes/image/libtiff.sh
recipes/image/libpng.sh
recipes/image/libjxl.sh
recipes/image/libwebp.sh

# Other libraries
recipes/other/libsdl.sh
recipes/other/freetype2.sh
recipes/other/vapoursynth.sh
recipes/other/srt.sh
recipes/other/zvbi.sh

# ZMQ
recipes/other/libzmq.sh

# HW acceleration
recipes/hwaccel/vulkan-headers.sh
recipes/hwaccel/glslang.sh
recipes/hwaccel/nv-codec.sh
recipes/hwaccel/vaapi.sh
recipes/hwaccel/amf.sh
recipes/hwaccel/opencl.sh
```

- [ ] **Step 2: Commit**

```bash
git add recipes/_order.conf
git commit -m "Add recipes/_order.conf — build order"
```

---

### Task 17: Update driver with accumulator file reads and nvcc fallback

**Files:**
- Modify: `mediaforge.sh`

- [ ] **Step 1: Add `.extra_ldflags` reader and nvcc fallback**

After the recipe loop and before sourcing `recipes/ffmpeg.sh`, add:

```sh
# Read extra LDFLAGS from accumulator file
if [ -f "$WORKSPACE/.extra_ldflags" ]; then
  while IFS= read -r _flag || [ -n "$_flag" ]; do
    LDFLAGS="$LDFLAGS $_flag"
  done < "$WORKSPACE/.extra_ldflags"
fi

# If on Linux and nvcc not found, explicitly disable ffnvcodec
if [ "$IS_LINUX" = true ] && ! command_exists nvcc; then
  CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --disable-ffnvcodec"
fi
```

- [ ] **Step 2: Commit**

```bash
git add mediaforge.sh
git commit -m "Add accumulator file reads and nvcc fallback to driver"
```

---

### Task 18: Verify POSIX compliance across all files

- [ ] **Step 1: Run shellcheck on all shell files**

Run: `find . -name '*.sh' -not -path './ffmpeg-build-scripts/*' -not -path './packages/*' -not -path './workspace/*' | sort | xargs shellcheck -s sh`

Expected: No errors. SC2086 warnings on intentional word-splitting are acceptable (should be suppressed with `# shellcheck disable=SC2086` comments).

- [ ] **Step 2: Test argument parsing**

Run:
```sh
sh mediaforge.sh --help
sh mediaforge.sh --version
sh mediaforge.sh  # should show usage and exit 1
sh mediaforge.sh --unknown  # should show error and exit 1
```

- [ ] **Step 3: Test under dash (if available)**

Run: `dash mediaforge.sh --help`
Expected: Same output as `sh`

- [ ] **Step 4: Commit any fixes**

```bash
git add -A
git commit -m "Fix POSIX compliance issues found during verification"
```

---

### Task 19: Final cleanup and verification

- [ ] **Step 1: Remove original script from new project structure**

The original `ffmpeg-build-scripts/mediaforge.sh` stays untouched as reference.

- [ ] **Step 2: Verify file structure matches spec**

Run: `find . -not -path './.git/*' -not -path './ffmpeg-build-scripts/*' -not -path './docs/*' -not -path './packages/*' -not -path './workspace/*' | sort`

Expected output should match the spec's project structure.

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "Mediaforge v2.0 — POSIX-compliant rewrite complete"
```
