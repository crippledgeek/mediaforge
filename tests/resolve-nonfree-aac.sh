#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
PREFIX="$ROOT/workspace"
AUTOINSTALL=yes   # is_interactive() -> false, so resolve_choices skips prompts
DRY_RUN=false
# SCRIPT_DIR is how lib/utils.sh locates its own dependency (lib/stage.sh, GH-59).
# mediaforge.sh sets it from $0; a test that sources the library directly has to
# supply it, and $ROOT is the same directory by construction.
SCRIPT_DIR="$ROOT"
# shellcheck source=lib/utils.sh
. lib/utils.sh
# shellcheck source=lib/menu.sh
. lib/menu.sh
# shellcheck source=lib/resolve.sh
. lib/resolve.sh
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

_reset() {  # valid values for the other groups so _validate_enum passes
  TLS_BACKEND=gnutls; H264_IMPL=x264; H265_IMPL=x265
  AV1_ENC_IMPL=svtav1; SPIRV_IMPL=glslang; FLITE_AUDIO=none
  DISABLE_PKGS=""; DISABLE_PKGS_INPUT=""
}

_expect() {  # _expect <assertion-name> <expected> <actual>
  if [ "$3" = "$2" ]; then
    _pass "$1"
  else
    _bad "$1" "expected=$2 got=$3"
  fi
}

# Case 1 (the bug): --enable-nonfree, stored 'native' loaded, no this-run --aac
#   → fdk_aac must win.
_reset; ENABLE_GPL=true; ENABLE_NONFREE=true; _aac_cli=""; AAC_IMPL="native"
resolve_choices
_expect nonfree-beats-stored-native fdk_aac "$AAC_IMPL"

# Case 2: --enable-nonfree + explicit --aac=native THIS run → native respected
_reset; ENABLE_GPL=true; ENABLE_NONFREE=true; _aac_cli="native"; AAC_IMPL="native"
resolve_choices
_expect explicit-aac-native-wins-under-nonfree native "$AAC_IMPL"

# Case 3: free build, nothing set → native default (unchanged behavior)
_reset; ENABLE_GPL=false; ENABLE_NONFREE=false; _aac_cli=""; AAC_IMPL=""
resolve_choices
_expect free-build-defaults-to-native native "$AAC_IMPL"

# Case 4: --enable-nonfree + explicit --aac=fdk_aac → fdk_aac (sanity)
_reset; ENABLE_GPL=true; ENABLE_NONFREE=true; _aac_cli="fdk_aac"; AAC_IMPL="fdk_aac"
resolve_choices
_expect explicit-aac-fdk-is-respected fdk_aac "$AAC_IMPL"

exit "$_fail"
