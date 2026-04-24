#!/bin/sh
# Top-level test runner. Sequential — each script exits non-zero on failure.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

sh tests/shellcheck.sh
sh tests/negative.sh
sh tests/dry-run-matrix.sh

printf 'All tests passed.\n'
