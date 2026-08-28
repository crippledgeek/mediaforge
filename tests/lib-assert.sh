# shellcheck shell=sh
# The assertion reporters, defined ONCE.
#
# Requires $ROOT to be set by the caller, and $_fail to be initialised to 0 --
# _bad sets it, and the caller exits with it.
#
# Seven test files carried this pair before this file existed, in TWO spellings:
# five omitted the `tr '\n' ' '` and two did not. (The eighth file sourcing it,
# tests/hash-comment-grammar.sh, is new and never carried a copy.) Without the
# flattening a FAIL whose detail spans lines emits continuation lines of its
# own. That is not cosmetic here. tests/oracle-baseline.sh measures a newly
# added test by COUNTING assertion lines, and the BASELINE run is counted with
# `grep -c '^PASS'` and `grep -c '^FAIL'` separately (the combined
# `^(PASS|FAIL)` pattern counts the current tree, not the base). So a detail
# line that happens to begin with `PASS` -- an assertion name
# quoted back inside a failure message, say -- is counted as an assertion that
# passed on the base, and the gate reports the file as an offender that cannot
# be detecting its change. Flattening the detail to one line is what makes the
# count mean what the gate thinks it means.
#
# FAIL goes to stderr and PASS to stdout, so a caller can read the failures
# alone. oracle-baseline captures both (`sh "$_f" 2>&1`), so the split does not
# hide an assertion from it.
#
# Six further test files (install-containment, install-manifest-reconcile,
# install-privileged-execs, libressl-pin-asm, libressl-trust-store,
# gitignore-artifacts) carry a third spelling OF THESE TWO FUNCTIONS:
# `FAIL: <sentence>` on stdout, with no assertion name. (Other tests report
# inline without helpers at all; this file is not a census of the tree.) They
# are not converged here because their call sites pass a whole sentence as the
# first argument, so each needs a NAME invented for it -- a judgement per site,
# not a rename. No count is given here on purpose: the
# enumeration in this header has drifted twice in three commits, and
# `grep -c '^[[:space:]]*_\(pass\|bad\)[[:space:]]' tests/<file>.sh` answers it
# without rotting.
#
# That debt is NOT tracked by an issue yet. Saying so is the point: a comment
# claiming a record exists elsewhere, with nothing to check it against, is the
# citation shape this branch is cleaning up.
_pass() { printf 'PASS [%s]\n' "$1"; }
_bad()  { printf 'FAIL [%s] %s\n' "$1" "$(printf '%s' "${2-}" | tr '\n' ' ')" >&2; _fail=1; }
