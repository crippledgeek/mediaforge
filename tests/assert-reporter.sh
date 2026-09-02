#!/bin/sh
# The shared reporters print exactly what tests/oracle-baseline.sh counts.
#
# tests/lib-assert.sh is where every test that uses the shared reporters routes
# its verdict, and the only file nothing else asserts on: a defect in _pass or
# _bad does not fail a test, it changes what a passing test PRINTS — and
# printing is the whole interface. Every test in the suite routes through it
# now (#48 converged the last twelve, which printed PASS/FAIL inline in three
# further spellings); `grep -L lib-assert tests/*.sh` returns only this
# library, tests/lib-provenance.sh, and the two gates that format their own
# output.
#
# tests/oracle-baseline.sh reads that output with `grep -c '^PASS'` and
# `grep -c '^FAIL'` to decide whether a newly added file could detect its own
# change, so the reporters' exact bytes are a gate input, not cosmetics.
#
# SIX assertions, and the split is deliberate. This line read FOUR while the
# file already emitted five, so it had been stale for at least one group before
# this one arrived -- a count in prose is only as current as its last editor,
# and nothing checks it.
#
# Probes 1-6 are ONE compound assertion, for a reason that is now HISTORICAL and
# is written in the past tense on purpose. oracle-baseline requires that no
# assertion in a newly added file passes on the merge base; when this file was
# added, against d9c918b, five of its six reporter probes held there already --
# only the no-detail form's output had a trailing space. Splitting them would
# have put five free passes on that base and the gate would have rejected the
# file, so the printed contract was asserted together with the one thing the
# base got wrong carrying it. Against TODAY's base all six hold (the
# trailing-space fix is in it) and the gate does not reach this file at all,
# since it is now modified rather than added -- so the shape is kept for the
# history, not because today's gate demands it.
#
# Probes 7-9 cover _evidence and stand alone, because that argument does not
# reach them under either base: _evidence exists in neither, so each of them
# fails there and none is a free pass. Folding them in would report a broken
# helper as `FAIL [reporter-output-contract-holds]` -- a name that does not name
# the claim
# being made, which is the rule at tests/lib-assert.sh's head and the defect
# that got a duplicate row deleted from tests/dry-run-matrix.sh on this branch.
# _evidence is also not a reporter: it is not part of the printed contract that
# oracle-baseline reads with `grep -c '^PASS'`, which probes 1-6 are about.
#
# Probes 1-6 each run in their own shell rather than in this one, because _bad
# sets _fail=1 by design — calling it here would fail this file for doing its
# job. That shell also isolates the stream split: stdout and stderr are captured
# separately, so "PASS went to stdout" and "FAIL went to stderr" are assertable
# rather than assumed. Probes 7-9 need no isolation: _evidence touches neither
# stream nor _fail, so they call it here.
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
trap 'rm -f "$_err"' EXIT
_cleanup_on_signal

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

# Group handoff. $_wrong is the scratch accumulator _want appends to; each
# group's result moves into its own variable so _want keeps three parameters.
# A _want call added BELOW the second handoff would be silently dropped from
# both reports -- put new probes above the group they belong to.
_wrong_rep=$_wrong
_wrong=''

# 7. _evidence yields at most N matching lines...
_got=$(printf 'a\nERROR one\nb\nERROR two\nc\n' | _evidence 1 'error')
_want 'evidence-matches-and-caps' "$_got" 'ERROR one'

# 8. ...falls back to the LAST N lines when nothing matches, so a detail is
#    never empty...
_got=$(printf 'a\nb\nc\n' | _evidence 2 'nothing-here')
_want 'evidence-falls-back-to-tail' "$_got" 'b
c'

# 9. ...and accepts a pattern beginning with a dash. Without the `--` in
#    _evidence, `grep -iE "-L"` reads -L as --files-without-match and prints
#    "(standard input)" instead of the matching line -- measured, not assumed.
# The trailing line matters: without it the tail fallback returns -L/nope too,
# and the probe passes whether or not the guard is there -- measured, and the
# first draft of this probe had exactly that hole.
_got=$(printf 'x\n-L/nope\nlast\n' | _evidence 1 '-L')
_want 'evidence-accepts-dash-pattern' "$_got" '-L/nope'

_wrong_ev=$_wrong
_wrong=''

# 10-12. _wired is the third thing this library now owns, and it is a reporter:
# it calls _pass/_bad itself, so a defect in it prints a wrong verdict rather
# than failing anything. It moved here from tests/debug-levels.sh and
# tests/ccache.sh, which held character-identical copies that had already
# drifted in their failure wording.
_got=$(_probe <<'EOF'
_wired name tests/lib-assert.sh '_wired()'
EOF
)
_want 'wired-passes-on-a-hit' "$_got" 'PASS [name]'

# A needle that is absent must FAIL rather than pass quietly -- the whole point
# of the helper is asserting that wiring exists.
_probe >/dev/null <<'EOF'
_wired name tests/lib-assert.sh 'no-such-needle-anywhere'
EOF
_want 'wired-fails-on-a-miss' "$(cat "$_err")" 'FAIL [name] tests/lib-assert.sh never mentions no-such-needle-anywhere'

# FIXED-string matching, not regex. Real needles in-tree are case labels like
# `--ccache)` whose parenthesis is a regex metacharacter.
#
# The needle has to be a VALID regex that MATCHES under -E while being absent as
# a literal, or the probe cannot tell the two apart: the first version used
# 'a)b', which -E rejects as an unbalanced parenthesis, so grep failed either
# way and the probe passed against a -qE implementation too -- caught by
# mutating -qF to -qE and watching this file stay green. '_pass|_bad' is an
# alternation that -E finds in the library and -F does not.
_probe >/dev/null <<'EOF'
_wired name tests/lib-assert.sh '_pass|_bad'
EOF
_want 'wired-needle-is-literal' "$(cat "$_err")" 'FAIL [name] tests/lib-assert.sh never mentions _pass|_bad'

_wrong_wired=$_wrong
_wrong=''

# 13-15. _uses_composed_cflags is the fourth thing this library owns, and the
# one whose failure is silent in the worst way: it is the predicate two gates
# use to decide whether a recipe DERIVES its compiler flags or REPLACES them.
# Mutating the comment-stripping out of it leaves both gates green on a recipe
# that drops -fPIC and the prefix include path -- measured, which is why it is
# pinned here rather than only through the gates that call it.
_probe_dir=$(mktemp -d) || exit 1
cat > "$_probe_dir/decoy.sh" <<'DECOY'
_decoy_cflags() {
  # NOTE: does not use $CFLAGS here, this is a decoy comment only
  printf '%s' "-O2 -w"
}
DECOY
cat > "$_probe_dir/real.sh" <<'REAL'
_real_cflags() { printf '%s' "-std=gnu99 $CFLAGS"; }
_named_cflags() { printf '%s' "$CFLAGS_BACKUP"; }
REAL

if _uses_composed_cflags "$_probe_dir/decoy.sh" _decoy_cflags; then
  _want 'cflags-decoy-comment-rejected' 'exempted' 'rejected'
else
  _want 'cflags-decoy-comment-rejected' 'rejected' 'rejected'
fi
if _uses_composed_cflags "$_probe_dir/real.sh" _real_cflags; then
  _want 'cflags-real-derivation-accepted' 'accepted' 'accepted'
else
  _want 'cflags-real-derivation-accepted' 'rejected' 'accepted'
fi
# A longer name that merely STARTS with CFLAGS is not a use of it.
if _uses_composed_cflags "$_probe_dir/real.sh" _named_cflags; then
  _want 'cflags-longer-name-not-a-use' 'accepted' 'rejected'
else
  _want 'cflags-longer-name-not-a-use' 'rejected' 'rejected'
fi
rm -rf "$_probe_dir"

_wrong_cflags=$_wrong
_wrong=''

# 16-17. _tree_sh_files and _lib_code are the fifth thing this library owns:
# they walk a corpus rooted at $ROOT, and a
# corpus that silently goes EMPTY is the worst failure either can have: every
# gate built on them asks "does any file in the tree do X", so an empty walk
# answers "no" for a tree nobody read. That is not hypothetical -- it shipped.
# tests/pc-exclusions-durable.sh spells its root $_root, called _tree_sh_files
# with no argument, and its whole-tree deleter search scanned zero files while
# reporting PASS (GH-90 branch).
#
# What made it survive is that six of the seven callers do NOT `set -u`. For
# them an unset $ROOT expands to empty, the paths become "/lib/*.sh", the glob
# matches nothing, and the helper returns status 0 having emitted nothing --
# no error, no diagnostic, a clean exit. Only pc-exclusions-durable.sh sets
# -u, which is the single reason anyone ever saw a message about it.
#
# So the contract asserted here is that an ABSENT root is fatal rather than
# empty. `${ROOT:?}` is what makes it fatal without depending on the caller's
# `set -u`, and this pair is what stops a future edit from restoring the
# quiet default.
# `set +u` inside each probe is the whole point and not a convenience: this
# file runs under `set -u`, where an unset $ROOT is already fatal, so a probe
# that inherited it would assert the one configuration that was never broken
# and pass against the old helper. Six of the seven real callers run without
# -u, and `set +u` is what reproduces them.
if (set +u; unset ROOT; _tree_sh_files >/dev/null 2>&1); then
  _want 'tree-walk-refuses-an-absent-root' 'returned an empty corpus' 'failed'
else
  _want 'tree-walk-refuses-an-absent-root' 'failed' 'failed'
fi
if (set +u; unset ROOT; _lib_code >/dev/null 2>&1); then
  _want 'lib-code-refuses-an-absent-root' 'returned an empty corpus' 'failed'
else
  _want 'lib-code-refuses-an-absent-root' 'failed' 'failed'
fi

_wrong_root=$_wrong
_wrong=''

# 18-20. _verdict is the sixth thing this library owns: the report of a COMPOUND
# assertion, chosen by whether the caller's accumulator is empty. It is pinned
# here for the same reason the pair below it is -- a defect in it does not fail
# a test, it changes what a test PRINTS, and printing is what
# tests/oracle-baseline.sh counts.
#
# This file's own four verdicts now route through it, which looks circular and
# is not: the probes below run in isolated shells, and the exit at the foot of
# this file keys on $_wrong rather than on $_fail precisely so a broken
# reporter cannot report itself green.
_got=$(_probe <<'EOF'
_verdict eta ""
EOF
)
_want 'verdict-empty-reasons-passes' "$_got" 'PASS [eta]'
_want 'verdict-pass-stderr-silent' "$(cat "$_err")" ''

# A non-empty accumulator must reach _bad WITH its detail: a _verdict that
# reported the failure and dropped the reasons would leave every compound
# assertion in the suite saying only that something was wrong.
_got=$(_probe <<'EOF'
_verdict theta " first;  second;"
EOF
)
_want 'verdict-reasons-stdout-silent' "$_got" ''
_want 'verdict-reasons-reach-the-detail' "$(cat "$_err")" 'FAIL [theta]  first;  second;'

# The polarity, stated as its own probe. An accumulator holding the string
# "0" or " " is NOT empty, and a _verdict testing truthiness rather than
# emptiness would pass a failing claim -- `[ -z ]` is the contract.
_got=$(_probe <<'EOF'
_verdict iota "0"
printf '%s' "$_fail"
EOF
)
_want 'verdict-zero-string-is-not-empty' "$_got" '1'

_wrong_verdict=$_wrong   # last handoff: no _want may follow this line

_verdict reporter-output-contract-holds "$_wrong_rep"

_verdict evidence-helper-contract-holds "$_wrong_ev"

_verdict wired-helper-contract-holds "$_wrong_wired"

_verdict cflags-derivation-predicate-holds "$_wrong_cflags"
_verdict tree-corpus-root-contract-holds "$_wrong_root"
_verdict verdict-helper-contract-holds "$_wrong_verdict"

printf 'DONE: assert-reporter\n'

# Exits on $_wrong, NOT on $_fail, and this is the one file in the suite that
# should. Every other test trusts _bad to set _fail; here _fail IS part of the
# subject, so trusting it would let a _bad that stopped setting it print a FAIL
# line and still exit 0 -- measured: mutating `_fail=1` out of the library left
# this file reporting the defect on stdout while tests/run.sh, which reads exit
# status, went green.
[ -z "$_wrong_rep$_wrong_ev$_wrong_wired$_wrong_cflags$_wrong_root$_wrong_verdict" ] || exit 1
exit 0
