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
sh tests/libressl-pin-asm.sh
sh tests/libressl-trust-store.sh
sh tests/git-commit-pinning.sh
sh tests/install-containment.sh
sh tests/install-privileged-execs.sh
sh tests/checksum-verification.sh
# Prose hygiene, not behaviour: a comment citing an in-tree file by LINE is
# correct only until the next edit above it, and nothing else in this suite
# reads a comment. It found fifteen such citations on the branch that added it,
# two of them already stale.
sh tests/comment-citations.sh
sh tests/recipe-identity.sh
# Pins .githooks/pre-push, which runs tests/shellcheck.sh -- and only that -- at
# push time. Asserts it forwards the gate's verdict both ways, demands a real
# linter rather than sh -n alone, and lets a branch deletion through. A hook that
# exited 0 regardless would leave the tree looking guarded when it is not, and
# nothing else here would notice.
sh tests/pre-push-hook.sh
# Pins the sidecar provenance convention (#36): a comment claiming "<algo> from
# <URL>" must head a block that actually records that algo, and the extra
# upstream digests must be CHECKED rather than inert. Nothing else in the suite
# reads a provenance comment, so an overclaiming one is otherwise invisible.
sh tests/upstream-provenance.sh
# Runs the unmerged test files against the merge base and fails if any assertion
# passes there. Catches the oracle that drifted into matching an error message,
# and the fixture whose path collided with the value it was distinguishing —
# both real, both green under shellcheck and the suite.
sh tests/oracle-baseline.sh

printf 'All tests passed.\n'
