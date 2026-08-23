#!/bin/sh
# Top-level test runner. Sequential — each script exits non-zero on failure.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

sh tests/shellcheck.sh
sh tests/version-ge.sh
sh tests/negative.sh
sh tests/dry-run-matrix.sh
sh tests/resolve-nonfree-aac.sh
sh tests/flac-removed.sh
sh tests/menu-stdin.sh
sh tests/fetch-fail-no-cache.sh
# Was never wired in, which is why dry-run-matrix.sh's contradicting lcevc row
# went unnoticed: the accurate test did not run and the inaccurate one did.
# Dry-run only, so it needs no built workspace — unlike lcevc-static-link.sh,
# oapv-static-link.sh, no-nested-archives.sh and avs2-reorder-dts.sh, which
# assert against $PREFIX and stay manual.
sh tests/lcevc-default-off.sh

printf 'All tests passed.\n'
