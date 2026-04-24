#!/bin/sh
# Lints every shell file under the repo with `sh -n` and (when available) `shellcheck -s sh`.
# Exit non-zero on first failure unless KEEP_GOING=1.

set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

_fail=0
_files=$(find mediaforge.sh lib recipes tests -type f -name '*.sh')

for f in $_files; do
  if ! sh -n "$f"; then
    printf 'sh -n FAILED: %s\n' "$f" >&2
    _fail=1
    [ "${KEEP_GOING:-0}" = "1" ] || exit 1
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  for f in $_files; do
    if ! shellcheck -s sh -e SC1090,SC1091,SC2034 "$f"; then
      printf 'shellcheck FAILED: %s\n' "$f" >&2
      _fail=1
      [ "${KEEP_GOING:-0}" = "1" ] || exit 1
    fi
  done
else
  printf 'shellcheck not installed — skipping\n' >&2
fi

exit "$_fail"
