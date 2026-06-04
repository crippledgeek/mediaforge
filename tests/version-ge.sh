#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
# shellcheck disable=SC1091
FFMPEG_VERSION=7.1
. lib/utils.sh
_fail=0
_t() { # desc  expect(0|1)  min
  if ffmpeg_version_ge "$3"; then _got=0; else _got=1; fi
  if [ "$_got" = "$2" ]; then printf 'PASS [%s]\n' "$1"; else printf 'FAIL [%s] got=%s want=%s\n' "$1" "$_got" "$2" >&2; _fail=1; fi
}
FFMPEG_VERSION=7.1;   _t "7.1>=7.1"   0 7.1
FFMPEG_VERSION=7.1;   _t "7.1>=8.0"   1 8.0
FFMPEG_VERSION=7.0;   _t "7.0>=7.1"   1 7.1
FFMPEG_VERSION=8.0.1; _t "8.0.1>=8.0" 0 8.0
FFMPEG_VERSION=6.1;   _t "6.1>=7.0"   1 7.0
FFMPEG_VERSION=8.0.1; _t "8.0.1>=7.1" 0 7.1
FFMPEG_VERSION=7.1;   _t "7.1>=7.1.1" 1 7.1.1
exit "$_fail"
