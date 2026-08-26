# shellcheck disable=SC2154,SC2034
# Resolver — translate per-group flags + stored choices + profile defaults
# into a final DISABLE_PKGS string. Idempotent.
# SC2034: _GROUP constants are read indirectly via `eval` (see promote_choice
# loop) and REBUILD_OUTDATED is read by lib/utils.sh — shellcheck can't trace
# either pattern statically.

# Per-group user choices (set from CLI; empty means "not chosen").
TLS_BACKEND=""
AAC_IMPL=""
H264_IMPL=""
H265_IMPL=""
AV1_ENC_IMPL=""
SPIRV_IMPL=""

# Compiled-in OPENSSLDIR for the openssl and libressl arms (empty = "not chosen",
# whereupon each recipe resolves its own default). Set from --openssldir.
OPENSSLDIR=""

# Conservative defaults (used when non-interactive and nothing else resolves).
TLS_BACKEND_DEFAULT_BUILTIN="gnutls"
AAC_IMPL_DEFAULT_BUILTIN="native"
H264_IMPL_DEFAULT_BUILTIN="x264"
H265_IMPL_DEFAULT_BUILTIN="x265"
AV1_ENC_IMPL_DEFAULT_BUILTIN="svtav1"
SPIRV_IMPL_DEFAULT_BUILTIN="glslang"

# Members of each mutex group (excluding sentinels like "none" and "native").
TLS_GROUP="openssl gnutls mbedtls libressl"
AAC_GROUP="fdk_aac"
H264_GROUP="x264 openh264"
H265_GROUP="x265 kvazaar"
AV1_ENC_GROUP="svtav1 rav1e av1"   # av1 = libaom recipe filename
SPIRV_GROUP="glslang shaderc"

# Given a chosen TLS backend, return the space-separated list of TLS-related
# packages that must be disabled. gmp/nettle are gnutls build-deps.
tls_disable_companions() {
  case "$1" in
    gnutls)   echo "openssl mbedtls libressl" ;;
    openssl)  echo "gnutls gmp nettle mbedtls libressl" ;;
    mbedtls)  echo "openssl gnutls gmp nettle libressl" ;;
    libressl) echo "openssl gnutls gmp nettle mbedtls" ;;
    none)     echo "openssl gnutls gmp nettle mbedtls libressl" ;;
    *)        echo "" ;;
  esac
}

# Host trust-store directories probed when --openssldir is not given, in order.
#
# These are DIRECTORIES whose child is literally cert.pem, not bundle files:
# libtls derives its compiled-in TLS_DEFAULT_CA_FILE as <openssldir>/cert.pem
# (tls/Makefile.am:53). That makes the list narrower than curl's bundle-file
# list — Debian/Ubuntu ship /etc/ssl/certs/ca-certificates.crt and no cert.pem,
# so they fall through to the caller's fallback by design. Fedora/RHEL DO have
# one at /etc/pki/tls/cert.pem, which is why that directory is listed second;
# it is also the entry gnutls's own probe carries (configure.ac:1363).
#
# Probing the build host for a trust store is the ecosystem norm, not a
# shortcut: curl does it (acinclude.m4, CURL_CHECK_CA_BUNDLE) and so does
# gnutls (configure.ac:1359-1372), both with an explicit override and a warning
# on a miss. curl additionally skips the probe when cross-compiling; mediaforge
# has no cross-compilation support at all, so there is no equivalent gate here.
OPENSSLDIR_CANDIDATES_DEFAULT="/etc/ssl /etc/pki/tls /usr/local/etc/ssl /opt/homebrew/etc/ca-certificates /usr/local/etc/ca-certificates"

# resolve_openssldir EXPLICIT FALLBACK [CANDIDATES]
#
# Resolve the compiled-in OPENSSLDIR: EXPLICIT (the --openssldir value) wins,
# else the first candidate directory that actually holds a cert.pem, else
# FALLBACK.
#
# EXPLICIT is a PARAMETER rather than a global, so the most important input is
# visible at every call site. The installer is a separate process that loads no
# choices of its own; a global would let it resolve as though the user had
# passed nothing, and silently bake a different path than the build did.
# Sets OPENSSLDIR_RESOLVED (the directory) and OPENSSLDIR_FROM (cli|host|
# fallback). Never fails.
#
# OPENSSLDIR_FROM reports HOW the decision was made (cli|host|fallback). No
# production caller needs it today — lib/install.sh branches on where the path
# lands relative to the two prefixes, which is a different question — but the
# probe tests assert on it, and a resolver that returns a bare path cannot be
# asked why.
#
# CANDIDATES is a parameter rather than an ambient variable so the probe can be
# driven from a synthetic root in tests without exposing a knob that a stray
# environment variable could use to silently change a real build's trust store.
resolve_openssldir() {
  _explicit=$1
  _fallback=$2
  _candidates=${3-$OPENSSLDIR_CANDIDATES_DEFAULT}

  if [ -n "$_explicit" ]; then
    OPENSSLDIR_RESOLVED="$_explicit"
    OPENSSLDIR_FROM="cli"
    return 0
  fi

  for _cand in $_candidates; do
    if [ -f "$_cand/cert.pem" ]; then
      OPENSSLDIR_RESOLVED="$_cand"
      OPENSSLDIR_FROM="host"
      return 0
    fi
  done

  OPENSSLDIR_RESOLVED="$_fallback"
  OPENSSLDIR_FROM="fallback"
}

# Validate a value against a "|"-separated enum. Aborts on mismatch.
_validate_enum() {
  _name=$1; _value=$2; _allowed=$3
  case "|$_allowed|" in
    *"|$_value|"*) return 0 ;;
  esac
  die "Invalid $_name: $_value. Allowed: $(printf '%s' "$_allowed" | tr '|' ',')"
}

# openssldir_warn_if_changed PREVIOUS CURRENT
#
# A changed openssldir on an existing workspace will NOT rebuild the TLS arm:
# the build stamp is keyed on <pkg>-<version> (lib/utils.sh stamp_check), and
# the compiled-in trust store is not part of that identity. Warn rather than
# abort, and rather than tracking it in state of our own — .mediaforge-choices
# already persists the previous value, and the user can act on the message.
#
# This is the common path into the flag: build, find https:// has no trust
# store, re-run with --openssldir. Silence there bakes the old path.
openssldir_warn_if_changed() {
  [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ] || return 0
  warn "--openssldir changed ('$1' -> '$2')."
  warn "  The build stamp does not capture it, so an already-built TLS arm is"
  warn "  skipped and keeps the OLD baked path. To rebuild against the new one:"
  warn "    rm -f $PREFIX/.stamps/libressl-* $PREFIX/.stamps/openssl-*"
}

# Validate a path that is compiled into a library, persisted across runs, and
# used as a privileged write destination. Aborts on anything unsafe.
#
# Every other persisted choice (TLS_BACKEND, AAC_IMPL, ...) is constrained by
# _validate_enum to a fixed literal set, so none of them can carry a shell
# metacharacter or a traversal. This is the first free-form value in that
# pipeline, and it reaches two places where unconstrained content is dangerous:
#
#   * lib/install.sh matches it with `case "$_install_prefix"/*` and passes the
#     result to _install_file, which runs mkdir -p and cp under $_priv (sudo,
#     for a system prefix). The glob constrains the prefix but not the suffix,
#     so '/usr/local/../../etc/ssl' matches and escapes — a privileged write to
#     an arbitrary path, e.g. over the host's real trust store. A glob
#     metacharacter in the value changes what that same `case` matches.
#   * save_stored_choices writes it as ONE LINE of $PREFIX/.mediaforge-choices,
#     and both readers (_stored_choice here, and lib/install.sh) split that
#     line at its first '=' and take the remainder. A newline in the value
#     forges a second record; a single quote breaks the quoting the writer
#     wraps it in.
#
# NOT because the file is sourced — it no longer is. It was, and that made this
# the difference between a stored string and arbitrary code on the next build;
# _stored_choice replaced the source with a by-name parser, so that specific
# consequence is gone. The check stays because the privileged write path above
# is unchanged and is reason enough on its own, and because a value that cannot
# carry shell syntax is one fewer thing every future reader of this file has to
# be careful with.
_validate_openssldir() {
  _name=$1; _value=$2; _why=$3
  [ -z "$_value" ] && return 0

  case "$_value" in
    /*) : ;;
    *) die "Invalid $_name: '$_value' is not an absolute path. $_why" ;;
  esac

  # Conservative allowlist rather than a metacharacter blocklist: a blocklist of
  # shell-special characters is a list you can forget an entry from.
  case "$_value" in
    *[!A-Za-z0-9_./+-]*)
      die "Invalid $_name: '$_value' contains characters that are not allowed.
  Permitted: letters, digits, and _ . / + -
  The value is stored as one line in $PREFIX/.mediaforge-choices and read back
  on the next build, and it is used as an install destination that may be
  written with sudo." ;;
  esac

  case "$_value" in
    */../*|*/..)
      die "Invalid $_name: '$_value' contains a '..' segment.
  The value is used as an install destination that may be written with sudo, so
  it must not be able to traverse out of the prefix it appears to be under." ;;
  esac
}

# Top-level resolver. Mutates DISABLE_PKGS in place. Idempotent.
resolve_choices() {
  # Smart prompts: ask interactively when the user did not pick.
  if is_interactive; then
    if [ -z "$TLS_BACKEND" ]; then
      TLS_BACKEND=$(menu_radiolist \
        "Pick a TLS backend" "$TLS_BACKEND_DEFAULT_BUILTIN" \
        gnutls   "GnuTLS — free, default" \
        openssl  "OpenSSL — Apache 2.0" \
        mbedtls  "mbedTLS — small footprint" \
        libressl "LibreSSL libtls" \
        none     "No TLS support") || die "TLS prompt cancelled"
    fi
    if [ -z "$AAC_IMPL" ]; then
      AAC_IMPL=$(menu_radiolist \
        "Pick an AAC encoder" "$AAC_IMPL_DEFAULT_BUILTIN" \
        native   "FFmpeg native AAC (always available)" \
        fdk_aac  "Fraunhofer FDK-AAC (requires --enable-nonfree)") || die "AAC prompt cancelled"
    fi
    if [ "$ENABLE_GPL" = true ]; then
      if [ -z "$H264_IMPL" ]; then
        H264_IMPL=$(menu_radiolist \
          "Pick an H.264 encoder" "$H264_IMPL_DEFAULT_BUILTIN" \
          x264     "x264 — GPL, de-facto standard" \
          openh264 "OpenH264 — BSD source, MPEG-LA royalties apply") || die "H.264 prompt cancelled"
      fi
      if [ -z "$H265_IMPL" ]; then
        H265_IMPL=$(menu_radiolist \
          "Pick an H.265 encoder" "$H265_IMPL_DEFAULT_BUILTIN" \
          x265    "x265 — GPL" \
          kvazaar "Kvazaar — LGPL") || die "H.265 prompt cancelled"
      fi
    fi
    if [ -z "$AV1_ENC_IMPL" ]; then
      AV1_ENC_IMPL=$(menu_radiolist \
        "Pick an AV1 encoder" "$AV1_ENC_IMPL_DEFAULT_BUILTIN" \
        svtav1 "SVT-AV1 — fastest, recommended" \
        rav1e  "rav1e — pure Rust" \
        av1    "libaom — reference encoder, slow") || die "AV1 prompt cancelled"
    fi
    if [ -z "$SPIRV_IMPL" ]; then
      SPIRV_IMPL=$(menu_radiolist \
        "Pick a SPIR-V compiler" "$SPIRV_IMPL_DEFAULT_BUILTIN" \
        glslang "glslang — Khronos reference (default, simpler build)" \
        shaderc "shaderc — Google wrapper (heavier build)") || die "SPIRV prompt cancelled"
    fi
  fi

  # --enable-nonfree implies fdk_aac unless the user explicitly picked an AAC
  # encoder THIS run (--aac= or --menu, captured in _aac_cli before stored
  # choices backfilled AAC_IMPL). This lets nonfree beat a stale stored 'native'
  # from a prior free build, while an explicit --aac=native this run still wins.
  if [ "$ENABLE_NONFREE" = true ] && [ -z "${_aac_cli:-}" ]; then
    AAC_IMPL="fdk_aac"
  fi

  # Apply profile *_DEFAULT then built-in defaults if nothing set them.
  : "${TLS_BACKEND:=${TLS_BACKEND_DEFAULT:-$TLS_BACKEND_DEFAULT_BUILTIN}}"
  : "${AAC_IMPL:=${AAC_IMPL_DEFAULT:-$AAC_IMPL_DEFAULT_BUILTIN}}"
  : "${H264_IMPL:=${H264_IMPL_DEFAULT:-$H264_IMPL_DEFAULT_BUILTIN}}"
  : "${H265_IMPL:=${H265_IMPL_DEFAULT:-$H265_IMPL_DEFAULT_BUILTIN}}"
  : "${AV1_ENC_IMPL:=${AV1_ENC_IMPL_DEFAULT:-$AV1_ENC_IMPL_DEFAULT_BUILTIN}}"
  : "${SPIRV_IMPL:=${SPIRV_IMPL_DEFAULT:-$SPIRV_IMPL_DEFAULT_BUILTIN}}"

  _validate_enum "--tls"     "$TLS_BACKEND"  "openssl|gnutls|mbedtls|libressl|none"
  _validate_enum "--aac"     "$AAC_IMPL"     "fdk_aac|native"
  _validate_enum "--h264"    "$H264_IMPL"    "x264|openh264"
  _validate_enum "--h265"    "$H265_IMPL"    "x265|kvazaar"
  _validate_enum "--av1-enc" "$AV1_ENC_IMPL" "svtav1|rav1e|av1"
  _validate_enum "--spirv"   "$SPIRV_IMPL"   "glslang|shaderc"
  _validate_enum "--flite-audio" "$FLITE_AUDIO" "none|alsa|pulseaudio|oss|sun"

  # Compiled into libtls as TLS_DEFAULT_CA_FILE (tls/Makefile.am:53) and into
  # libcrypto as X509_CERT_FILE, so a relative value would be resolved against
  # the working directory of whatever process links it — the arm would silently
  # trust nothing rather than fail loudly.
  #
  # Validated BEFORE the staleness warning below: warning first would quote an
  # invalid value back at the user and then die on it anyway.
  _validate_openssldir "--openssldir" "$OPENSSLDIR" \
    "It is compiled into the TLS library as its default trust store."

  # Only the two arms that bake an openssldir; the stamps this names exist for
  # no other arm.
  case "$TLS_BACKEND" in
    openssl|libressl)
      openssldir_warn_if_changed "${STORED_OPENSSLDIR:-}" "$OPENSSLDIR" ;;
  esac

  # TLS: disable companions of the chosen backend
  for _p in $(tls_disable_companions "$TLS_BACKEND"); do
    DISABLE_PKGS="$DISABLE_PKGS $_p"
  done

  # AAC: only fdk_aac is a mutex member; native means "skip fdk_aac"
  case "$AAC_IMPL" in
    native) DISABLE_PKGS="$DISABLE_PKGS fdk_aac" ;;
  esac

  # H264 / H265 / AV1-enc: disable every member of the group except the chosen one
  for _g_var in H264_GROUP H265_GROUP AV1_ENC_GROUP SPIRV_GROUP; do
    eval "_members=\$$_g_var"
    eval "_chosen=\$${_g_var%_GROUP}_IMPL"
    for _m in $_members; do
      [ "$_m" = "$_chosen" ] && continue
      DISABLE_PKGS="$DISABLE_PKGS $_m"
    done
  done

  # Detect contradictions: --tls=X --disable=X
  for _chosen in "$TLS_BACKEND" "$AAC_IMPL" "$H264_IMPL" "$H265_IMPL" "$AV1_ENC_IMPL" "$SPIRV_IMPL"; do
    case "$_chosen" in
      none|native) continue ;;
    esac
    for _d in ${DISABLE_PKGS_INPUT:-}; do
      if [ "$_d" = "$_chosen" ]; then
        die "Contradiction: '$_chosen' is both selected via per-group flag and listed in --disable="
      fi
    done
  done
}

# Load previously-stored choices, if present. Stored values are applied
# *under* CLI flags (i.e. CLI overrides storage).
# _stored_choice FILE NAME
# Print the value of the STORED_* assignment called NAME in FILE, stripping the
# single quotes save_stored_choices wraps STORED_OPENSSLDIR in.
#
# Parsed, never sourced. $PREFIX is the workspace every dependency's
# `make install` writes into, so anything that can compromise a build can also
# leave shell in this file for the NEXT one to execute -- including settings no
# caller ever asked about, such as MAKESUM_MODE=true, which turns verification
# into digest recording with the sidecars rewritten from whatever is fetched.
# Asking for values by name means a setting we did not ask for cannot arrive at
# all, which is a smaller thing to get right than enumerating what to reject.
# lib/install.sh reads the same file the same way.
_stored_choice() {
  awk -v k="$2" -v q="'" '
    {
      eq = index($0, "=")
      if (eq == 0) next
      if (substr($0, 1, eq - 1) != k) next
      v = substr($0, eq + 1)
      if (length(v) > 1 && substr(v, 1, 1) == q && substr(v, length(v), 1) == q) {
        v = substr(v, 2, length(v) - 2)
      }
      print v
      exit
    }
  ' "$1"
}

load_stored_choices() {
  [ "${USE_MENU:-false}" = true ] && return 0
  [ "${DRY_RUN:-false}" = true ] && return 0
  _file="$PREFIX/.mediaforge-choices"
  [ -f "$_file" ] || return 0
  : "${TLS_BACKEND:=$(_stored_choice "$_file" STORED_TLS_BACKEND)}"
  : "${AAC_IMPL:=$(_stored_choice "$_file" STORED_AAC_IMPL)}"
  : "${H264_IMPL:=$(_stored_choice "$_file" STORED_H264_IMPL)}"
  : "${H265_IMPL:=$(_stored_choice "$_file" STORED_H265_IMPL)}"
  : "${AV1_ENC_IMPL:=$(_stored_choice "$_file" STORED_AV1_ENC_IMPL)}"
  : "${SPIRV_IMPL:=$(_stored_choice "$_file" STORED_SPIRV_IMPL)}"
  # Kept in its own variable as well as backfilled, because resolve_choices
  # needs the PREVIOUS value even when the current one came from the CLI --
  # that is the entire case openssldir_warn_if_changed exists for. This used to
  # arrive as a side effect of sourcing the file; nothing assigned it once the
  # by-name parser replaced the source, and the warning went silently dead
  # while its own unit tests, which call it directly, stayed green.
  STORED_OPENSSLDIR=$(_stored_choice "$_file" STORED_OPENSSLDIR)
  : "${OPENSSLDIR:=$STORED_OPENSSLDIR}"
}

# Save resolved choices for next run.
save_stored_choices() {
  [ "${DRY_RUN:-false}" = true ] && return 0
  _file="$PREFIX/.mediaforge-choices"
  mkdir -p "$PREFIX" 2>/dev/null || return 0
  cat >"$_file" <<EOF
# Generated by mediaforge — edit at your own risk; --clean-choices removes this file.
STORED_TLS_BACKEND=$TLS_BACKEND
STORED_AAC_IMPL=$AAC_IMPL
STORED_H264_IMPL=$H264_IMPL
STORED_H265_IMPL=$H265_IMPL
STORED_AV1_ENC_IMPL=$AV1_ENC_IMPL
STORED_SPIRV_IMPL=$SPIRV_IMPL
STORED_OPENSSLDIR='$OPENSSLDIR'
EOF
}

# Four-screen interactive menu. Sets ENABLE_GPL, ENABLE_NONFREE,
# the per-group choices, and adds to DISABLE_PKGS. Called from cmd_build
# before resolve_choices when --menu is passed.
run_menu() {
  if ! is_interactive; then
    die "--menu requires an interactive terminal"
  fi
  if [ "${AUTOINSTALL:-}" = "yes" ]; then
    die "--menu and --yes are mutually exclusive"
  fi

  # Screen 1 — licence tier
  _tier=$(menu_radiolist "Licence tier" "free" \
    free    "Free codecs only" \
    gpl     "GPL codecs (x264, x265, xvidcore, vid_stab)" \
    nonfree "GPL + non-free (fdk_aac, srt over openssl)") || die "Menu cancelled"
  case "$_tier" in
    free)    ENABLE_GPL=false; ENABLE_NONFREE=false ;;
    gpl)     ENABLE_GPL=true;  ENABLE_NONFREE=false ;;
    nonfree) ENABLE_GPL=true;  ENABLE_NONFREE=true ;;
  esac

  # Screen 2 — build options
  _opts=$(menu_checklist "Build options" \
    static  "Full static binary (Linux only)" off \
    small   "Minimal build" off \
    lv2     "LV2 audio plugin chain" on \
    rebuild "Rebuild outdated dependencies" off) || die "Menu cancelled"
  for _o in $_opts; do
    case "$_o" in
      static)  _enable_static=true ;;
      small)   _enable_small=true ;;
      lv2)     ;;
      rebuild) REBUILD_OUTDATED=true ;;
    esac
  done
  case " $_opts " in
    *" lv2 "*) ;;
    *) DISABLE_PKGS="$DISABLE_PKGS lv2" ;;
  esac

  # Screen 3 — mutex group picks
  TLS_BACKEND=$(menu_radiolist "TLS backend" "${TLS_BACKEND:-gnutls}" \
    gnutls   "GnuTLS"   \
    openssl  "OpenSSL"  \
    mbedtls  "mbedTLS"  \
    libressl "LibreSSL" \
    none     "No TLS")  || die "Menu cancelled"
  AAC_IMPL=$(menu_radiolist "AAC encoder" "${AAC_IMPL:-native}" \
    native   "FFmpeg native"      \
    fdk_aac  "FDK-AAC (nonfree)") || die "Menu cancelled"
  if [ "$ENABLE_GPL" = true ]; then
    H264_IMPL=$(menu_radiolist "H.264 encoder" "${H264_IMPL:-x264}" \
      x264     "x264 (GPL)" \
      openh264 "OpenH264 (BSD source)") || die "Menu cancelled"
    H265_IMPL=$(menu_radiolist "H.265 encoder" "${H265_IMPL:-x265}" \
      x265    "x265 (GPL)" \
      kvazaar "Kvazaar (LGPL)") || die "Menu cancelled"
  fi
  AV1_ENC_IMPL=$(menu_radiolist "AV1 encoder" "${AV1_ENC_IMPL:-svtav1}" \
    svtav1 "SVT-AV1" \
    rav1e  "rav1e"   \
    av1    "libaom (slow reference)") || die "Menu cancelled"
  SPIRV_IMPL=$(menu_radiolist "SPIR-V compiler" "${SPIRV_IMPL:-glslang}" \
    glslang "glslang (reference)" \
    shaderc "shaderc (Google)") || die "Menu cancelled"
}
