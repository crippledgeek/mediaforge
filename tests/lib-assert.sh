# shellcheck shell=sh
# The assertion reporters, defined ONCE.
#
# Requires $ROOT to be set by the caller, and $_fail to be initialised to 0 --
# _bad sets it, and the caller exits with it.
#
# Eight test files carried byte-identical copies of these two lines before this
# file existed, and a ninth pair had already drifted: five of them omitted the
# `tr '\n' ' '`, so a FAIL whose detail spanned lines emitted continuation lines
# of its own. That is not cosmetic here. tests/oracle-baseline.sh measures a
# newly added test by COUNTING the lines matching `^(PASS|FAIL)` on the merge
# base, so a detail line that happens to begin with `PASS` -- an assertion name
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
# gitignore-artifacts) still carry a THIRD variant: `FAIL: <sentence>` on
# stdout, with no assertion name. They are not converged here because their 182
# call sites pass a whole sentence as the first argument, so each one needs a
# name invented for it -- a judgement per call site, not a rename. Tracked
# separately; this file is the definition they should move onto.
_pass() { printf 'PASS [%s]\n' "$1"; }
_bad()  { printf 'FAIL [%s] %s\n' "$1" "$(printf '%s' "${2-}" | tr '\n' ' ')" >&2; _fail=1; }
