# shellcheck shell=sh
# The assertion reporters, defined ONCE.
#
# Sourced by path from the test that uses it, and requires that test to have
# initialised $_fail to 0 -- _bad sets it, and the caller exits with it.
#
# Called as `_pass <assertion-name>` and `_bad <assertion-name> "<detail>"`. The
# name is what the reporter prints, so it should read as the claim being made
# ("symlinked-leaf-replaced-not-followed"), not as a restatement of the detail.
#
# Before this file existed the pair was copy-pasted into every test that wanted
# it, in three spellings, and the copies drifted. Five omitted the `tr '\n' ' '`
# below and two did not. That is not cosmetic. tests/oracle-baseline.sh measures
# a newly added test by COUNTING assertion lines, and the BASELINE run is
# counted with `grep -c '^PASS'` and `grep -c '^FAIL'` separately (the combined
# `^(PASS|FAIL)` pattern counts the current tree, not the base). So a detail
# line that happens to begin with `PASS` -- an assertion name quoted back inside
# a failure message, say -- is counted as an assertion that passed on the base,
# and the gate reports the file as an offender that cannot be detecting its
# change. Flattening the detail to one line is what makes the count mean what
# the gate thinks it means.
#
# The third spelling (`FAIL: <sentence>` on stdout, with no assertion name) was
# converged in #46, which is why no file outside this one defines the pair any
# more. `grep -rn '^_pass()' tests/` is the check; no count is written here,
# because the enumeration this header used to carry drifted twice in three
# commits.
#
# FAIL goes to stderr and PASS to stdout, so a caller can read the failures
# alone. oracle-baseline captures both (`sh "$_f" 2>&1`), so the split does not
# hide an assertion from it.
_pass() { printf 'PASS [%s]\n' "$1"; }
_bad()  { printf 'FAIL [%s] %s\n' "$1" "$(printf '%s' "${2-}" | tr '\n' ' ')" >&2; _fail=1; }
