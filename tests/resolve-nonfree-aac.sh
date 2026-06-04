#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
PREFIX="$ROOT/workspace"
AUTOINSTALL=yes   # is_interactive() -> false, so resolve_choices skips prompts
DRY_RUN=false
# shellcheck disable=SC1091
. lib/utils.sh
. lib/menu.sh
. lib/resolve.sh
_fail=0

_reset() {  # valid values for the other groups so _validate_enum passes
  TLS_BACKEND=gnutls; FLAC_IMPL=native; H264_IMPL=x264; H265_IMPL=x265
  AV1_ENC_IMPL=svtav1; SPIRV_IMPL=glslang; DISABLE_PKGS=""; DISABLE_PKGS_INPUT=""
}

_expect() {  # _expect <label> <expected> <actual>
  if [ "$3" = "$2" ]; then
    printf 'PASS [%s]\n' "$1"
  else
    printf 'FAIL [%s] expected=%s got=%s\n' "$1" "$2" "$3" >&2
    _fail=1
  fi
}

# Case 1 (the bug): --enable-nonfree, stored 'native' loaded, no this-run --aac
#   → fdk_aac must win.
_reset; ENABLE_GPL=true; ENABLE_NONFREE=true; _aac_cli=""; AAC_IMPL="native"
resolve_choices
_expect "nonfree beats stored native" fdk_aac "$AAC_IMPL"

# Case 2: --enable-nonfree + explicit --aac=native THIS run → native respected
_reset; ENABLE_GPL=true; ENABLE_NONFREE=true; _aac_cli="native"; AAC_IMPL="native"
resolve_choices
_expect "explicit --aac=native wins under nonfree" native "$AAC_IMPL"

# Case 3: free build, nothing set → native default (unchanged behavior)
_reset; ENABLE_GPL=false; ENABLE_NONFREE=false; _aac_cli=""; AAC_IMPL=""
resolve_choices
_expect "free build defaults native" native "$AAC_IMPL"

# Case 4: --enable-nonfree + explicit --aac=fdk_aac → fdk_aac (sanity)
_reset; ENABLE_GPL=true; ENABLE_NONFREE=true; _aac_cli="fdk_aac"; AAC_IMPL="fdk_aac"
resolve_choices
_expect "explicit fdk_aac" fdk_aac "$AAC_IMPL"

exit "$_fail"
