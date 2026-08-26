#!/bin/sh
# The pre-push hook actually blocks a push, and the gate actually covers it.
#
# WHAT THIS PINS. tests/shellcheck.sh was runnable but not run: nothing invoked
# it, so a regression reached the remote and was found later by hand. The hook
# closes that, and it introduces two failure modes of its own that are silent
# in exactly the same way:
#
#   * a hook that exits 0 regardless -- a push proceeds over a red gate and the
#     tree looks guarded when it is not;
#   * a hook nothing lints -- .githooks/* carry no extension because git
#     requires exact hook names, so the *.sh glob in the gate could not see the
#     one file whose syntax error would block every push.
#
# NOT ASSERTED, deliberately: that the hook exits 0 on a clean tree. That path
# runs the whole gate (~19s), tests/run.sh runs the same gate as its first step
# anyway, and tests/oracle-baseline.sh executes this file twice more -- so the
# assertion would cost about a minute to re-prove what the suite already
# proves. The hook's invocation of the gate is pinned by the blocking assertion
# below, which fails fast.
#
# Usage: tests/pre-push-hook.sh
# Exit 0 = pass, 1 = regression.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT" || exit 1
_fail=0

_pass() { printf 'PASS [%s]\n' "$1"; }
_bad()  { printf 'FAIL [%s] %s\n' "$1" "${2-}" >&2; _fail=1; }

HOOK=.githooks/pre-push
ZERO=0000000000000000000000000000000000000000
LIVE=1111111111111111111111111111111111111111

# Both fixtures are removed on every exit path, including an interrupt: they are
# deliberately broken shell files inside the tree, and one left behind would
# fail the gate for every later run and be attributed to whatever ran next.
BAD_TEST=tests/.pre-push-fixture-broken.sh
BAD_HOOK=.githooks/.pre-push-fixture-broken
trap 'rm -f "$BAD_TEST" "$BAD_HOOK"' EXIT INT TERM
_plant() { printf '#!/bin/sh\nif [ -z "" ; then\n' > "$1"; }

# ── the hook is there, and is a shell file the kernel will run ──────────────
if [ -f "$HOOK" ] && [ -x "$HOOK" ]; then
  _pass hook-present-and-executable
else
  _bad hook-present-and-executable "$HOOK is missing or not executable"
fi

if sh -n "$HOOK" 2>/dev/null; then
  _pass hook-is-posix-sh
else
  _bad hook-is-posix-sh "$HOOK does not parse under sh -n"
fi

# ── a deletion-only push is let through ─────────────────────────────────────
# Deleting a merged remote branch is required by the branch policy and ships no
# content, so a lint failure that predates the deletion must not obstruct it.
# This is also the cheap positive: it proves the hook runs and exits 0 without
# paying for the gate.
if [ -x "$HOOK" ]; then
  _delout=$(printf 'refs/heads/x %s refs/heads/x %s\n' "$ZERO" "$LIVE" | "$HOOK" 2>&1)
  _delrc=$?
  # Both halves matter: exit 0 alone would also be produced by a hook that
  # ignores its input and blesses everything, which is the failure mode this
  # file exists to catch. The message proves the deletion branch is what ran.
  if [ "$_delrc" -eq 0 ] && printf '%s' "$_delout" | grep -qF 'deletion-only push'; then
    _pass hook-skips-deletion-only-push
  else
    _bad hook-skips-deletion-only-push "rc=$_delrc output=[$_delout]"
  fi
else
  _bad hook-skips-deletion-only-push "$HOOK is not executable"
fi

# ── a content push over a failing gate is REFUSED ───────────────────────────
if [ -x "$HOOK" ]; then
  _plant "$BAD_TEST"
  _blockout=$(printf 'refs/heads/x %s refs/heads/x %s\n' "$LIVE" "$LIVE" | "$HOOK" 2>&1)
  _blockrc=$?
  rm -f "$BAD_TEST"
  # Matched on the fixture's own path, not merely on a non-zero status: the
  # hook must have refused BECAUSE of this file. A tree that was already red
  # for an unrelated reason exits the gate at that file instead, and this
  # reports rather than passing for the wrong reason.
  if [ "$_blockrc" -ne 0 ] && printf '%s' "$_blockout" | grep -qF "$BAD_TEST"; then
    _pass hook-blocks-push-when-lint-fails
  else
    _bad hook-blocks-push-when-lint-fails "rc=$_blockrc output=[$_blockout]"
  fi
else
  _bad hook-blocks-push-when-lint-fails "$HOOK is not executable"
fi

# ── the gate lints the hook directory itself ────────────────────────────────
# Run against tests/shellcheck.sh directly rather than through the hook: the
# claim here is about the gate's file list, and routing it through the hook
# would leave a passing result ambiguous between the two.
_plant "$BAD_HOOK"
_covout=$(sh tests/shellcheck.sh 2>&1)
_covrc=$?
rm -f "$BAD_HOOK"
if [ "$_covrc" -ne 0 ] && printf '%s' "$_covout" | grep -qF "$BAD_HOOK"; then
  _pass lint-gate-covers-githooks
else
  _bad lint-gate-covers-githooks "gate did not flag a broken file in .githooks; rc=$_covrc"
fi

printf 'DONE:\n'
exit "$_fail"
