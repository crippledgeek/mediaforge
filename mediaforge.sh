#!/usr/bin/env sh
# shellcheck disable=SC2034,SC1090

SCRIPT_VERSION="3.0"
# shellcheck disable=SC2034
FFMPEG_VERSION="8.0.1"
PROGNAME=$(basename "$0")

# Resolve script's own directory (portable)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

TOPDIR=$(pwd)
DISTDIR="$TOPDIR/packages"
PREFIX="$TOPDIR/workspace"

# Source libraries (order matters — utils first, platform needs command_exists)
. "$SCRIPT_DIR/lib/utils.sh"
. "$SCRIPT_DIR/lib/registry.sh"
. "$SCRIPT_DIR/lib/platform.sh"
. "$SCRIPT_DIR/lib/download.sh"
. "$SCRIPT_DIR/lib/cleanup.sh"
. "$SCRIPT_DIR/lib/framework.sh"
. "$SCRIPT_DIR/lib/resolve.sh"

# Compiler flags
CFLAGS="-I$PREFIX/include"
CXXFLAGS="-I$PREFIX/include"
LDFLAGS="-L$PREFIX/lib"
LDEXEFLAGS=""
# shellcheck disable=SC2034
EXTRALIBS="-ldl -lpthread -lm -lz"
FFMPEG_CONFIGURE_OPTS=""
NVCCFLAGS=""

# Feature flags (defaults)
ENABLE_GPL=false
ENABLE_NONFREE=false
REBUILD_OUTDATED=false
INSTALL_MANPAGES=1
SKIP_INSTALL=""
AUTOINSTALL=""
PROFILE_NAME=""
# shellcheck disable=SC2034
VERBOSE=0
QUIET=false
DRY_RUN=false
KEEP_GOING=false
DISABLE_PKGS=""
ENABLE_PKGS=""

# ─── Help ────────────────────────────────────────────────────────────

cmd_help() {
  printf 'Usage: %s <command> [options]\n\n' "$PROGNAME"
  printf 'Commands:\n'
  printf '  build              Build FFmpeg and dependencies\n'
  printf '  clean              Remove all build artifacts\n'
  printf '  install            Install built binaries and libraries\n'
  printf '  uninstall          Remove installed files\n'
  printf '  check-updates      Check for newer dependency versions\n'
  printf '  list-profiles      List available version profiles\n'
  printf '  help               Show this help\n'
  printf '  version            Show version\n'
  printf '\nBuild options:\n'
  printf '  -g, --enable-gpl          Enable GPL-licensed codecs\n'
  printf '  -G, --enable-nonfree      Enable non-free codecs (implies GPL)\n'
  printf '  -L, --disable-lv2         Skip LV2 plugin chain\n'
  printf '  -s, --enable-static       Full static binary (Linux only)\n'
  printf '  -m, --enable-small        Minimal build\n'
  printf '  -p, --profile=X.Y         Use version profile\n'
  printf '  -j, --jobs=N              Parallel job count (default: auto)\n'
  printf '  -u, --rebuild-outdated    Rebuild stale dependencies\n'
  printf '  -I, --no-install          Skip post-build install\n'
  printf '  -y, --yes                 Non-interactive mode\n'
  printf '  -v, --verbose             Show build commands (-vv for more)\n'
  printf '  -q, --quiet               Errors only\n'
  printf '  -n, --dry-run             Show what would build\n'
  printf '  -k, --keep-going          Continue on recipe failure\n'
  printf '      --disable=PKG         Disable a recipe by name (repeatable, comma-separated ok)\n'
  printf '      --enable=PKG          Force-enable a recipe that defaults to off\n'
  printf '      --list-pkgs           Print every recipe with category and mutex group\n'
  printf '\n'
}

cmd_version() {
  printf 'mediaforge %s\n' "$SCRIPT_VERSION"
}

# ─── Build ───────────────────────────────────────────────────────────

cmd_build() {
  # Unified option parser — handles both short and long options
  while [ $# -gt 0 ]; do
    case "$1" in
      # Short options
      -g)  ENABLE_GPL=true ;;
      -G)  ENABLE_NONFREE=true; ENABLE_GPL=true ;;
      -L)  DISABLE_PKGS="$DISABLE_PKGS lv2" ;;
      -s)  _enable_static=true ;;
      -m)  _enable_small=true ;;
      -p)  shift; PROFILE_NAME="$1" ;;
      -j)  shift; MJOBS="$1" ;;
      -I)  SKIP_INSTALL=yes ;;
      -y)  AUTOINSTALL=yes ;;
      -v)  VERBOSE=$((VERBOSE + 1)) ;;
      -q)  QUIET=true ;;
      -n)  DRY_RUN=true ;;
      -k)  KEEP_GOING=true ;;
      -h)  cmd_help; exit 0 ;;
      # Long options
      --enable-gpl)        ENABLE_GPL=true ;;
      --enable-nonfree)    ENABLE_NONFREE=true; ENABLE_GPL=true ;;
      --disable-lv2)       DISABLE_PKGS="$DISABLE_PKGS lv2" ;;
      --enable-static)     _enable_static=true ;;
      --enable-small)      _enable_small=true ;;
      --profile=*)         PROFILE_NAME="${1#--profile=}" ;;
      --profile)           shift; PROFILE_NAME="$1" ;;
      --jobs=*)            MJOBS="${1#--jobs=}" ;;
      --jobs)              shift; MJOBS="$1" ;;
      --rebuild-outdated)  REBUILD_OUTDATED=true ;;
      --no-install)        SKIP_INSTALL=yes ;;
      --yes)               AUTOINSTALL=yes ;;
      --verbose)           VERBOSE=$((VERBOSE + 1)) ;;
      --quiet)             QUIET=true ;;
      --dry-run)           DRY_RUN=true ;;
      --keep-going)        KEEP_GOING=true ;;
      --disable=*)         DISABLE_PKGS="$DISABLE_PKGS $(echo "${1#--disable=}" | tr ',' ' ')" ;;
      --disable)           shift; DISABLE_PKGS="$DISABLE_PKGS $(echo "$1" | tr ',' ' ')" ;;
      --enable=*)          ENABLE_PKGS="$ENABLE_PKGS $(echo "${1#--enable=}" | tr ',' ' ')" ;;
      --enable)            shift; ENABLE_PKGS="$ENABLE_PKGS $(echo "$1" | tr ',' ' ')" ;;
      --list-pkgs)         list_pkgs; exit 0 ;;
      --)                  shift; break ;;
      -*)                  die "Unknown option: $1" ;;
      *)                   break ;;
    esac
    shift
  done

  # Validate every name in DISABLE_PKGS / ENABLE_PKGS against the recipe registry
  registry_init
  for _p in $DISABLE_PKGS $ENABLE_PKGS; do
    if ! is_known_pkg "$_p"; then
      _hint=$(suggest_pkg "$_p")
      if [ -n "$_hint" ]; then
        die "Unknown package: $_p. Did you mean: $_hint ?"
      else
        die "Unknown package: $_p. Run '$PROGNAME build --list-pkgs' to see all."
      fi
    fi
  done

  # Apply deferred flags
  if [ "$ENABLE_GPL" = true ]; then
    FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS --enable-gpl"
  fi
  if [ "$ENABLE_NONFREE" = true ]; then
    FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS --enable-nonfree"
  fi
  if [ "$_enable_static" = true ]; then
    if [ "$OS_MACOS" = true ]; then
      die "Full static binaries can only be built on Linux."
    fi
    LDEXEFLAGS="-static -fPIC"
    CFLAGS="$CFLAGS -fPIC"
    CXXFLAGS="$CXXFLAGS -fPIC"
  fi
  if [ "$_enable_small" = true ]; then
    FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS --enable-small --disable-doc"
    INSTALL_MANPAGES=0
  fi

  # Load version profile if specified
  if [ -n "$PROFILE_NAME" ]; then
    _profile_file="$SCRIPT_DIR/profiles/ffmpeg-${PROFILE_NAME}.conf"
    if [ ! -f "$_profile_file" ]; then
      die "Profile not found: $_profile_file"
    fi
    . "$_profile_file"
    log "Using profile: ffmpeg-${PROFILE_NAME}"
  fi

  # Setup traps
  setup_traps

  # Pre-flight checks
  command_exists "make" || die "make not installed"
  command_exists "g++"  || die "g++ not installed"
  command_exists "curl" || die "curl not installed"

  command_exists "cargo"   || warn "cargo not installed — rav1e will be skipped"
  command_exists "python3" || warn "python3 not installed — dav1d and lv2 will be skipped"

  # Static build: check for required static system libraries
  if [ -n "$LDEXEFLAGS" ]; then
    _missing=""
    for _slib in expat bz2 lzma unibreak bsd md deflate jbig jpeg unwind; do
      if [ ! -f "/usr/lib/lib${_slib}.a" ]; then
        _missing="$_missing $_slib"
      fi
    done
    if [ -n "$_missing" ]; then
      warn "Static build: missing system static libraries:$_missing"
      warn "FFmpeg configure may fail. See BUILDING.md for details."
      warn "On Arch Linux, rebuild these packages with staticlibs or use AUR static packages."
    fi
  fi

  # Platform-specific setup
  if [ "$OS_MACOS_ARM" = true ]; then
    export ARCH=arm64
    export MACOSX_DEPLOYMENT_TARGET=11.0
    CXX=$(command -v clang++)
    export CXX
    command_exists "clang++" || die "clang++ not installed. Please install Xcode."
    log "Apple Silicon detected ($(sw_vers -productVersion))"
  fi

  # shellcheck disable=SC2034
  GNU_LIBTOOL=""
  if [ "$OS_MACOS" = true ]; then
    FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS --enable-videotoolbox"
    GNU_LIBTOOL="$(command -v libtool)"
  fi

  # Setup paths
  mkdir -p "$DISTDIR" || die "Failed to create $DISTDIR"
  mkdir -p "$PREFIX" || die "Failed to create $PREFIX"
  mkdir -p "$PREFIX/.stamps" 2>/dev/null
  mkdir -p "$PREFIX/.logs" 2>/dev/null

  # Add CUDA to PATH if installed (common locations)
  for _cuda_dir in /opt/cuda /usr/local/cuda; do
    if [ -d "$_cuda_dir/bin" ]; then
      PATH="$_cuda_dir/bin:$PATH"
      break
    fi
  done
  export PATH="$PREFIX/bin:$PATH"

  # Build pkg-config path dynamically
  PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:/usr/local/lib/pkgconfig"
  if [ -n "$MULTIARCH_TRIPLET" ]; then
    PKG_CONFIG_PATH="$PKG_CONFIG_PATH:/usr/lib/$MULTIARCH_TRIPLET/pkgconfig"
    PKG_CONFIG_PATH="$PKG_CONFIG_PATH:/usr/local/lib/$MULTIARCH_TRIPLET/pkgconfig"
  fi
  PKG_CONFIG_PATH="$PKG_CONFIG_PATH:/usr/local/share/pkgconfig:/usr/lib/pkgconfig"
  PKG_CONFIG_PATH="$PKG_CONFIG_PATH:/usr/share/pkgconfig:/usr/lib64/pkgconfig"
  export PKG_CONFIG_PATH

  log "Using $MJOBS parallel jobs"
  if [ "$ENABLE_GPL" = true ]; then
    log "GPL codecs enabled"
  fi
  if [ "$ENABLE_NONFREE" = true ]; then
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

  # Read extra flags from accumulator files (written by recipes like lv2, nv-codec)
  if [ -f "$PREFIX/.extra_cflags" ]; then
    while IFS= read -r _flag || [ -n "$_flag" ]; do
      CFLAGS="$CFLAGS $_flag"
    done < "$PREFIX/.extra_cflags"
  fi
  if [ -f "$PREFIX/.extra_ldflags" ]; then
    while IFS= read -r _flag || [ -n "$_flag" ]; do
      LDFLAGS="$LDFLAGS $_flag"
    done < "$PREFIX/.extra_ldflags"
  fi

  # If on Linux and nvcc not found, explicitly disable ffnvcodec
  if [ "$OS_LINUX" = true ] && ! command_exists nvcc; then
    FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS --disable-ffnvcodec"
  fi

  # Build FFmpeg
  . "$SCRIPT_DIR/recipes/ffmpeg.sh"

  # Install (unless --no-install)
  if [ "$SKIP_INSTALL" != "yes" ]; then
    . "$SCRIPT_DIR/lib/install.sh"
    do_install ""
  fi
}

# ─── Clean ───────────────────────────────────────────────────────────

cmd_clean() {
  full_cleanup
}

# ─── Install ─────────────────────────────────────────────────────────

cmd_install() {
  . "$SCRIPT_DIR/lib/install.sh"
  _prefix=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefix=*) _prefix="${1#--prefix=}" ;;
      --prefix)   shift; _prefix="$1" ;;
      --yes|-y)   AUTOINSTALL=yes ;;
      --)         shift; break ;;
      -*)         die "Unknown option for install: $1" ;;
      *)          break ;;
    esac
    shift
  done
  do_install "$_prefix"
}

# ─── Uninstall ───────────────────────────────────────────────────────

cmd_uninstall() {
  . "$SCRIPT_DIR/lib/install.sh"
  _prefix=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefix=*) _prefix="${1#--prefix=}" ;;
      --prefix)   shift; _prefix="$1" ;;
      --yes|-y)   AUTOINSTALL=yes ;;
      --)         shift; break ;;
      -*)         die "Unknown option for uninstall: $1" ;;
      *)          break ;;
    esac
    shift
  done
  do_uninstall "$_prefix"
}

# ─── Check Updates ───────────────────────────────────────────────────

cmd_check_updates() {
  # Parse --profile option for check-updates
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile=*) PROFILE_NAME="${1#--profile=}" ;;
      --profile)   shift; PROFILE_NAME="$1" ;;
      -p)          shift; PROFILE_NAME="$1" ;;
      *)           die "Unknown option for check-updates: $1" ;;
    esac
    shift
  done

  if [ -n "$PROFILE_NAME" ]; then
    _profile_file="$SCRIPT_DIR/profiles/ffmpeg-${PROFILE_NAME}.conf"
    if [ ! -f "$_profile_file" ]; then
      die "Profile not found: $_profile_file"
    fi
    . "$_profile_file"
  fi

  . "$SCRIPT_DIR/lib/updates.sh"
  check_updates
}

# ─── List Profiles ───────────────────────────────────────────────────

cmd_list_profiles() {
  log "Available profiles:"
  for _pf in "$SCRIPT_DIR"/profiles/ffmpeg-*.conf; do
    [ -f "$_pf" ] || continue
    _pname=$(basename "$_pf" .conf | sed 's/^ffmpeg-//')
    log "  ffmpeg-${_pname}"
  done
}

# ─── Subcommand Dispatch ─────────────────────────────────────────────

log "mediaforge v$SCRIPT_VERSION"
log "========================="

_cmd="${1:-}"
if [ -n "$_cmd" ]; then
  shift
fi

case "$_cmd" in
  build)          cmd_build "$@" ;;
  clean)          cmd_clean "$@" ;;
  install)        cmd_install "$@" ;;
  uninstall)      cmd_uninstall "$@" ;;
  check-updates)  cmd_check_updates "$@" ;;
  list-profiles)  cmd_list_profiles "$@" ;;
  help|-h|--help) cmd_help ;;
  version|--version) cmd_version ;;

  # Backward compatibility hints for old flags
  -b|--build)     die "Syntax changed: use '$PROGNAME build' instead of '$PROGNAME -b'" ;;
  -c|--cleanup)   die "Syntax changed: use '$PROGNAME clean' instead of '$PROGNAME -c'" ;;
  --gpl)          die "Syntax changed: use '$PROGNAME build --enable-gpl'" ;;
  --nonfree)      die "Syntax changed: use '$PROGNAME build --enable-nonfree'" ;;
  --latest)       die "Syntax changed: use '$PROGNAME build --rebuild-outdated'" ;;
  --small)        die "Syntax changed: use '$PROGNAME build --enable-small'" ;;
  --full-static)  die "Syntax changed: use '$PROGNAME build --enable-static'" ;;
  --skip-install) die "Syntax changed: use '$PROGNAME build --no-install'" ;;
  --auto-install) die "Syntax changed: use '$PROGNAME build --yes'" ;;

  "")             cmd_help; exit 2 ;;
  -*)             die "Unknown option: $_cmd (try '$PROGNAME help')" ;;
  *)              die "Unknown command: $_cmd (try '$PROGNAME help')" ;;
esac

exit 0
