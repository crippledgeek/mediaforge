#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
FFMPEG_VERSION=7.1
# SCRIPT_DIR is how lib/utils.sh locates its own dependency (lib/stage.sh, GH-59).
# mediaforge.sh sets it from $0; a test that sources the library directly has to
# supply it, and $ROOT is the same directory by construction.
SCRIPT_DIR="$ROOT"
# shellcheck source=lib/utils.sh
. lib/utils.sh
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

_t() { # assertion-name  expect(0|1)  min
  if ffmpeg_version_ge "$3"; then _got=0; else _got=1; fi
  if [ "$_got" = "$2" ]; then _pass "$1"; else _bad "$1" "got=$_got want=$2"; fi
}
FFMPEG_VERSION=7.1;   _t version-7.1-meets-7.1     0 7.1
FFMPEG_VERSION=7.1;   _t version-7.1-below-8.0     1 8.0
FFMPEG_VERSION=7.0;   _t version-7.0-below-7.1     1 7.1
FFMPEG_VERSION=8.0.1; _t version-8.0.1-meets-8.0   0 8.0
FFMPEG_VERSION=6.1;   _t version-6.1-below-7.0     1 7.0
FFMPEG_VERSION=8.0.1; _t version-8.0.1-meets-7.1   0 7.1
FFMPEG_VERSION=7.1;   _t version-7.1-below-7.1.1   1 7.1.1
exit "$_fail"
