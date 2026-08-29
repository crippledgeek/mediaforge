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
# #48 then took the twelve that defined nothing but inlined the printf at each
# call site instead, which no definition-grep could see.
# `grep -rnE '_pass\(\)|_bad\(\)' tests/` is the check -- ERE, because `\|`
# alternation is a GNU extension a BSD grep silently matches nothing with, and
# unanchored, so an indented redefinition inside a function or a file that
# copied only _bad is caught too. It answers "does anything else DEFINE the
# pair", which is narrower than this paragraph's subject: a test that inlines
# `printf 'PASS ...'` at each call site is a copy that no definition-grep can
# see, and `grep -rnE "printf '(PASS|FAIL)" tests/` is the complement that
# finds those. No file census is written here: the enumeration this header used
# to carry drifted twice in three commits, and a grep does not.
#
# FAIL goes to stderr and PASS to stdout, so a caller can read the failures
# alone. oracle-baseline captures both (`sh "$_f" 2>&1`), so the split does not
# hide an assertion from it.
#
# Evidence for a failure detail: at most $1 lines of the log on stdin matching
# the ERE $2, falling back to the LAST $1 lines when nothing matches -- or when
# grep cannot run the pattern at all, which is the same answer for the same
# reason -- so a detail is never empty and never unbounded. A malformed ERE is
# not silent (grep says so on stderr, beside the FAIL line), but _evidence only
# runs once a test has already failed, so a broken pattern lies dormant until
# the moment the diagnosis is wanted. Every pattern in-tree is a fixed literal;
# a computed one would want checking here first. Both failures were real. A grep for
# 'monoton|error' finds nothing when an encoder fails some other way, leaving
# `FAIL [name]` with no diagnosis at all; and an uncapped `cat` of a linker log
# becomes one flattened multi-kilobyte line, since _bad collapses newlines.
#
# `grep -- "$2"` so a pattern beginning with a dash (`-L`) is read as a pattern
# rather than as options: without it `grep -iE "-L"` takes -L as
# --files-without-match and prints "(standard input)" instead of the match.
_evidence() {
  _ev=$(cat)
  _ev_hit=$(printf '%s\n' "$_ev" | grep -iE -- "$2" | head -n "$1")
  [ -n "$_ev_hit" ] || _ev_hit=$(printf '%s\n' "$_ev" | tail -n "$1")
  printf '%s' "$_ev_hit"
}

_pass() { printf 'PASS [%s]\n' "$1"; }
_bad() {
  if [ "$#" -ge 2 ]; then
    printf 'FAIL [%s] %s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ')" >&2
  else
    printf 'FAIL [%s]\n' "$1" >&2
  fi
  _fail=1
}

# Glob-match reporters. The pattern "run something, glob-match the result,
# _pass or _bad with the actual value in the detail" was written five times
# across tests/compiler-flags.sh and tests/debug-levels.sh, in two polarities.
# It is the same convergence the reporters themselves went through in #45/#46/
# #48: the copies agreed only by inspection, and the detail string -- the thing
# a reader sees when a test fails -- had already drifted between them.
#
# $3 is a GLOB by design, so it is deliberately unquoted in the case. The caller
# passes the actual value in $2 and a describing prefix in $4, so the failure
# line says what was fed in as well as what came out.
#
# NOTE the polarity trap these replaced: a "must NOT match" check is satisfied by
# the empty string, so on a tree lacking the feature it passes having verified
# nothing. _glob_not therefore FAILS on empty input rather than passing, and
# callers that can legitimately produce empty must say so before calling.
_glob() { # name  actual  glob  detail-prefix
  # shellcheck disable=SC2254
  case "$2" in
    $3) _pass "$1" ;;
    *)  _bad "$1" "$4 got=[$2]" ;;
  esac
}

_glob_not() { # name  actual  glob  detail-prefix
  if [ -z "$2" ]; then
    _bad "$1" "$4 produced nothing — a negative claim on empty input is vacuous"
    return
  fi
  # shellcheck disable=SC2254
  case "$2" in
    $3) _bad "$1" "$4 got=[$2]" ;;
    *)  _pass "$1" ;;
  esac
}

# "Is this wiring present in that file?" -- a literal grep reported as a named
# assertion. Defined here after being written twice: tests/debug-levels.sh and
# tests/ccache.sh had character-identical copies that already disagreed on the
# failure wording ("never calls" vs "never mentions"), which is the drift the
# header above describes happening again in miniature.
#
# grep -qF, not -qE: every needle in-tree is a fixed string (a case label, a
# help line, a function name), and one containing a regex metacharacter -- a
# `--ccache)` label ends in one -- would silently match something else.
_wired() { # name  file  needle
  if grep -qF -- "$3" "$2" 2>/dev/null; then
    _pass "$1"
  else
    _bad "$1" "$2 never mentions $3"
  fi
}
