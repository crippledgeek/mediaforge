#!/bin/sh
# The shared reporters print exactly what tests/oracle-baseline.sh counts.
#
# tests/lib-assert.sh is where every test that uses the shared reporters routes
# its verdict, and the only file nothing else asserts on: a defect in _pass or
# _bad does not fail a test, it changes what a passing test PRINTS — and
# printing is the whole interface. Not the whole suite goes through it: several
# tests still print PASS/FAIL inline, in spellings oracle-baseline counts
# identically, and `grep -L lib-assert tests/*.sh` narrows them to a candidate
# list rather than a count here that would drift -- it returns a superset,
# since this library, tests/lib-provenance.sh and the two gates appear in it
# too. Converging those is #48 -- three spellings across twelve files, each
# call site needing a name invented for it -- not this file's job; being
# correct about the ones that DO route through it is.
#
# tests/oracle-baseline.sh reads that output with `grep -c '^PASS'` and
# `grep -c '^FAIL'` to decide whether a newly added file could detect its own
# change, so the reporters' exact bytes are a gate input, not cosmetics.
#
# ONE compound assertion, deliberately. oracle-baseline requires that no
# assertion in a newly added file passes on the merge base, and five of the six
# numbered probes below held there already — only the no-detail form's output
# had a trailing space. Asserting them separately would put five free passes on
# the base and the gate would correctly reject the file, so the whole contract
# is asserted together with the one the base gets wrong carrying it. That is
# also the honest shape: the claim is "the printed contract holds", not six
# independent facts.
#
# Every probe runs in its own shell rather than in this one, because _bad sets
# _fail=1 by design — calling it here would fail this file for doing its job.
# That shell also isolates the stream split: stdout and stderr are captured
# separately, so "PASS went to stdout" and "FAIL went to stderr" are assertable
# rather than assumed.
#
# No `set -e`: the single check reports and this file exits with the accumulated
# status, and the baseline gate depends on a file that reaches its DONE line.
set -u

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
_root=$(CDPATH='' cd -- "$_here/.." && pwd)
cd "$_root" || exit 1

_fail=0
# shellcheck source=tests/lib-assert.sh
. "$_root/tests/lib-assert.sh"

_err=$(mktemp) || exit 1
trap 'rm -f "$_err"' EXIT INT TERM

# Run one reporter call in a fresh shell. The fragment arrives on stdin from a
# QUOTED here-doc, so it reaches the inner shell verbatim; the preamble is
# printed once here rather than repeated per probe. Nothing in the printf is
# `$`-expanded -- the library is sourced by a path relative to the cwd this
# script already established -- which is what keeps the fragment out of a
# single-quoted string that ShellCheck would (correctly) read as un-expanded.
#
# stderr goes to $_err so the two streams stay distinguishable. Command
# substitution strips trailing NEWLINES and never trailing SPACES, which is what
# lets the comparisons below see the trailing space the no-detail form emitted
# before this branch.
_probe() {
  { printf '_fail=0\n. tests/lib-assert.sh\n'; cat; } | sh -s 2>"$_err"
}

_wrong=''
_want() {
  # _want <property> <got> <expected>
  [ "$2" = "$3" ] || _wrong="$_wrong
  $1: got [$2] want [$3]"
}

# 1. _pass writes its name to stdout, and nothing to stderr.
_got=$(_probe <<'EOF'
_pass alpha
EOF
)
_want 'pass-stdout' "$_got" 'PASS [alpha]'
_want 'pass-stderr-silent' "$(cat "$_err")" ''

# 2. _bad with a detail writes name and detail to stderr, and nothing to stdout.
_got=$(_probe <<'EOF'
_bad beta "a detail"
EOF
)
_want 'bad-stdout-silent' "$_got" ''
_want 'bad-stderr' "$(cat "$_err")" 'FAIL [beta] a detail'

# 3. _bad with NO detail prints the name alone. The trailing space this used to
#    emit is the half of this assertion that fails on the merge base.
_probe >/dev/null <<'EOF'
_bad gamma
EOF
_want 'bad-no-detail' "$(cat "$_err")" 'FAIL [gamma]'

# 4. A multi-line detail is flattened to one line, so it cannot emit a
#    continuation line beginning with PASS that oracle-baseline would count as
#    an assertion that passed on the base.
_probe >/dev/null <<'EOF'
_bad delta "$(printf '%s\n%s' one PASS)"
EOF
_want 'bad-flattens-newlines' "$(cat "$_err")" 'FAIL [delta] one PASS'

# 5. _bad sets _fail, which is how every caller's exit status is built.
_got=$(_probe <<'EOF'
_bad epsilon "x"
printf '%s' "$_fail"
EOF
)
_want 'bad-sets-fail' "$_got" '1'

# 6. _pass leaves _fail alone.
_got=$(_probe <<'EOF'
_pass zeta >/dev/null
printf '%s' "$_fail"
EOF
)
_want 'pass-leaves-fail' "$_got" '0'

if [ -z "$_wrong" ]; then
  _pass reporter-output-contract-holds
else
  _bad reporter-output-contract-holds "$_wrong"
fi

printf 'DONE: assert-reporter\n'

# Exits on $_wrong, NOT on $_fail, and this is the one file in the suite that
# should. Every other test trusts _bad to set _fail; here _fail IS part of the
# subject, so trusting it would let a _bad that stopped setting it print a FAIL
# line and still exit 0 -- measured: mutating `_fail=1` out of the library left
# this file reporting the defect on stdout while tests/run.sh, which reads exit
# status, went green.
[ -z "$_wrong" ] || exit 1
exit 0
