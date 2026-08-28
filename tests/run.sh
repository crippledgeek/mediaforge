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
# Pins #15: install reconciles against the previous manifest instead of
# overwriting it, so a file an older build shipped and this one does not is
# removed rather than orphaned. Nothing else in the suite runs install TWICE,
# which is the only way the defect is reachable.
sh tests/install-manifest-reconcile.sh
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
# Pins that the agent-artifact ignore patterns actually BITE. .gitignore fails
# silently: a pattern that matches nothing is indistinguishable in `git status`
# from one that works, and the artifact just shows up untracked and committable.
# graphify-out/ was missing while every sibling was present, which is what this
# was written for. Asks git, not the file's text, so an inert pattern is a miss.
sh tests/gitignore-artifacts.sh
# Pins the sidecar provenance convention (#36): a comment claiming "<algo> from
# <URL>" must head a block that actually records that algo, and the extra
# upstream digests must be CHECKED rather than inert. Nothing else in the suite
# reads a provenance comment, so an overclaiming one is otherwise invisible.
sh tests/upstream-provenance.sh
# Pins the committed signing keys (#40): a `# with key <fpr>` line must have the
# matching keys/<fpr>.asc, a committed key must be cited by some block, and each
# INDEX row must state what the committed bytes themselves say. The pin alone
# records only WHICH key signed; expiry and revocation are self-signatures the
# holder can change afterwards, so without the material a recorded verdict can
# flip with no commit touching this tree.
sh tests/signing-keys.sh
# Pins the sidecar comment grammar (#45): overriding HASH_COMMENT_RE must change
# what hash_file_validate and hash_lookup do. Asserted by mutation rather than by
# grep, because the claim is that the parsers READ the shared definition -- a
# second copy spelled differently would satisfy a grep and still be a second
# copy. Nothing else in the suite would notice one.
sh tests/hash-comment-grammar.sh
# Pins the shared reporters themselves (#46): tests/lib-assert.sh is the one
# file every other test's verdict passes through, and a defect in it does not
# fail a test — it changes what a passing test PRINTS, which is exactly what
# oracle-baseline below counts. Nothing else asserts on that output.
sh tests/assert-reporter.sh
# Runs the unmerged test files against the merge base and fails if any assertion
# passes there. Catches the oracle that drifted into matching an error message,
# and the fixture whose path collided with the value it was distinguishing —
# both real, both green under shellcheck and the suite.
sh tests/oracle-baseline.sh

printf 'All tests passed.\n'
