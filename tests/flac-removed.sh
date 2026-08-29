#!/bin/sh
# Regression guard: the bogus `--flac=libflac` selector is gone.
#
# FFmpeg's FLAC encode/decode is native — there is no `--enable-libflac`
# configure option and nothing in FFmpeg consumes external libFLAC. The old
# flac.sh recipe emitted `--enable-libflac`, which FFmpeg rejects
# ("Unknown option"), breaking every build that resolved FLAC to libflac.
# This test ensures no code path can emit that flag and that the `--flac`
# selector no longer exists.
set -u

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
_root=$(CDPATH='' cd -- "$_here/.." && pwd)
cd "$_root" || exit 1

_fail=0
# shellcheck source=tests/lib-assert.sh
. "$_root/tests/lib-assert.sh"
# shellcheck source=tests/lib-scratch.sh
. "$_root/tests/lib-scratch.sh"
_scratch_init "$_root"
trap '_scratch_cleanup' EXIT
_cleanup_on_signal

# 1) No source emits the invalid FFmpeg flag.
if grep -rn -- '--enable-libflac' recipes/ lib/ mediaforge.sh >/dev/null 2>&1; then
  _bad no-source-emits-enable-libflac \
    "still referenced: $(grep -rn -- '--enable-libflac' recipes/ lib/ mediaforge.sh)"
else
  _pass no-source-emits-enable-libflac
fi

# 2) The flac recipe is gone.
if [ -f recipes/audio/flac.sh ]; then
  _bad flac-recipe-removed "recipes/audio/flac.sh is still present"
else
  _pass flac-recipe-removed
fi

# 3) The --flac selector is rejected as an unknown option (fast: dies before build).
_out=$(_mf build --flac=native 2>&1)
if printf '%s\n' "$_out" | grep -qi 'unknown option'; then
  _pass flac-selector-rejected-as-unknown
else
  _bad flac-selector-rejected-as-unknown "--flac was accepted; the selector is not fully removed"
fi

exit "$_fail"
