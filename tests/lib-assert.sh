# shellcheck shell=sh
# The assertion reporters, defined ONCE.
#
# Sourced by path from the test that uses it, and requires that test to have
# initialised $_fail to 0 -- _bad sets it, and the caller exits with it.
#
# Called as `_pass <assertion-name>`, `_bad <assertion-name> "<detail>"`, or
# `_bad <assertion-name>` where the name is the whole claim and there is no
# detail to add -- the majority shape in tests/install-manifest-reconcile.sh,
# whose _pass and _bad said the same sentence before they had names. The name is
# what the reporter prints, so it should read as the claim being made
# ("symlinked-leaf-replaced-not-followed"), not as a restatement of the detail.
#
# Before this file existed the pair was copy-pasted into every test that wanted
# it, in three spellings, and the copies drifted. Of the seven that already used
# this file's `FAIL [<name>] <detail>` shape, five omitted the `tr '\n' ' '`
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
# A third spelling (`FAIL: <sentence>` on stdout, with no assertion name) was
# converged over two changes -- #45 took tests/hash-comment-grammar.sh, #46 the
# last six -- which is why no file outside this one defines the pair any more.
# `grep -rn '_pass()\|_bad()' tests/` is the check, matching either function
# unanchored so that an indented redefinition inside a function, or a file that
# copied only _bad, is caught too. No file census is written here: the
# enumeration this header used to carry drifted twice in three commits, and the
# grep does not.
#
# FAIL goes to stderr and PASS to stdout, so a caller can read the failures
# alone. oracle-baseline captures both (`sh "$_f" 2>&1`), so the split does not
# hide an assertion from it.
_pass() { printf 'PASS [%s]\n' "$1"; }
_bad() {
  if [ "$#" -ge 2 ]; then
    printf 'FAIL [%s] %s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ')" >&2
  else
    printf 'FAIL [%s]\n' "$1" >&2
  fi
  _fail=1
}
