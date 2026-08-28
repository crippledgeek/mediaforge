#!/bin/sh
# The pre-push hook actually blocks a push, and the gate actually covers it.
#
# WHAT THIS PINS. tests/shellcheck.sh was runnable and wired into tests/run.sh,
# but nothing ran either at push time -- so it depended on a contributor
# remembering, and findings accumulated unseen until 81c17a0 fixed them in bulk.
# The hook closes that, and introduces three failure modes of its own that are
# silent in exactly the same way:
#
#   * a hook that exits 0 whatever the gate said -- a push proceeds over a red
#     gate and the tree looks guarded when it is not;
#   * a hook nothing lints -- .githooks/* carry no extension because git
#     requires exact hook names, so the -name '*.sh' filter in the gate could
#     not see the one file whose syntax error would block every push;
#   * a gate that reports a pass having run only sh -n, because shellcheck was
#     absent -- the findings it exists to catch are the ones sh -n cannot see.
#
# The hook's own decision is exercised against a THROWAWAY REPO with a stub
# gate, not against this one. That isolates "what the hook does with the gate's
# verdict" from "what the gate decides", makes the pass-through path affordable
# (~20ms rather than a full gate run), and keeps the deliberately-broken
# fixtures out of the shared tree for every assertion that does not need them.
#
# Usage: tests/pre-push-hook.sh
# Exit 0 = pass, 1 = regression.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT" || exit 1
_fail=0

# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

HOOK=.githooks/pre-push
ZERO=0000000000000000000000000000000000000000
LIVE=1111111111111111111111111111111111111111

# The two fixtures that must live in the real tree, because their assertions are
# about the real gate's real file list. Removed on every exit path including an
# interrupt: a deliberately broken shell file left behind fails the gate for
# every later run, and gets attributed to whatever ran next. They are also
# gitignored, for the signal a trap cannot catch.
BAD_SYNTAX=.githooks/.pre-push-fixture-syntax
BAD_LINT=.githooks/.pre-push-fixture-lint
_stubs=""
# Deferred expansion, deliberately: $_stubs accumulates temp dirs as the file
# runs, so the trap must read it when it FIRES, not when it is installed. That
# is also why _stub_repo assigns STUB_DIR in this shell -- an assignment inside
# $( ) lands in a subshell, the parent's $_stubs stays empty, and the trap
# cleans nothing while every assertion still passes.
trap 'rm -rf "$BAD_SYNTAX" "$BAD_LINT" $_stubs' EXIT INT TERM

# Both fixtures must be EXECUTABLE or the gate will not look at them: it filters
# .githooks by the bit git itself uses to decide what is a hook.
_plant() { printf '%s' "$2" > "$1" && chmod +x "$1"; }
SYNTAX_ERR='#!/bin/sh
if [ -z "" ; then
'
# Parses cleanly, so sh -n passes it and only shellcheck objects (SC2164, an
# unchecked cd). Without this the coverage claim would rest on the sh -n loop
# alone -- which aborts the gate before the shellcheck loop ever runs.
LINT_ERR='#!/bin/sh
cd /tmp
'

# The stub gates. GATE_REQ carries a ${...} that is the stub's own source and
# must survive into the file rather than expand here -- which is
# indistinguishable, to a linter, from the mistake of single-quoting an
# expansion you meant to interpolate. A quoted heredoc says it unambiguously;
# the other two follow the same form for consistency, not necessity.
GATE_OK=$(cat <<'EOF'
#!/bin/sh
exit 0
EOF
)
GATE_FAIL=$(cat <<'EOF'
#!/bin/sh
exit 1
EOF
)
GATE_REQ=$(cat <<'EOF'
#!/bin/sh
[ "${REQUIRE_SHELLCHECK:-0}" = "1" ] || exit 1
exit 0
EOF
)

# Builds a throwaway git repo whose tests/shellcheck.sh is $1, with the real
# hook copied in, and leaves its path in STUB_DIR for the caller to run from.
# STUB_DIR rather than stdout: a caller writing _d=$(_stub_repo ...) would run
# this whole body in a subshell, so the temp dir would never reach $_stubs and
# every run would leak one.
_stub_repo() {
  STUB_DIR=$(mktemp -d) || return 1
  _stubs="$_stubs $STUB_DIR"
  mkdir -p "$STUB_DIR/tests" || return 1
  printf '%s' "$1" > "$STUB_DIR/tests/shellcheck.sh" || return 1
  git init -q "$STUB_DIR" >/dev/null 2>&1 || return 1
  cp "$ROOT/$HOOK" "$STUB_DIR/pre-push" || return 1
  chmod +x "$STUB_DIR/pre-push" || return 1
}

# Builds a minimal tree around a COPY of the real gate: one trivial clean file
# under each root the gate walks EXCEPT .githooks, plus the two entry points it
# checks the mode of. .githooks is absent on purpose -- the coverage assertions
# below make that claim against the real tree, where it means something.
# The three assertions that follow ask whether the gate HONOURS its environment
# -- SHELLCHECK, REQUIRE_SHELLCHECK, the identity check -- which is a question
# about control flow, not about which files exist. Answering it over the real
# corpus costs a full lint per invocation, and three of them dominated this
# file's cost on the merge base. Same reasoning as the stub repo above, same
# $_stubs cleanup.
_min_tree() {
  MIN_DIR=$(mktemp -d) || return 1
  _stubs="$_stubs $MIN_DIR"
  mkdir -p "$MIN_DIR/lib" "$MIN_DIR/recipes" "$MIN_DIR/tests" || return 1
  for _f in mediaforge.sh lib/probe.sh recipes/probe.sh tests/probe.sh; do
    printf '#!/bin/sh\nexit 0\n' > "$MIN_DIR/$_f" || return 1
  done
  cp "$ROOT/tests/shellcheck.sh" "$MIN_DIR/tests/shellcheck.sh" || return 1
  # The gate refuses to pass a tree whose ./-invoked entry points are not
  # executable, so a fabricated tree has to satisfy that too or every assertion
  # here fails for a reason that has nothing to do with what it asks.
  chmod +x "$MIN_DIR/mediaforge.sh" "$MIN_DIR/tests/shellcheck.sh" || return 1
}

# Runs the hook inside stub repo $1 with one content-push line on stdin.
_run_stub() {
  ( cd "$1" && printf 'refs/heads/x %s refs/heads/x %s\n' "$LIVE" "$LIVE" | ./pre-push 2>&1 )
}

# ── the hook is there, and is a shell file git will run ─────────────────────
# The executable bit is load-bearing rather than cosmetic: git silently ignores
# a hook that does not carry it, which would disable the gate with no error.
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

# ── the hook forwards the gate's verdict, both ways ─────────────────────────
# Against a stub gate, so a regression in either the hook or the gate lands on
# exactly one of these assertions instead of both.
if [ -x "$HOOK" ] && _stub_repo "$GATE_OK"; then
  _okout=$(_run_stub "$STUB_DIR"); _okrc=$?
  # The message proves the gate was CONSULTED. Exit 0 on its own is also what a
  # hook that returns early -- or ignores the gate entirely -- produces, and
  # that hook is the failure mode this file exists to catch.
  if [ "$_okrc" -eq 0 ] && printf '%s' "$_okout" | grep -qF 'running tests/shellcheck.sh'; then
    _pass hook-passes-when-gate-passes
  else
    _bad hook-passes-when-gate-passes "rc=$_okrc output=[$_okout]"
  fi
else
  _bad hook-passes-when-gate-passes "could not stage a stub repo around $HOOK"
fi

if [ -x "$HOOK" ] && _stub_repo "$GATE_FAIL"; then
  _failout=$(_run_stub "$STUB_DIR"); _failrc=$?
  if [ "$_failrc" -ne 0 ] && printf '%s' "$_failout" | grep -qF 'push aborted'; then
    _pass hook-blocks-when-gate-fails
  else
    _bad hook-blocks-when-gate-fails "rc=$_failrc output=[$_failout]"
  fi
else
  _bad hook-blocks-when-gate-fails "could not stage a stub repo around $HOOK"
fi

# ── the hook demands a real linter, not just a parser ───────────────────────
# The stub gate fails unless REQUIRE_SHELLCHECK reached it, so a hook that
# stopped exporting it turns this red -- the propagation is the assertion.
if [ -x "$HOOK" ] && _stub_repo "$GATE_REQ"; then
  _reqout=$(_run_stub "$STUB_DIR"); _reqrc=$?
  if [ "$_reqrc" -eq 0 ]; then
    _pass hook-requires-shellcheck
  else
    _bad hook-requires-shellcheck "hook did not pass REQUIRE_SHELLCHECK=1 to the gate; rc=$_reqrc"
  fi
else
  _bad hook-requires-shellcheck "could not stage a stub repo around $HOOK"
fi

# ── and the gate honours it: strict refuses, lenient still degrades ─────────
# One assertion for both halves on purpose. The lenient half alone holds on the
# pre-REQUIRE_SHELLCHECK tree too, so asserting it separately would tell
# tests/oracle-baseline.sh this file detects something it does not.
if _min_tree; then
  _gate=$MIN_DIR/tests/shellcheck.sh
  _strictout=$(REQUIRE_SHELLCHECK=1 SHELLCHECK=mediaforge-no-such-linter sh "$_gate" 2>&1)
  _strictrc=$?
  SHELLCHECK=mediaforge-no-such-linter sh "$_gate" >/dev/null 2>&1
  _lenientrc=$?
  if [ "$_strictrc" -ne 0 ] && printf '%s' "$_strictout" | grep -qF 'REQUIRE_SHELLCHECK=1' \
     && [ "$_lenientrc" -eq 0 ]; then
    _pass gate-refuses-a-pass-without-shellcheck
  else
    _bad gate-refuses-a-pass-without-shellcheck \
      "strict rc=$_strictrc lenient rc=$_lenientrc; gate said: $(printf '%s' "$_strictout" | tail -2 | tr '\n' ' ')"
  fi

  # The spliced gate text is flattened to one line: tests/oracle-baseline.sh
  # counts ^PASS / ^FAIL / ^DONE: on this file's own output, so a continuation
  # line landing at column 0 could corrupt the baseline verdict of the file doing
  # the splicing. Unreachable from the messages these two paths can produce, but
  # a lint report quotes the offending SOURCE line at column 0, so any future
  # splice that reaches one would inherit the hazard from linted content.
  # (A comment line may not START with the linter's name -- it would be read as
  # a directive, which is why that sentence is phrased around it.)
  # ── ...and will not accept a binary that merely resolves ──────────────────
  # SHELLCHECK exists so this file can reach the absent-linter path at all. An
  # env seam that names an EXECUTABLE is a trust decision, and an
  # always-succeeds shim would otherwise report every file clean, in silence.
  _shimout=$(REQUIRE_SHELLCHECK=1 SHELLCHECK=true sh "$_gate" 2>&1)
  _shimrc=$?
  if [ "$_shimrc" -ne 0 ] && printf '%s' "$_shimout" | grep -qF 'does not identify itself as ShellCheck'; then
    _pass gate-rejects-a-linter-that-only-resolves
  else
    _bad gate-rejects-a-linter-that-only-resolves \
      "SHELLCHECK=true bought rc=$_shimrc; gate said: $(printf '%s' "$_shimout" | tail -2 | tr '\n' ' ')"
  fi
else
  _bad gate-refuses-a-pass-without-shellcheck "could not stage a minimal tree"
  _bad gate-rejects-a-linter-that-only-resolves "could not stage a minimal tree"
fi

# ── the gate lints the hook directory itself, in both of its passes ─────────
# Against the real gate, because the claim here is about the real file list.
# Planted one at a time: a syntax error aborts the gate before the shellcheck
# loop, so a lint-only fixture sharing the tree with it would never be reached.
if [ -d .githooks ]; then
  _plant "$BAD_SYNTAX" "$SYNTAX_ERR"
  _synout=$(sh tests/shellcheck.sh 2>&1); _synrc=$?
  rm -f "$BAD_SYNTAX"
  # Matched on the fixture's own path, not merely on a non-zero status: a tree
  # already red for an unrelated reason exits at that file instead, and this
  # reports rather than passing for the wrong reason.
  if [ "$_synrc" -ne 0 ] && printf '%s' "$_synout" | grep -qF "$BAD_SYNTAX"; then
    _pass lint-gate-syntax-checks-githooks
  else
    _bad lint-gate-syntax-checks-githooks "gate did not flag a broken .githooks file; rc=$_synrc"
  fi

  # The expensive one, and the reason it is worth it: this is the only assertion
  # that reaches the shellcheck loop, which runs over the whole tree before it
  # arrives at .githooks. A regression that added .githooks to the sh -n list
  # only would leave every other assertion here green.
  _plant "$BAD_LINT" "$LINT_ERR"
  _lintout=$(sh tests/shellcheck.sh 2>&1); _lintrc=$?
  rm -f "$BAD_LINT"
  if [ "$_lintrc" -ne 0 ] && printf '%s' "$_lintout" | grep -qF "$BAD_LINT"; then
    _pass lint-gate-shellchecks-githooks
  else
    _bad lint-gate-shellchecks-githooks "gate did not shellcheck a clean-parsing .githooks file; rc=$_lintrc"
  fi
else
  _bad lint-gate-syntax-checks-githooks ".githooks does not exist"
  _bad lint-gate-shellchecks-githooks ".githooks does not exist"
fi

# ── a deletion-only push is let through ─────────────────────────────────────
# Deleting a merged remote branch is required by the branch policy and ships no
# content, so a lint failure that predates the deletion must not obstruct it.
if [ -x "$HOOK" ]; then
  _delout=$(printf 'refs/heads/x %s refs/heads/x %s\n' "$ZERO" "$LIVE" | "$HOOK" 2>&1)
  _delrc=$?
  if [ "$_delrc" -eq 0 ] && printf '%s' "$_delout" | grep -qF 'deletion-only push'; then
    _pass hook-skips-deletion-only-push
  else
    _bad hook-skips-deletion-only-push "rc=$_delrc output=[$_delout]"
  fi
else
  _bad hook-skips-deletion-only-push "$HOOK is not executable"
fi

printf 'DONE:\n'
exit "$_fail"
