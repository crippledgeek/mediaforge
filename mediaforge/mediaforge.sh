#!/usr/bin/env sh

SCRIPT_VERSION="2.0"
FFMPEG_VERSION="8.0.1"
PROGNAME=$(basename "$0")

# Resolve script's own directory (portable)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

TOPDIR=$(pwd)
DISTDIR="$TOPDIR/packages"
PREFIX="$TOPDIR/workspace"

# Source libraries (order matters — utils first, platform needs command_exists)
. "$SCRIPT_DIR/lib/utils.sh"
. "$SCRIPT_DIR/lib/platform.sh"
. "$SCRIPT_DIR/lib/download.sh"
. "$SCRIPT_DIR/lib/cleanup.sh"
. "$SCRIPT_DIR/lib/framework.sh"

# Compiler flags
CFLAGS="-I$PREFIX/include"
CXXFLAGS="-I$PREFIX/include"
LDFLAGS="-L$PREFIX/lib"
LDEXEFLAGS=""
EXTRALIBS="-ldl -lpthread -lm -lz"
FFMPEG_CONFIGURE_OPTS=""
NVCCFLAGS=""

# Feature flags
ENABLE_GPL=false
ENABLE_NONFREE=false
NO_LV2=false
REBUILD_OUTDATED=false
INSTALL_MANPAGES=1
SKIP_INSTALL=""
AUTOINSTALL=""
PROFILE_NAME=""
CHECK_UPDATES=false
LIST_PROFILES=false

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
  printf '      --profile <name>           Use version profile (e.g., 7.1, 8.0.1)\n'
  printf '      --list-profiles            List available version profiles\n'
  printf '      --check-updates            Check for newer dependency versions on GitHub\n'
  printf '\n'
}

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
      ENABLE_GPL=true
      FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS --enable-gpl"
      ;;
    --nonfree)
      ENABLE_NONFREE=true
      if [ "$ENABLE_GPL" != true ]; then
        ENABLE_GPL=true
        FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS --enable-gpl"
      fi
      FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS --enable-nonfree"
      ;;
    --disable-lv2)
      NO_LV2=true
      ;;
    -c|--cleanup)
      cflag=yes
      ;;
    --latest)
      REBUILD_OUTDATED=true
      ;;
    --small)
      FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS --enable-small --disable-doc"
      INSTALL_MANPAGES=0
      ;;
    --full-static)
      if [ "$OS_MACOS" = true ]; then
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
      SKIP_INSTALL=yes
      ;;
    --auto-install)
      if [ "$SKIP_INSTALL" = "yes" ]; then
        die "--auto-install cannot be used with --skip-install"
      fi
      AUTOINSTALL=yes
      ;;
    --profile)
      shift
      PROFILE_NAME="$1"
      ;;
    --list-profiles)
      LIST_PROFILES=true
      ;;
    --check-updates)
      CHECK_UPDATES=true
      ;;
    *)
      warn "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

# Load version profile if specified
if [ -n "$PROFILE_NAME" ]; then
  _profile_file="$SCRIPT_DIR/profiles/ffmpeg-${PROFILE_NAME}.conf"
  if [ ! -f "$_profile_file" ]; then
    die "Profile not found: $_profile_file"
  fi
  . "$_profile_file"
  log "Using profile: ffmpeg-${PROFILE_NAME}"
fi

# Standalone actions (no -b required)
if [ "$LIST_PROFILES" = true ]; then
  log "Available profiles:"
  for _pf in "$SCRIPT_DIR"/profiles/ffmpeg-*.conf; do
    [ -f "$_pf" ] || continue
    _pname=$(basename "$_pf" .conf | sed 's/^ffmpeg-//')
    log "  ffmpeg-${_pname}"
  done
  exit 0
fi

if [ "$CHECK_UPDATES" = true ]; then
  . "$SCRIPT_DIR/lib/updates.sh"
  check_updates
  exit 0
fi

# Must specify an action
if [ -z "$bflag" ]; then
  if [ "$cflag" = "yes" ]; then
    full_cleanup
    exit 0
  fi
  usage
  exit 1
fi

# Setup traps
setup_traps

# Pre-flight checks
command_exists "make" || die "make not installed"
command_exists "g++"  || die "g++ not installed"
command_exists "curl" || die "curl not installed"

command_exists "cargo"   || warn "cargo not installed — rav1e will be skipped"
command_exists "python3" || warn "python3 not installed — dav1d and lv2 will be skipped"

# Platform-specific setup
if [ "$OS_MACOS_ARM" = true ]; then
  export ARCH=arm64
  export MACOSX_DEPLOYMENT_TARGET=11.0
  CXX=$(command -v clang++)
  export CXX
  command_exists "clang++" || die "clang++ not installed. Please install Xcode."
  log "Apple Silicon detected ($(sw_vers -productVersion))"
fi

GNU_LIBTOOL=""
if [ "$OS_MACOS" = true ]; then
  FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS --enable-videotoolbox"
  GNU_LIBTOOL="$(command -v libtool)"
fi

# Setup paths
mkdir -p "$DISTDIR" || die "Failed to create $DISTDIR"
mkdir -p "$PREFIX" || die "Failed to create $PREFIX"
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

# Install
. "$SCRIPT_DIR/lib/install.sh"

exit 0
