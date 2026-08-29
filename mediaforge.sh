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
. "$SCRIPT_DIR/lib/flags.sh"
. "$SCRIPT_DIR/lib/registry.sh"
. "$SCRIPT_DIR/lib/platform.sh"
. "$SCRIPT_DIR/lib/storage.sh"
. "$SCRIPT_DIR/lib/ccache.sh"
. "$SCRIPT_DIR/lib/download.sh"
. "$SCRIPT_DIR/lib/makesum.sh"
. "$SCRIPT_DIR/lib/cleanup.sh"
. "$SCRIPT_DIR/lib/pc-exclusions.sh"
. "$SCRIPT_DIR/lib/framework.sh"
. "$SCRIPT_DIR/lib/resolve.sh"
. "$SCRIPT_DIR/lib/menu.sh"

# The user's own flags, captured BEFORE mediaforge sets any of its own. These
# are the values the operator exported; per the GNU coding standards they belong
# to them, and mediaforge re-appends them last (see lib/flags.sh) so they win.
# Assigning over them, as this file did until now, both discarded them and
# suppressed autotools' "-g -O2" default -- which is why every autotools recipe
# was compiling at -O0. tests/compiler-flags.sh pins the rules.
MF_USER_CFLAGS="${CFLAGS-}"
MF_USER_CXXFLAGS="${CXXFLAGS-}"
MF_USER_LDFLAGS="${LDFLAGS-}"

# Compiler flags mediaforge itself requires. Kept SEPARATE from $CFLAGS, which
# is the composed line handed to recipes: conflating the two is what let a flag
# mediaforge discovered late (the lv2 recipe's lilv include path, written to
# $PREFIX/.extra_cflags and read after every recipe has run) land AFTER the
# user's flags and outrank them. mf_export_flags recomposes from these, so the
# user stays last however late mediaforge adds one of its own.
MF_OWN_CFLAGS="-I$PREFIX/include"
MF_OWN_CXXFLAGS="-I$PREFIX/include"
MF_OWN_LDFLAGS="-L$PREFIX/lib"
mf_export_flags
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
MF_CCACHE=auto
MF_ALLOW_TMPFS=false
# Debug build level: "" (off), symbols, balanced or full. See lib/flags.sh.
MF_DEBUG_LEVEL=""
FLITE_AUDIO="none"
SKIP_CHECKSUM=false
SKIP_CHECKSUM_PKGS=""
# Initialized here for the same reason as the two above: every consumer reads
# ${MAKESUM_MODE:-false}, so without this line `MAKESUM_MODE=true
# ./mediaforge.sh build` inherited recording mode from the environment --
# verification disabled for every fetch and the sidecars rewritten from
# whatever was fetched. cmd_makesum sets it after this point, which is the only
# way in.
MAKESUM_MODE=false

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
  printf '  reconcile          Check build stamps against the artifacts they vouch for\n'
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
  printf '      --allow-tmpfs         Build even when the working directory is on a RAM-backed\n'
  printf '                            filesystem (refused by default — a full tree is ~34GB)\n'
  printf '      --ccache              Compile through ccache; fail if it is not installed\n'
  printf '                            (default: used when installed, unless CCACHE_DISABLE is set)\n'
  printf '      --no-ccache           Do not use ccache, meson recipes included\n'
  printf '      --debug[=LEVEL]       Build with debug info. LEVEL is one of:\n'
  printf '                              symbols   -O2 -g3, assertions off, no measurable slowdown\n'
  printf '                              balanced  -Og -g3, assertions on, ~2x slower\n'
  printf '                              full      -O0 -g3, assertions on, 4-5x slower (default)\n'
  printf '                            Forces LTO off. Greatly enlarges the binary.\n'
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
  printf '\nMakesum options (used by the makesum subcommand):\n'
  printf '      --profile=X.Y         Record digests against a specific version profile\n'
  printf '      --update              Overwrite an existing digest that no longer matches\n'
  printf '      --allow-tmpfs         Fetch even when the working directory is on a\n'
  printf '                            RAM-backed filesystem (refused by default)\n'
  printf '      --build               Run a real build with recording enabled, to reach\n'
  printf '                            sub-build downloads (forwards remaining args to build;\n'
  printf '                            no package filter)\n'
  printf '\nChecksum verification (loud; never persisted to the stored choice matrix):\n'
  printf '      --skip-checksum       Disable verification for EVERY recipe\n'
  printf '      --skip-checksum=PKG   Disable verification for one recipe, by recipe filename or "ffmpeg" (repeatable, comma-separated ok)\n'
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

# _skip_checksum_banner
# The loud complement to every way of leaving the build unverified: called at
# both build start and build end so whoever bypassed the verification gate
# cannot miss it, and cannot miss it again if they scroll past the start.
# Silent when verification is fully on.
_skip_checksum_banner() {
  # Recording mode bypasses verification just as thoroughly as
  # --skip-checksum, and additionally overwrites the sidecars, so it announces
  # itself on the same terms. Unconditional rather than "only when it arrived
  # some unexpected way": `makesum --build` genuinely is a build with no
  # verification, and a reader who scrolls past that has been told.
  if [ "${MAKESUM_MODE:-false}" = true ]; then
    warn "================================================================"
    warn "makesum recording is ACTIVE: digests are RECORDED, not verified"
    warn "  Every fetched file overwrites its recorded digest"
    warn "================================================================"
  fi
  [ "$SKIP_CHECKSUM" = true ] || [ -n "${SKIP_CHECKSUM_PKGS:-}" ] || return 0
  warn "================================================================"
  warn "--skip-checksum is ACTIVE: checksum verification is bypassed"
  [ "$SKIP_CHECKSUM" = true ] && warn "  ALL recipes: verification disabled"
  [ -n "${SKIP_CHECKSUM_PKGS:-}" ] && warn "  Named recipes: ${SKIP_CHECKSUM_PKGS}"
  warn "================================================================"
}

# _add_skip_checksum VALUE
# Append --skip-checksum=VALUE's comma- or space-separated recipe names to
# SKIP_CHECKSUM_PKGS, single-space separated with no leading space.
#
# The normalization is load-bearing, not tidiness: checksum_skipped searches
# the list as a substring of a space-padded window, so a leading space opened
# that window with "  " and made the empty string a member of every list. An
# empty VALUE is rejected outright for the same reason, and because it arms the
# banner with a bypass that names nothing.
_add_skip_checksum() {
  # Every separator the SHELL would accept, not just the two a user is likely
  # to type. validate_pkg_names word-splits this list on $IFS, which includes
  # tab and newline, so a tab-separated pair validated cleanly and was reported
  # skipped in the banner -- while checksum_skipped, which searches a
  # space-padded window for " name ", never matched either of them. A separator
  # that validates but cannot match is the worst outcome for a verification
  # bypass, because the user is told it happened.
  #
  # PORTABILITY, since this is the shape a strict port would break: POSIX says
  # the result is UNSPECIFIED when string2 is shorter than string1, and notes
  # that BSD pads with the last character while System V does not. Every tr
  # mediaforge runs on -- GNU coreutils, BSD/macOS, busybox -- pads, so every
  # character in the class maps to a space. Do not "simplify" this to a
  # System V-safe form by dropping members of the class.
  _asc=$(printf '%s' "$1" | tr -s '[:space:],' ' ')
  _asc="${_asc# }"
  _asc="${_asc% }"
  [ -n "$_asc" ] || die "--skip-checksum= requires at least one recipe name (use bare --skip-checksum to disable verification everywhere)"
  if [ -z "$SKIP_CHECKSUM_PKGS" ]; then
    SKIP_CHECKSUM_PKGS="$_asc"
  else
    SKIP_CHECKSUM_PKGS="$SKIP_CHECKSUM_PKGS $_asc"
  fi
}

# ─── Build ───────────────────────────────────────────────────────────

# Source the requested version profile, if one was named.
#
# Three subcommands need it -- build, check-updates and makesum -- and each had
# its own copy. They had already drifted: two logged which profile was in use and
# one did so silently, so `check-updates --profile=7.1` gave no indication it was
# reading 7.1's pins. One definition, and it always says.
load_profile() {
  [ -n "$PROFILE_NAME" ] || return 0
  _profile_file="$SCRIPT_DIR/profiles/ffmpeg-${PROFILE_NAME}.conf"
  if [ ! -f "$_profile_file" ]; then
    die "Profile not found: $_profile_file"
  fi
  # shellcheck disable=SC1090
  . "$_profile_file"
  log "Using profile: ffmpeg-${PROFILE_NAME}"
}

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
      --debug)             MF_DEBUG_LEVEL=full ;;
      --debug=*)
        MF_DEBUG_LEVEL="${1#--debug=}"
        mf_debug_level_valid "$MF_DEBUG_LEVEL" \
          || die "Unknown --debug level '$MF_DEBUG_LEVEL' (use symbols, balanced or full)"
        ;;
      --enable-lto)        ENABLE_LTO=true ;;
      --disable-lto)       ENABLE_LTO=false ;;
      --allow-tmpfs)       MF_ALLOW_TMPFS=true ;;
      --ccache)            MF_CCACHE=true ;;
      --no-ccache)         MF_CCACHE=false ;;
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
      --skip-checksum=*)   _add_skip_checksum "${1#--skip-checksum=}" ;;
      --skip-checksum)     SKIP_CHECKSUM=true ;;
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

  # Validate every requested name against the recipe registry.
  # --skip-checksum additionally accepts "ffmpeg": it is not a selectable
  # package (recipes/ffmpeg.sh is sourced directly by cmd_build, not listed in
  # _order.conf) but it is a real sidecar with a real digest, and until it was
  # accepted here the FFmpeg tarball was the one file that could not be
  # deliberately skipped.
  validate_pkg_names "$DISABLE_PKGS $ENABLE_PKGS"
  validate_pkg_names "$SKIP_CHECKSUM_PKGS" ffmpeg

  # Hoisted out of the menu block below so that a contradiction in the ARGUMENTS
  # is reported before anything about the environment. A user who typed two
  # flags that cannot combine should be told which two, not told about their
  # filesystem -- and the storage guard sits between the two for exactly that
  # reason.
  if [ "$USE_MENU" = true ] && [ "$AUTOINSTALL" = "yes" ]; then
    die "--menu and --yes are mutually exclusive"
  fi

  # Storage before anything is created or written, which means HERE rather than
  # beside the tool pre-flight further down: save_stored_choices and the
  # .debug-level write both mkdir $PREFIX first, so a guard placed with the
  # other checks refuses a /tmp build only after having created a directory in
  # tmpfs -- and after run_menu has taken the operator through a full selection
  # to tell them no. The option loop above is all this needs: $TOPDIR is fixed
  # at startup and $MF_ALLOW_TMPFS is settled by the parse.
  #
  # A dry run is exempt because it writes nothing -- it prints the plan and
  # stops. Guarding it would refuse an operation that cannot cause the problem,
  # and would refuse it in the ordinary case rather than an exotic one: every
  # test that exercises the parser runs mediaforge from a mktemp -d scratch
  # TOPDIR (tests/lib-scratch.sh), and mktemp answers under /tmp, which is
  # tmpfs on Linux.
  if [ "${DRY_RUN:-false}" != true ]; then
    mf_storage_guard "$TOPDIR" "$MF_ALLOW_TMPFS"
  fi

  if [ "$USE_MENU" = true ]; then
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
  _skip_checksum_banner

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
  #
  # Composed here rather than at the assignment above because this is the point
  # at which every flag mediaforge itself contributes is known -- -fPIC is added
  # after option parsing. The user's flags go last so an explicit -march or
  # -fsanitize from their environment reaches the compiler instead of being
  # silently dropped. Note that "last wins" settles the command line only: a
  # cmake recipe pinned to Release still appends -O3 -DNDEBUG after these, so an
  # operator's -O0 survives for autotools and meson recipes but not cmake ones.
  # See the SCOPE note in lib/flags.sh.
  MF_OWN_CFLAGS="$MF_OWN_CFLAGS -fPIC"
  MF_OWN_CXXFLAGS="$MF_OWN_CXXFLAGS -fPIC"

  # A debug level changes the optimization mediaforge defaults to, and adds the
  # symbol flags. The optimization goes through MF_DEFAULT_OPT rather than being
  # appended separately, so it stays in the one place that decides optimization
  # and the operator's own -O still wins by coming last.
  # A workspace remembers the level it was built at, and a mismatch is refused.
  #
  # stamp_check keys only on "<name>-<version>", so nothing about a build's FLAGS
  # is captured. Without this guard, `build` followed by `build --debug` rebuilds
  # nothing but FFmpeg: you get a debug ffmpeg linked against ~110 stripped, -O2,
  # NDEBUG'd archives -- and it compiles, links and runs, so the only symptom is
  # stack traces that are quietly wrong in every library. That is the precise
  # failure this feature exists to prevent, one layer above where it operates.
  #
  # Refused rather than warned. lib/resolve.sh warns for the analogous TLS-arm
  # case, and a warning is right there because the build still does what it says
  # with the wrong arm. Here the deliverable IS the thing being skipped, so a
  # warning scrolls past and the operator debugs against symbols that were never
  # built.
  _mf_lvlfile="$PREFIX/.debug-level"
  _mf_prev=""
  [ -f "$_mf_lvlfile" ] && _mf_prev=$(cat "$_mf_lvlfile" 2>/dev/null)
  if [ "$_mf_prev" != "$MF_DEBUG_LEVEL" ] && [ -d "$PREFIX/.stamps" ] &&
     [ -n "$(ls -A "$PREFIX/.stamps" 2>/dev/null)" ]; then
    warn "This workspace was built at debug level '${_mf_prev:-none}'; you asked for '${MF_DEBUG_LEVEL:-none}'."
    warn "Build stamps record only name and version, so the already-built recipes"
    warn "would NOT be rebuilt and the result would mix the two levels silently."
    warn "Rebuild them with either:"
    warn "    ./mediaforge.sh clean"
    warn "    rm -rf $PREFIX/.stamps"
    die "refusing to produce a mixed-level workspace"
  fi
  # Not written on a dry run. A dry run must leave the workspace exactly as it
  # found it -- the same reason $PREFIX/.mediaforge-choices is skipped there --
  # and recording a level for a build that never happened would make the next
  # real build believe the workspace already matches.
  if [ "${DRY_RUN:-false}" != true ]; then
    mkdir -p "$PREFIX"
    printf '%s' "$MF_DEBUG_LEVEL" > "$_mf_lvlfile"
  fi

  if [ -n "$MF_DEBUG_LEVEL" ]; then
    # --enable-small wins over the level for FFmpeg ITSELF: its configure picks
    # optflags in the order small -> optimizations -> noopt, so libav* compiles
    # at -Os while every dependency honours the level. Said out loud because the
    # two flags are individually reasonable and the interaction is not visible.
    if [ "$_enable_small" = true ]; then
      warn "--enable-small overrides --debug for FFmpeg itself: libav* will build at -Os"
      warn "(the ~110 dependencies still honour the debug level)"
    fi
    MF_DEFAULT_OPT=$(mf_debug_opt "$MF_DEBUG_LEVEL")
    _mf_dbg_cflags=$(mf_debug_cflags "$MF_DEBUG_LEVEL")
    MF_OWN_CFLAGS="$MF_OWN_CFLAGS $_mf_dbg_cflags"
    MF_OWN_CXXFLAGS="$MF_OWN_CXXFLAGS $_mf_dbg_cflags"
    # LTO discards the per-function debug info that makes stepping work, so the
    # two together produce a slow build with unreliable symbols. Forced off, and
    # said out loud rather than honoured silently.
    if [ "$ENABLE_LTO" = true ]; then
      warn "--debug forces LTO off: LTO discards the debug info it would emit"
      ENABLE_LTO=false
    fi
  fi

  mf_export_flags
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
  load_profile

  # Setup traps
  setup_traps

  # Pre-flight checks
  command_exists "make" || die "make not installed"
  command_exists "g++"  || die "g++ not installed"
  command_exists "curl" || die "curl not installed"

  # After the compiler pre-flight above: the masquerade directory links the names
  # that resolve, so a tree with no compiler should fail on the missing compiler
  # rather than on an empty directory. The state-to-behaviour table lives in
  # lib/ccache.sh, beside the mechanism it selects.
  mf_ccache_apply "$MF_CCACHE"

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

  # Preflight the stamps against the workspace before building anything
  # (GH-59). A stamp whose artifact is gone is not evidence that a recipe was
  # built, and leaving it in place is what makes the next build SKIP that
  # recipe and fail later at FFmpeg's configure or link step, nowhere near the
  # cause.
  #
  # Drifted stamps are DROPPED here rather than merely reported. Dropping one
  # costs a rebuild of exactly that recipe; keeping one costs a build that
  # cannot work and whose failure points somewhere else. Nothing the operator
  # authored is touched -- a stamp is mediaforge's own bookkeeping. The
  # reconcile subcommand is the read-only view of the same check.
  #
  # A DRY RUN reports and drops nothing. Its contract is "show what would
  # build", and deleting files is not something a flag that promises to touch
  # nothing may do -- the per-recipe dry-run short-circuit is in run_recipe,
  # far below this point, so without this branch `build --dry-run` would prune.
  if [ "${DRY_RUN:-false}" = true ]; then
    _rc_quiet=true
    _reconcile_stamps
    if [ "$_rc_drifted" -gt 0 ]; then
      warn "$_rc_drifted build stamp(s) vouch for artifacts that are gone."
      warn "  A real build would drop them and rebuild those recipes."
    fi
  else
    mf_build_preflight_stamps
  fi

  # Reset the pc-skip queue at the start of every build. Recipes with
  # PKG_TRANSITIVE_UTIL=true append their .pc filenames; recipes/ffmpeg.sh
  # finalizes the queue after FFmpeg's configure has consumed the .pc files.
  # See lib/pc-exclusions.sh for why the finalized list is not reset here.
  pc_exclusions_reset

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

  # Read extra flags from accumulator files (written by recipes like lv2,
  # nv-codec). These are mediaforge's OWN flags discovered during the run, so
  # they accumulate into MF_OWN_* and the line is recomposed below -- appending
  # them to $CFLAGS directly would place them after the user's flags and let
  # them override an explicit choice.
  if [ -f "$PREFIX/.extra_cflags" ]; then
    while IFS= read -r _flag || [ -n "$_flag" ]; do
      MF_OWN_CFLAGS="$MF_OWN_CFLAGS $_flag"
    done < "$PREFIX/.extra_cflags"
  fi
  if [ -f "$PREFIX/.extra_ldflags" ]; then
    while IFS= read -r _flag || [ -n "$_flag" ]; do
      MF_OWN_LDFLAGS="$MF_OWN_LDFLAGS $_flag"
    done < "$PREFIX/.extra_ldflags"
  fi
  # Both accumulators have been read, so mediaforge has now contributed every
  # flag it is going to. Recompose once, here, rather than inside either loop.
  mf_export_flags

  # If on Linux and nvcc not found, explicitly disable ffnvcodec
  if [ "$OS_LINUX" = true ] && ! command_exists nvcc; then
    FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS --disable-ffnvcodec"
  fi

  # recipes/ffmpeg.sh is sourced directly rather than through run_recipe(),
  # so the DRY_RUN short-circuit above (mirrored from lib/framework.sh) never
  # reaches it. Stop here to keep a dry run from fetching/extracting FFmpeg
  # and falling through to the install step.
  if [ "${DRY_RUN:-false}" = true ]; then
    log "Would build FFmpeg $FFMPEG_VERSION"
    log "Would configure FFmpeg with:$FFMPEG_CONFIGURE_OPTS"
    _skip_checksum_banner
    return 0
  fi

  # Build FFmpeg
  . "$SCRIPT_DIR/recipes/ffmpeg.sh"

  # Install (unless --no-install)
  if [ "$SKIP_INSTALL" != "yes" ]; then
    . "$SCRIPT_DIR/lib/install.sh"
    do_install ""
  fi

  _skip_checksum_banner
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

  load_profile

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
      --allow-tmpfs) MF_ALLOW_TMPFS=true ;;
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
      # --build reaches the fetch() calls nested inside a recipe phase
      # function (lv2's sub-tarballs, opencl's ICD-Loader, libcdio's paranoia
      # sub-package, vid_stab's cmake-quoting patch) that a fetch-only pass
      # never sources far enough to see. That set is pinned by
      # tests/checksum-verification.sh's nested-fetch-recipes-are-the-documented-set;
      # no count is stated here, because the count in this comment has already
      # been wrong twice.
      # recipes/ffmpeg.sh is not among them: its fetch is at that
      # file's top level, and plain `makesum` records it via
      # makesum_fetch_and_record. Consumed, never forwarded: cmd_build has no
      # such flag of its own.
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
    makesum_update_summary
    return
  fi

  load_profile

  # Same validation cmd_build's --enable=/--disable= go through, so a typo
  # fails fast with a suggestion instead of silently matching nothing.
  validate_pkg_names "$_mk_pkgs"

  # The fetch-only path downloads every tarball in _order.conf into $DISTDIR --
  # the same directory, the same filesystem and the same failure a build has, so
  # it gets the same guard. The --build path above does not need one here:
  # cmd_build applies it before writing anything. install writes to the chosen
  # prefix rather than $TOPDIR, and check-updates only talks to the network, so
  # neither is in scope.
  #
  # After the name validation, not before it, for the reason cmd_build hoists
  # its mutex check: a typo in an argument is the operator's to fix and must be
  # reported as itself, rather than masked by a complaint about the filesystem.
  # tests/checksum-verification.sh pins that both subcommands answer a bad name
  # identically, which is what caught the first ordering.
  #
  # $TOPDIR, not $DISTDIR: packages/ does not exist until the first fetch
  # creates it, and both probes fail open on a path that is not there -- so
  # guarding $DISTDIR returned 0 on precisely the fresh tree it was added to
  # protect, and makesum went on to download. $TOPDIR always exists and is the
  # same filesystem, which the condition below has just established.
  #
  # That condition is a HARNESS carve-out, not an operator one. There is no
  # --distdir flag and no environment override -- line 13 assigns
  # DISTDIR="$TOPDIR/packages" unconditionally -- so the only thing that can
  # take the false branch is an in-process caller that set DISTDIR before
  # calling cmd_makesum, which is what tests/checksum-verification.sh does with
  # its own small fixture directories.
  if [ "$DISTDIR" = "$TOPDIR/packages" ]; then
    mf_storage_guard "$TOPDIR" "$MF_ALLOW_TMPFS"
  fi

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
    makesum_fetch_and_record "$PKG_HASH_FILE" "$_mk_file" "$PKG_URL"
  done < "$SCRIPT_DIR/recipes/_order.conf"

  # FFmpeg itself is sourced directly by cmd_build (recipes/ffmpeg.sh), not
  # listed in _order.conf, so the loop above never reaches it -- the only
  # other path that could record its digest is `makesum --build`, which needs
  # the whole dependency chain built first. Only when no package filter was
  # given: a scoped `makesum somepkg` should record exactly that package, not
  # silently also touch FFmpeg (which isn't itself a selectable package name
  # in the registry `is_known_pkg` already validated `_mk_pkgs` against above).
  if [ -z "$_mk_pkgs" ]; then
    makesum_fetch_and_record "$(ffmpeg_hash_file)" "$(ffmpeg_tarball_filename)" "$(ffmpeg_tarball_url)"
  fi

  makesum_update_summary
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
        printf '  [expected dropped]   — recipe declared PKG_TRANSITIVE_UTIL=true and the\n'
        printf '                         system provides it; .pc kept in the workspace, not installed\n'
        printf '  [expected NO SYSTEM] — recipe drops it but the system has no replacement\n'
        printf '  [NEW SHADOW]         — would be installed AND system has it; review whether the\n'
        printf '                         recipe should set PKG_TRANSITIVE_UTIL=true\n\n'
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
  #
  # Derived here rather than read from $PREFIX/.pc-exclude, which lib/framework.sh
  # queues and recipes/ffmpeg.sh finalizes from the same two variables. The two
  # answer different questions and only one of them is available: this command
  # audits what the RECIPES declare, and has to work on a tree no build has
  # finished, where the record does not exist yet.
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

  # First pass: recipe-declared transitive utils. These stay in the workspace
  # — the next build links against them — and are excluded at install time
  # instead, so the dir listing says nothing about them either way. Probe the
  # system for each and report it as [expected dropped] (recipe intent +
  # system has it, doctrine working as designed) or [expected NO SYSTEM]
  # (recipe drops it but the system doesn't have it — falls through to
  # nothing). "Dropped" is about the INSTALL prefix throughout.
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
  # being installed (no recipe declared them) and might be a missed
  # transitive-util declaration. Codec libs (x264, vpx, x265, ...)
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

# ─── Reconcile ───────────────────────────────────────────────────────
#
# Compare the workspace's build stamps against the artifacts they vouch for
# (GH-59). Two directions, and they are not equally serious:
#
#   stamp present, artifact GONE   — the next build SKIPS a recipe it did not
#                                    actually build, and the failure surfaces at
#                                    FFmpeg's configure or link step, far from
#                                    the cause. This is the direction worth a
#                                    gate, and the one --prune fixes.
#   artifact present, stamp GONE   — a silent rebuild of work already done.
#                                    Wasteful, not incorrect, so it is reported
#                                    and nothing more.
#
# Reading recipe metadata out of _order.conf follows cmd_check_shadowers, which
# audits the same workspace from the other end.

# Report each stamp as verified / drifted / unverifiable, printing the missing
# paths for the drifted ones. Sets _rc_drifted to the count and _rc_drifted_list
# to the stamp paths, one per line.
#
# The list is what --prune acts on, rather than prune re-deriving "which stamps
# are drifted" from the filesystem a second time. One decision, made once: a
# second copy of the rule would be free to disagree with the report the operator
# just read, and prune is a DELETE.
_reconcile_stamps() {
  _rc_drifted=0
  _rc_verified=0
  _rc_unverifiable=0
  _rc_drifted_list=""

  for _rc_stamp in "$PREFIX/.stamps"/*; do
    [ -f "$_rc_stamp" ] || continue
    _rc_name=$(basename "$_rc_stamp")

    # An empty stamp is a stamp with no manifest, not a stamp with no files:
    # every stamp written before GH-59 is empty, as is every stamp for a recipe
    # that installs through a bare shell `cp` and stages nothing. Reporting
    # those as drift would be a false positive on a majority of a legacy
    # workspace, which is the fastest way to teach someone to ignore this
    # command.
    if [ ! -s "$_rc_stamp" ]; then
      _rc_unverifiable=$((_rc_unverifiable + 1))
      [ "$_rc_quiet" = true ] || log "  [unverifiable] $_rc_name — stamp carries no manifest"
      continue
    fi

    # Newline-separated, and filtered by the same helper lib/stage.sh uses to
    # keep a manifest sound -- one definition of "is this recorded path still
    # there", asked here in the opposite polarity. Space-separated with `for`
    # would word-split a path containing a space into two bogus report lines and
    # glob one containing `*` against the cwd; the drift DECISION would still be
    # right, but the report is what the operator acts on.
    _rc_missing=$(mf_stage_filter_paths missing < "$_rc_stamp")

    if [ -n "$_rc_missing" ]; then
      _rc_drifted=$((_rc_drifted + 1))
      _rc_drifted_list="$_rc_drifted_list$_rc_stamp
"
      warn "  [DRIFTED]      $_rc_name — the stamp vouches for files that are gone:"
      printf '%s\n' "$_rc_missing" | while IFS= read -r _rc_m; do
        [ -n "$_rc_m" ] || continue
        warn "                   $_rc_m"
      done
    else
      _rc_verified=$((_rc_verified + 1))
      [ "$_rc_quiet" = true ] || log "  [verified]     $_rc_name"
    fi
  done
}

# The other direction: a recipe with no stamp whose .pc is nonetheless sitting
# in the workspace. Heuristic by construction — it can only ask about recipes
# that ship a .pc, and PKG_PC_FILES defaults to PKG_NAME — so it is advisory and
# never gates anything.
_reconcile_orphan_artifacts() {
  _rc_orphans=0
  while IFS= read -r _rc_line; do
    [ -z "$_rc_line" ] && continue
    case "$_rc_line" in '#'*) continue ;; esac
    _rc_recipe="$SCRIPT_DIR/$_rc_line"
    [ -f "$_rc_recipe" ] || continue

    _rc_meta=$(sh -c '. "$1" 2>/dev/null; printf "%s\n%s\n" "$PKG_NAME" "${PKG_PC_FILES:-$PKG_NAME}"' -- "$_rc_recipe")
    _rc_pkg=$(printf '%s\n' "$_rc_meta" | sed -n 1p)
    _rc_pcs=$(printf '%s\n' "$_rc_meta" | sed -n 2p)
    [ -n "$_rc_pkg" ] || continue

    _rc_stamped=false
    for _rc_s in "$PREFIX/.stamps/${_rc_pkg}-"*; do
      [ -f "$_rc_s" ] && _rc_stamped=true && break
    done
    [ "$_rc_stamped" = true ] && continue

    for _rc_pc in $_rc_pcs; do
      if [ -f "$PREFIX/lib/pkgconfig/${_rc_pc}.pc" ]; then
        warn "  [lost stamp]   $_rc_pkg — lib/pkgconfig/${_rc_pc}.pc is present with no stamp; it will be rebuilt"
        _rc_orphans=$((_rc_orphans + 1))
        break
      fi
    done
  done < "$SCRIPT_DIR/recipes/_order.conf"
}

# Delete the stamps _reconcile_stamps just reported as drifted.
#
# Shared by `reconcile --prune` and the build preflight so the two cannot
# disagree about which stamps go: the list comes from the run that produced the
# report the operator read, never from a second walk of the filesystem.
_reconcile_prune() {
  printf '%s' "$_rc_drifted_list" | while IFS= read -r _rc_stamp; do
    [ -n "$_rc_stamp" ] || continue
    log "Pruning stamp $(basename "$_rc_stamp")"
    rm -f "$_rc_stamp"
  done
}

# Build preflight: drop any stamp whose artifacts are gone, so this build redoes
# exactly those recipes instead of skipping them (GH-59).
#
# Quiet on a clean workspace -- a preflight that prints a line per stamp on
# every build is one nobody reads.
mf_build_preflight_stamps() {
  [ -d "$PREFIX/.stamps" ] || return 0
  _rc_quiet=true
  _reconcile_stamps
  [ "$_rc_drifted" -gt 0 ] || return 0
  warn "$_rc_drifted build stamp(s) vouch for artifacts that are no longer present."
  warn "  Dropping them so this build rebuilds those recipes rather than skipping them."
  _reconcile_prune
}

cmd_reconcile() {
  _rc_prune=false
  _rc_quiet=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --prune) _rc_prune=true ;;
      --quiet|-q) _rc_quiet=true ;;
      -h|--help)
        printf 'Usage: %s reconcile [--prune] [--quiet]\n\n' "$PROGNAME"
        printf 'Check each build stamp against the artifacts it vouches for.\n'
        printf 'Reports each stamp as:\n'
        printf '  [verified]      every path in the stamp is present\n'
        printf '  [DRIFTED]       the stamp names a path that is gone — the next\n'
        printf '                  build would SKIP this recipe without building it\n'
        printf '  [unverifiable]  the stamp carries no manifest (written by an older\n'
        printf '                  mediaforge, or by a recipe that installs with a\n'
        printf '                  plain cp and so stages nothing)\n\n'
        printf '  --prune    delete the drifted stamps, so the next build redoes\n'
        printf '             exactly those recipes\n'
        printf '  --quiet    report only problems (no header, no summary)\n'
        exit 0 ;;
      *) die "Unknown option for reconcile: $1" ;;
    esac
    shift
  done

  [ -d "$PREFIX/.stamps" ] || die "No stamps at $PREFIX/.stamps — run '$PROGNAME build' first"

  # --quiet means only problems, and that has to include the framing. A mode
  # documented as "report only problems" that still prints a header, two blank
  # lines and a summary on a clean workspace is not quiet, and the help text
  # would be the false half of the pair.
  if [ "$_rc_quiet" != true ]; then
    log "Reconciling $PREFIX/.stamps against the workspace..."
    log ""
  fi
  _reconcile_stamps
  _reconcile_orphan_artifacts
  if [ "$_rc_quiet" != true ]; then
    log ""
    log "verified: $_rc_verified   drifted: $_rc_drifted   unverifiable: $_rc_unverifiable   lost stamps: $_rc_orphans"
  fi

  if [ "$_rc_drifted" -gt 0 ]; then
    if [ "$_rc_prune" = true ]; then
      _reconcile_prune
      log "Pruned $_rc_drifted drifted stamp(s). The next build will redo those recipes."
      exit 0
    fi
    warn "$_rc_drifted stamp(s) vouch for artifacts that are gone."
    warn "  Re-run with --prune to drop them so the next build redoes those recipes."
    exit 1
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
  reconcile)      cmd_reconcile "$@" ;;
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
