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
. "$SCRIPT_DIR/lib/makesum.sh"
. "$SCRIPT_DIR/lib/cleanup.sh"
. "$SCRIPT_DIR/lib/framework.sh"
. "$SCRIPT_DIR/lib/resolve.sh"
. "$SCRIPT_DIR/lib/menu.sh"

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
USE_MENU=false
ENABLE_LTO=false
FLITE_AUDIO="none"

# ─── Help ────────────────────────────────────────────────────────────

cmd_help() {
  printf 'Usage: %s <command> [options]\n\n' "$PROGNAME"
  printf 'Commands:\n'
  printf '  build              Build FFmpeg and dependencies\n'
  printf '  clean              Remove all build artifacts\n'
  printf '  install            Install built binaries and libraries\n'
  printf '  uninstall          Remove installed files\n'
  printf '  check-updates      Check for newer dependency versions\n'
  printf '  makesum            Fetch recipe sources and record their sha256/size sidecars\n'
  printf '  check-shadowers    Audit workspace .pc files for system-version shadowing\n'
  printf '  list-profiles      List available version profiles\n'
  printf '  help               Show this help\n'
  printf '  version            Show version\n'
  printf '\nBuild options:\n'
  printf '  -g, --enable-gpl          Enable GPL-licensed codecs\n'
  printf '  -G, --enable-nonfree      Enable non-free codecs (implies GPL)\n'
  printf '  -L, --disable-lv2         Skip LV2 plugin chain\n'
  printf '  -s, --enable-static       Full static binary (Linux only)\n'
  printf '  -m, --enable-small        Minimal build\n'
  printf '      --enable-lto          Enable LTO in recipes that support it (default: off; archives may break on GCC major bumps)\n'
  printf '      --disable-lto         Force LTO off (default)\n'
  printf '  -p, --profile=X.Y         Use version profile\n'
  printf '  -j, --jobs=N              Parallel job count (default: auto)\n'
  printf '  -u, --rebuild-outdated    Rebuild stale dependencies\n'
  printf '  -I, --no-install          Skip post-build install\n'
  printf '  -y, --yes                 Non-interactive mode\n'
  printf '      --menu                Interactive selector (whiptail or POSIX fallback)\n'
  printf '  -v, --verbose             Show build commands (-vv for more)\n'
  printf '  -q, --quiet               Errors only\n'
  printf '  -n, --dry-run             Show what would build\n'
  printf '  -k, --keep-going          Continue on recipe failure\n'
  printf '\nCodec / backend selectors (mutually exclusive within each group):\n'
  printf '      --tls=BACKEND         TLS backend: openssl|gnutls|mbedtls|libressl|none (default: gnutls)\n'
  printf '      --aac=IMPL            AAC encoder: fdk_aac|native (default: native; nonfree -> fdk_aac)\n'
  printf '      --h264=IMPL           H.264 encoder: x264|openh264 (default: x264)\n'
  printf '      --h265=IMPL           H.265 encoder: x265|kvazaar (default: x265)\n'
  printf '      --av1-enc=IMPL        AV1 encoder: svtav1|rav1e|av1 (default: svtav1)\n'
  printf '      --spirv=IMPL          SPIR-V compiler: glslang|shaderc (default: glslang)\n'
  printf '      --flite-audio=BACKEND flite audio output: none|alsa|pulseaudio|oss|sun (default: none; FFmpeg filter does not invoke it)\n'
  printf '      --openssldir=PATH     Compiled-in trust store for the openssl/libressl arms (absolute).\n'
  printf '                            Default: probe the host for a dir holding cert.pem, else the prefix.\n'
  printf '\nRecipe overrides:\n'
  printf '      --disable=PKG         Disable a recipe by name (repeatable, comma-separated ok)\n'
  printf '      --enable=PKG          Force-enable a recipe that defaults to off\n'
  printf '      --list-pkgs           Print every recipe with category and mutex group\n'
  printf '      --clean-choices       Delete the stored choice matrix and exit\n'
  printf '\nInstall / uninstall options (used by the install and uninstall subcommands):\n'
  printf '      --prefix=PATH         Install/uninstall location (default: interactive prompt)\n'
  printf '  -y, --yes                 Non-interactive mode\n'
  printf '\nInstall doctrine:\n'
  printf '  Do NOT run install with sudo against a user-owned prefix. The installer\n'
  printf '  auto-elevates only when the prefix requires it (/usr/local, /opt/...).\n'
  printf '  For downstream pkg-config consumers, prefer an isolated prefix:\n'
  # SC2016 false positive: $HOME is shown to the user literally, not expanded.
  # shellcheck disable=SC2016
  printf '    ./mediaforge.sh install --prefix=$HOME/.local/mediaforge\n'
  printf '  This keeps mediaforge'\''s 94 transitive .pc files out of the shared\n'
  printf '  ~/.local/lib/pkgconfig and avoids shadowing system fontconfig/harfbuzz.\n'
  printf '\n'
}

cmd_version() {
  printf 'mediaforge %s\n' "$SCRIPT_VERSION"
}

# Guard for space-form CLI flags. Call AFTER `shift` with the remaining
# arg count and the flag name; aborts with a clear message when the
# value is missing instead of consuming the next flag as the value.
_need_arg() {
  [ "$1" -gt 0 ] || die "$2 requires an argument"
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
      -p)  shift; _need_arg "$#" -p; PROFILE_NAME="$1" ;;
      -j)  shift; _need_arg "$#" -j; MJOBS="$1" ;;
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
      --enable-lto)        ENABLE_LTO=true ;;
      --disable-lto)       ENABLE_LTO=false ;;
      --flite-audio=*)     FLITE_AUDIO="${1#--flite-audio=}" ;;
      --flite-audio)       shift; _need_arg "$#" --flite-audio; FLITE_AUDIO="$1" ;;
      --openssldir=*)      OPENSSLDIR="${1#--openssldir=}" ;;
      --openssldir)        shift; _need_arg "$#" --openssldir; OPENSSLDIR="$1" ;;
      --profile=*)         PROFILE_NAME="${1#--profile=}" ;;
      --profile)           shift; _need_arg "$#" --profile; PROFILE_NAME="$1" ;;
      --jobs=*)            MJOBS="${1#--jobs=}" ;;
      --jobs)              shift; _need_arg "$#" --jobs; MJOBS="$1" ;;
      --rebuild-outdated)  REBUILD_OUTDATED=true ;;
      --no-install)        SKIP_INSTALL=yes ;;
      --yes)               AUTOINSTALL=yes ;;
      --verbose)           VERBOSE=$((VERBOSE + 1)) ;;
      --quiet)             QUIET=true ;;
      --dry-run)           DRY_RUN=true ;;
      --keep-going)        KEEP_GOING=true ;;
      --disable=*)         DISABLE_PKGS="$DISABLE_PKGS $(echo "${1#--disable=}" | tr ',' ' ')" ;;
      --disable)           shift; _need_arg "$#" --disable; DISABLE_PKGS="$DISABLE_PKGS $(echo "$1" | tr ',' ' ')" ;;
      --enable=*)          ENABLE_PKGS="$ENABLE_PKGS $(echo "${1#--enable=}" | tr ',' ' ')" ;;
      --enable)            shift; _need_arg "$#" --enable; ENABLE_PKGS="$ENABLE_PKGS $(echo "$1" | tr ',' ' ')" ;;
      --list-pkgs)         list_pkgs; exit 0 ;;
      --clean-choices)     rm -f "$PREFIX/.mediaforge-choices"; log "Cleared stored choices"; exit 0 ;;
      --tls=*)             TLS_BACKEND="${1#--tls=}" ;;
      --tls)               shift; _need_arg "$#" --tls; TLS_BACKEND="$1" ;;
      --aac=*)             AAC_IMPL="${1#--aac=}" ;;
      --aac)               shift; _need_arg "$#" --aac; AAC_IMPL="$1" ;;
      --h264=*)            H264_IMPL="${1#--h264=}" ;;
      --h264)              shift; _need_arg "$#" --h264; H264_IMPL="$1" ;;
      --h265=*)            H265_IMPL="${1#--h265=}" ;;
      --h265)              shift; _need_arg "$#" --h265; H265_IMPL="$1" ;;
      --av1-enc=*)         AV1_ENC_IMPL="${1#--av1-enc=}" ;;
      --av1-enc)           shift; _need_arg "$#" --av1-enc; AV1_ENC_IMPL="$1" ;;
      --spirv=*)           SPIRV_IMPL="${1#--spirv=}" ;;
      --spirv)             shift; _need_arg "$#" --spirv; SPIRV_IMPL="$1" ;;
      --menu)              USE_MENU=true ;;
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

  if [ "$USE_MENU" = true ]; then
    if [ "$AUTOINSTALL" = "yes" ]; then
      die "--menu and --yes are mutually exclusive"
    fi
    run_menu
  fi

  # Snapshot the AAC choice the user made THIS run (CLI --aac= or --menu),
  # before load_stored_choices backfills it from a prior build. Used so
  # --enable-nonfree's fdk_aac implication can beat a stale stored 'native'
  # (see resolve_choices) without overriding an explicit --aac= this run.
  _aac_cli="$AAC_IMPL"

  # Load stored choices from previous run (CLI flags take precedence —
  # load_stored_choices only sets values that are currently empty).
  load_stored_choices

  # Snapshot the user-provided disables before resolver augments them
  DISABLE_PKGS_INPUT="$DISABLE_PKGS"

  # Resolve per-group choices into DISABLE_PKGS
  resolve_choices

  # Persist the resolved matrix for next run
  save_stored_choices

  # Log final choice matrix
  log "Choices: tls=$TLS_BACKEND aac=$AAC_IMPL h264=$H264_IMPL h265=$H265_IMPL av1-enc=$AV1_ENC_IMPL spirv=$SPIRV_IMPL openssldir=${OPENSSLDIR:-auto}"

  # Apply deferred flags
  if [ "$ENABLE_GPL" = true ]; then
    FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS --enable-gpl"
  fi
  if [ "$ENABLE_NONFREE" = true ]; then
    FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS --enable-nonfree"
  fi
  # Position-independent code for every recipe, unconditionally, so the static
  # archives we produce link into PIE executables and shared libraries on ANY
  # host (e.g. downstream consumers like rdlp). Arch defaults to PIE so this is
  # redundant there, but non-PIE-default toolchains need it or a dynamic build
  # hits "relocation R_X86_64_32 ... cannot be used when making a PIE object".
  # Exported so codec ./configure and cmake invocations inherit it — without the
  # export it would reach only FFmpeg (via --extra-cflags), not the codecs.
  # The fully-static ffmpeg binary (-static) stays opt-in below.
  CFLAGS="$CFLAGS -fPIC"
  CXXFLAGS="$CXXFLAGS -fPIC"
  export CFLAGS CXXFLAGS
  if [ "$_enable_static" = true ]; then
    if [ "$OS_MACOS" = true ]; then
      die "Full static binaries can only be built on Linux."
    fi
    LDEXEFLAGS="-static -fPIC"
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

  # Static build: warn about static system libs that are neither bundled by
  # mediaforge's own recipes (recipes/syslib/) nor present in /usr/lib/.
  # mediaforge bundles: expat, bz2 (via bzip2), lzma (via xz), unibreak, brotli.
  # Anything else — bsd, md, deflate, jbig, jpeg, unwind, asound — must come
  # from the system or be opted out (e.g. --disable=flite for asound).
  if [ -n "$LDEXEFLAGS" ]; then
    _bundled="expat bz2 lzma unibreak brotlidec brotlicommon"
    _missing=""
    for _slib in expat bz2 lzma unibreak bsd md deflate jbig jpeg unwind \
                 brotlidec brotlicommon asound; do
      case " $_bundled " in
        *" $_slib "*) continue ;;  # mediaforge will produce $PREFIX/lib/lib<x>.a
      esac
      if [ ! -f "/usr/lib/lib${_slib}.a" ] && \
         [ ! -f "/usr/lib/${MULTIARCH_TRIPLET:-}/lib${_slib}.a" ]; then
        _missing="$_missing $_slib"
      fi
    done
    if [ -n "$_missing" ]; then
      warn "Static build: missing system static libraries:$_missing"
      warn "FFmpeg's link step may fail with misleading messages (e.g. 'libass not found')."
      warn "Workarounds: install AUR -static variants, or drop --enable-static, or"
      warn "skip the recipes that need them (e.g. --disable=flite removes the asound dep)."
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

  # Reset the pc-skip queue at the start of every build. Recipes with
  # PKG_TRANSITIVE_UTIL=true append their .pc filenames; recipes/ffmpeg.sh
  # processes the queue after FFmpeg's configure has consumed the .pc files.
  rm -f "$PREFIX/.pc-skip-queue" 2>/dev/null

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
      --prefix)   shift; _need_arg "$#" --prefix; _prefix="$1" ;;
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
      --prefix)   shift; _need_arg "$#" --prefix; _prefix="$1" ;;
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
      --profile)   shift; _need_arg "$#" --profile; PROFILE_NAME="$1" ;;
      -p)          shift; _need_arg "$#" -p; PROFILE_NAME="$1" ;;
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

# ─── Makesum ─────────────────────────────────────────────────────────

cmd_makesum() {
  MAKESUM_UPDATE=false
  _mk_build=false
  _mk_pkgs=""

  # Pre-scan for --build before the real parse below. Once --build is
  # present, every other flag on the line belongs to cmd_build's own option
  # parser (e.g. --enable-nonfree) rather than makesum's, and cmd_build's
  # parser hasn't run yet to validate them -- checking "is --build anywhere
  # in $@" up front means the order the user typed the flags in doesn't matter.
  for _mk_scan in "$@"; do
    [ "$_mk_scan" = --build ] && _mk_build=true
  done

  # Rebuild "$@" itself into the forward list when --build is set, rather
  # than accumulating a string: a string accumulator's later unquoted
  # expansion word-splits on whitespace inside a value, so
  # --openssldir "/path with space" would reach cmd_build as two arguments.
  # "$@" is POSIX sh's one whitespace-safe argument-vector primitive, and
  # `set -- "$@" "$_mk_arg"` moves a token to the back of it intact. $_mk_argc
  # drives the loop instead of $#, because $# does not shrink when a token is
  # re-appended -- looping on $# would never terminate for a forwarded token.
  _mk_argc=$#
  while [ "$_mk_argc" -gt 0 ]; do
    _mk_arg="$1"
    shift
    _mk_argc=$((_mk_argc - 1))
    case "$_mk_arg" in
      --profile=*) PROFILE_NAME="${_mk_arg#--profile=}" ;;
      --profile)
        _need_arg "$_mk_argc" --profile
        PROFILE_NAME="$1"; shift; _mk_argc=$((_mk_argc - 1))
        ;;
      -p)
        _need_arg "$_mk_argc" -p
        PROFILE_NAME="$1"; shift; _mk_argc=$((_mk_argc - 1))
        ;;
      --update)    MAKESUM_UPDATE=true ;;
      # --build reaches the fetch() calls nested inside pkg_install() (lv2's
      # seven sub-tarballs, ffmpeg.sh, opencl, libcdio) that a fetch-only pass
      # never sources far enough to see -- already accounted for by the
      # pre-scan above, nothing left to do here. Consumed, never forwarded:
      # cmd_build has no such flag of its own.
      --build)     ;;
      # Everything else -- flag or bare value, whether or not it starts with
      # "-" -- is forwarded to cmd_build verbatim when --build is set, rather
      # than re-parsed here. cmd_makesum does not know which of cmd_build's
      # flags take a separate-token value (-j 4, --tls openssl,
      # --openssldir /etc/ssl); teaching it that grammar would duplicate
      # cmd_build's own parser and the two would drift the next time a flag
      # is added (see ~/.claude/rules/extract-before-you-duplicate.md). A
      # value token like "openssl" is also a real recipe name, so it cannot
      # be told apart from a package filter here either -- only cmd_build,
      # which already validates its own grammar, can tell a stray value from
      # a bad flag. Outside --build mode a bare token is still a package
      # filter and an unrecognized "-*" still dies here, exactly as before.
      *)
        if [ "$_mk_build" = true ]; then
          set -- "$@" "$_mk_arg"
        else
          case "$_mk_arg" in
            -*) die "Unknown option for makesum: $_mk_arg" ;;
            *)  _mk_pkgs="$_mk_pkgs $_mk_arg" ;;
          esac
        fi
        ;;
    esac
  done

  if [ "$_mk_build" = true ]; then
    # MAKESUM_MODE makes fetch() (lib/download.sh) record instead of its
    # ordinary behavior; every fetch() call this build reaches, including
    # ones nested inside a recipe's pkg_install(), runs in this same shell
    # process, so a plain assignment already suffices. Exported anyway per
    # the task brief, to stay visible to a subshell if one is ever added.
    MAKESUM_MODE=true
    export MAKESUM_MODE
    log "makesum: running a real build with checksum recording enabled (--build)"
    # "$@" now holds exactly the tokens the loop above re-appended (flags and
    # their separate-token values alike, e.g. --tls openssl), each with its
    # word boundaries intact -- no word-splitting, so no SC2086 to suppress.
    # A stray package name (`makesum --build zlib`) is forwarded too and
    # rejected by cmd_build's own parser, not this one.
    cmd_build "$@"
    return
  fi

  if [ -n "$PROFILE_NAME" ]; then
    _profile_file="$SCRIPT_DIR/profiles/ffmpeg-${PROFILE_NAME}.conf"
    if [ ! -f "$_profile_file" ]; then
      die "Profile not found: $_profile_file"
    fi
    . "$_profile_file"
    log "Using profile: ffmpeg-${PROFILE_NAME}"
  fi

  # Validate every requested package name against the recipe registry, same
  # as cmd_build's --enable=/--disable= validation, so a typo fails fast with
  # a suggestion instead of silently matching nothing.
  registry_init
  for _p in $_mk_pkgs; do
    if ! is_known_pkg "$_p"; then
      _hint=$(suggest_pkg "$_p")
      if [ -n "$_hint" ]; then
        die "Unknown package: $_p. Did you mean: $_hint ?"
      else
        die "Unknown package: $_p. Run '$PROGNAME build --list-pkgs' to see all."
      fi
    fi
  done

  while IFS= read -r _recipe || [ -n "$_recipe" ]; do
    case "$_recipe" in
      ""|\#*) continue ;;
    esac

    if [ -n "$_mk_pkgs" ]; then
      _mk_name=$(basename "$_recipe" .sh)
      _mk_match=false
      for _p in $_mk_pkgs; do
        [ "$_p" = "$_mk_name" ] && _mk_match=true && break
      done
      [ "$_mk_match" = true ] || continue
    fi

    # load_recipe (lib/framework.sh) is the same prelude run_recipe() uses:
    # reset state, derive PKG_HASH_FILE from this recipe's own path, source
    # it. Recipe top levels are plain variable assignment and conditionals
    # (PKG_FFMPEG_OPT, PKG_DISABLED guards) -- none of the ~80 recipes run a
    # command at source time, so sourcing every one here for a fetch-only
    # pass is safe.
    load_recipe "$SCRIPT_DIR/$_recipe"

    if [ "$PKG_SKIP_EXTRACT" = true ] || [ -z "$PKG_URL" ]; then
      log "makesum: skipping $PKG_NAME (no PKG_URL to fetch)"
      continue
    fi

    _mk_file="${PKG_FILENAME:-${PKG_URL##*/}}"
    _mk_dest="$DISTDIR/$_mk_file"

    if makesum_needs_fetch "$PKG_HASH_FILE" "$_mk_file" "$_mk_dest"; then
      download_file "$PKG_URL" "$_mk_dest"
    else
      log "makesum: $_mk_file already matches its recorded digest, skipping download"
    fi

    MAKESUM_PROVENANCE="Locally calculated $(date +%Y-%m-%d)"
    hash_record_write "$PKG_HASH_FILE" "$_mk_file" "$_mk_dest"
  done < "$SCRIPT_DIR/recipes/_order.conf"
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

# ─── Check Shadowers ─────────────────────────────────────────────────
#
# Audit the workspace pkgconfig dir against the system: for each .pc the build
# produced, probe `pkg-config --exists` with the system path only and report
# any name that the system ALSO provides. Names already in
# _PKGCONFIG_SHADOWERS (lib/install.sh) print as `[expected]`; new names
# print as `[NEW SHADOW]` and the command exits 1 under `--strict`.
#
# No build tool we surveyed (pkg-config, pkgconf, rpmlint, lintian, brew
# audit, vcpkg) exposes a built-in shadow-detection mode. The pristine-system
# probe below is the documented workaround; distro convention is to warn
# (not fail) so this command exits 0 by default — pair with `--strict` in CI
# if you want gating.

cmd_check_shadowers() {
  _strict=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --strict) _strict=true ;;
      -h|--help)
        printf 'Usage: %s check-shadowers [--strict]\n\n' "$PROGNAME"
        printf 'Audit workspace .pc files against the system pkgconfig path.\n'
        printf 'Reports each system overlap as either:\n'
        printf '  [expected]   — recipe declared PKG_TRANSITIVE_UTIL=true; .pc dropped at build end\n'
        printf '  [NEW SHADOW] — would be installed AND system has it; review whether the recipe\n'
        printf '                 should set PKG_TRANSITIVE_UTIL=true\n\n'
        printf '  --strict   exit 1 when new shadowers are found (default: warn only)\n'
        exit 0 ;;
      *) die "Unknown option for check-shadowers: $1" ;;
    esac
    shift
  done

  if ! command_exists pkg-config; then
    die "pkg-config not found — install pkgconf or pkg-config first"
  fi

  _pc_dir="$PREFIX/lib/pkgconfig"
  if [ ! -d "$_pc_dir" ]; then
    die "No pkgconfig dir at $_pc_dir — run '$PROGNAME build' first"
  fi

  # Collect the .pc files that recipes have declared as transitive utils.
  # Each line of _order.conf is a recipe path. Source each in a subshell to
  # extract PKG_TRANSITIVE_UTIL and PKG_PC_FILES without polluting our scope.
  _expected_set=""
  while IFS= read -r _recipe_line; do
    [ -z "$_recipe_line" ] && continue
    case "$_recipe_line" in '#'*) continue ;; esac
    _recipe_path="$SCRIPT_DIR/$_recipe_line"
    [ -f "$_recipe_path" ] || continue
    _recipe_pcs=$(sh -c '. "$1" 2>/dev/null; [ "$PKG_TRANSITIVE_UTIL" = true ] && printf "%s\n" ${PKG_PC_FILES:-$PKG_NAME}' -- "$_recipe_path")
    [ -n "$_recipe_pcs" ] && _expected_set="$_expected_set $_recipe_pcs"
  done < "$SCRIPT_DIR/recipes/_order.conf"

  log "Auditing $_pc_dir against system pkgconfig path..."
  log ""

  _new=0
  _known=0

  # First pass: recipe-declared transitive utils. These were removed from the
  # workspace by recipes/ffmpeg.sh's queue-processing step, so they won't be
  # in the dir listing — but they're still valid audit subjects. Probe the
  # system for each and report it as [expected dropped] (recipe intent +
  # system has it, doctrine working as designed) or [expected NO SYSTEM]
  # (recipe dropped but system doesn't have it — falls through to nothing).
  for _e in $_expected_set; do
    if PKG_CONFIG_PATH="" pkg-config --exists "$_e" 2>/dev/null; then
      _sys_ver=$(PKG_CONFIG_PATH="" pkg-config --modversion "$_e" 2>/dev/null)
      log "  [expected dropped]   $_e  (system=$_sys_ver) — recipe intent + system fallback ✓"
      _known=$((_known + 1))
    else
      warn "  [expected NO SYSTEM] $_e — recipe dropped but system doesn't provide it; downstream consumers asking for $_e will fail"
      _known=$((_known + 1))
    fi
  done

  # Second pass: workspace .pc files that overlap with system. These ARE
  # being installed (not in the recipe-intent skip-queue) and might be a
  # missed transitive-util declaration. Codec libs (x264, vpx, x265, ...)
  # legitimately appear here because they're intentionally installed for
  # downstream static link.
  for _pc in "$_pc_dir"/*.pc; do
    [ -f "$_pc" ] || continue
    _name=$(basename "$_pc" .pc)
    _name_lc=$(printf '%s' "$_name" | tr '[:upper:]' '[:lower:]')
    # Skip names already covered by the expected-set pass.
    _in_expected=false
    for _e in $_expected_set; do
      if [ "$_e" = "$_name_lc" ] || [ "$_e" = "$_name" ]; then
        _in_expected=true
        break
      fi
    done
    [ "$_in_expected" = true ] && continue

    if PKG_CONFIG_PATH="" pkg-config --exists "$_name" 2>/dev/null; then
      _sys_ver=$(PKG_CONFIG_PATH="" pkg-config --modversion "$_name" 2>/dev/null)
      _prv_ver=$(awk -F': ' '/^Version:/ {print $2; exit}' "$_pc")
      warn "  [NEW SHADOW]         $_name  (private=$_prv_ver  system=$_sys_ver) — set PKG_TRANSITIVE_UTIL=true on the owning recipe if this should be dropped"
      _new=$((_new + 1))
    fi
  done

  log ""
  log "Expected drops (recipe-declared transitive utils): $_known"
  log "New shadows (recipe didn't declare):               $_new"

  if [ "$_new" -gt 0 ]; then
    warn "$_new new shadowing .pc file(s) found — review whether the owning recipe should set PKG_TRANSITIVE_UTIL=true"
    [ "$_strict" = true ] && exit 1
  fi
  exit 0
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
  makesum)        cmd_makesum "$@" ;;
  check-shadowers) cmd_check_shadowers "$@" ;;
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
