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

# 1) No source emits the invalid FFmpeg flag.
if grep -rn -- '--enable-libflac' recipes/ lib/ mediaforge.sh >/dev/null 2>&1; then
  echo "FAIL: '--enable-libflac' still referenced in source:"
  grep -rn -- '--enable-libflac' recipes/ lib/ mediaforge.sh | sed 's/^/    /'
  _fail=1
else
  echo "PASS: no source references --enable-libflac"
fi

# 2) The flac recipe is gone.
if [ -f recipes/audio/flac.sh ]; then
  echo "FAIL: recipes/audio/flac.sh still present"
  _fail=1
else
  echo "PASS: recipes/audio/flac.sh removed"
fi

# 3) The --flac selector is rejected as an unknown option (fast: dies before build).
_out=$(./mediaforge.sh build --flac=native 2>&1)
if printf '%s\n' "$_out" | grep -qi 'unknown option'; then
  echo "PASS: --flac is rejected as an unknown option"
else
  echo "FAIL: --flac was accepted (selector not fully removed)"
  _fail=1
fi

exit "$_fail"
