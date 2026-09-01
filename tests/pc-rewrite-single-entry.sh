#!/bin/sh
# A .pc is rewritten through mf_pc_* and nowhere else.
#
# The sibling of tests/{cmake,meson}-single-entry.sh, and it exists for the same
# reason: eight recipes hand-rolled the same two rewrites -- six byte-identical
# awk programs appending -lstdc++, two swapping -lgcc_s for -lgcc_eh under
# LDEXEFLAGS -- and copies that agree only by inspection drift the moment one is
# edited.
#
# The behavioural half matters more than the count. Every one of the eight ran
# `awk prog "$_pc" > "$_pc.tmp" && mv "$_pc.tmp" "$_pc"` with no check that the
# .pc was there: on a missing file awk fails, the && skips the mv, and the
# recipe quietly does not apply the fix it exists to apply. A library whose
# upstream .pc name changed would then link without -lstdc++ and nothing would
# say so. That silent path is what is asserted here, not the tidiness.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

# lib/utils.sh FIRST, then the stub over the top of the die() it brings in.
# _mf_pc_rewrite performs its rewrite through mf_awk_rewrite, which lives in
# utils (GH-85); stubbing that instead would put a second implementation of the
# mechanism under test into the file that exists to pin it -- the same argument
# this file makes about hand-rolled rewrites. Sourced at file level rather than
# inside _drive so the stub below still wins, and so the subshells inherit both.
# SCRIPT_DIR is how lib/utils.sh locates lib/stage.sh.
SCRIPT_DIR="$ROOT"
# shellcheck source=lib/utils.sh
. "$ROOT/lib/utils.sh"

# One stub for every driver below. lib/framework.sh defines no die() of its own
# AND sources nothing when it is loaded -- the second half is what matters here:
# it is why _drive's `. lib/framework.sh` cannot clobber this stub, and why
# sourcing lib/utils.sh above it is safe. Three copies of the stub was the shape
# this file exists to argue against.
# Invoked from the sourced lib/framework.sh, which the linter's call graph does
# not reach; the finding is wrong here rather than tolerated.
# shellcheck disable=SC2329
die() { printf 'DIED %s\n' "$*"; exit 3; }

_tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$_tmp"' EXIT
_cleanup_on_signal
# Unconditionally, so no driver below depends on an earlier one's else-branch
# having created it.
mkdir -p "$_tmp/prefix/lib/pkgconfig"

# THE FLOOR. The offender scan below is a "grep finds nothing" claim, and an
# empty recipes/ satisfies it having verified nothing -- so is a tree where
# every pkg_post_install was deleted. Mutation-found: stripping pkg_post_install
# from all eight recipes left this file printing 4x PASS, which is the branch's
# own thesis (the fix silently not applied) going unguarded.
_sites=$(grep -rlE '(^|[^_[:alnum:]])mf_pc_(add_stdcxx|static_libgcc) ' recipes/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$_sites" -ge 8 ]; then
  _pass pc-recipes-present-to-check
else
  _bad pc-recipes-present-to-check "only $_sites recipe(s) call mf_pc_*; expected >=8"
fi

# --- no recipe rewrites a .pc by hand, and none reaches past the wrappers ---
# Keyed on the SUBSTANCE (an awk or sed touching either flag inside an install
# phase), not on one variable name: the first draft keyed on `$_pc.tmp` and a
# copy spelled `$_out` or using sed would have walked straight past it. Its
# other alternative was dead outright -- the pkgconfig path lived on the line
# above the awk, so it never matched even on the merge base.
#
# _mf_pc_rewrite is framework-internal: it takes an arbitrary awk program, so a
# recipe calling it directly is back to N spellings with only the existence
# check shared.
_offenders=""
# Redirected from a file rather than piped into the loop: a pipeline runs the
# body in a subshell and $_offenders would not survive it. Read line-by-line
# rather than word-split, so a path with a space cannot silently split.
# -rlE, not -rl: `\|` alternation is a GNU extension, and a BSD grep reads it as
# the literal string -- matching nothing, writing an empty file list, and
# leaving the loop below to report PASS having read no recipe at all. The floor
# above does not save it, because that counts files CALLING mf_pc_*, and a
# recipe can keep its call and add a hand-rolled rewrite beside it.
# tests/lib-assert.sh names this trap; this was the only `\|` in tests/.
grep -rlE 'pkg_install|pkg_post_install' recipes/ 2>/dev/null | sort -u > "$_tmp/phasefiles"
for _fn in pkg_install pkg_post_install; do
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    _body=$(_fn_body "$_f" "$_fn" | _code_only -)
    printf '%s\n' "$_body" | grep -qE '(awk|sed).*(lstdc\+\+|lgcc_s)' \
      && _offenders="$_offenders $_f:$_fn(hand-rolled)"
    printf '%s\n' "$_body" | grep -qE '(^|[^_[:alnum:]])_mf_pc_rewrite' \
      && _offenders="$_offenders $_f:$_fn(reaches past the wrappers)"
  done < "$_tmp/phasefiles"
done
_verdict pc-rewrites-go-through-the-wrappers "$_offenders"

# --- the framework really defines them --------------------------------------
# Behaviourally REDUNDANT, and kept deliberately: every mutation that trips this
# also trips a drive-based assertion below. What it buys is the difference
# between a symptom ("the rewrite failed under LDEXEFLAGS") and a cause
# ("lib/framework.sh defines no mf_pc_static_libgcc"). Recorded rather than left
# for the next reviewer to re-derive.
_reasons=""
for _fn in _mf_pc_rewrite mf_pc_add_stdcxx mf_pc_static_libgcc; do
  _code_only lib/framework.sh | grep -qE "^$_fn\(\)" || _reasons="$_reasons lib/framework.sh defines no $_fn."
done
_verdict pc-helpers-are-defined "$_reasons"

# Run one helper against the scratch prefix. PREFIX and PKG_NAME are read by the
# sourced lib/framework.sh, a cross-file consumer the linter cannot follow --
# the same rationale lib/framework.sh gives for its own file-level SC2034.
# LDEXEFLAGS first so the rest is the command and ITS arguments, which is what
# lets one driver serve a wrapper taking a .pc name and the internal taking a
# name plus an awk program. A second driver for the second shape would be the
# eighth copy of a subshell in the file arguing against copies.
# shellcheck disable=SC2034
_drive() { # ldexeflags  command  [args...]
  _d_ldex="$1"; shift
  ( set -eu
    PREFIX="$_tmp/prefix"; PKG_NAME=probe; LDEXEFLAGS="$_d_ldex"
    # shellcheck source=/dev/null
    . "$ROOT/lib/framework.sh" 2>/dev/null || true
    "$@" ) >>"$_tmp/out" 2>&1
}

# --- the missing-.pc path DIES rather than passing silently -----------------
# The one property none of the eight copies had.
_reasons=""
if ! _code_only lib/framework.sh | grep -qE '^_mf_pc_rewrite\(\)'; then
  _reasons=" _mf_pc_rewrite is not defined, so the silent path is still open."
else
  : > "$_tmp/out"
  if _drive '' mf_pc_add_stdcxx absent; then
    _reasons=" rewriting a .pc that does not exist reported success."
  elif ! grep -q '^DIED' "$_tmp/out"; then
    _reasons=" a missing .pc failed without reaching die, so a recipe would carry on unfixed."
  elif ! grep -q 'to rewrite (upstream' "$_tmp/out"; then
    # The MESSAGE, not just the death. Without this, deleting the [ -f ] check
    # is an equivalent mutation -- awk fails on the absent file and the arm
    # below it dies instead, so the property holds while the diagnostic that
    # tells an operator WHY is gone. Mutation-found.
    _reasons=" it died without naming the missing .pc, so the operator gets awk's failure instead of the cause: $(tail -1 "$_tmp/out")"
  fi
fi
_verdict missing-pc-is-fatal "$_reasons"

# --- a .pc name that is a path is refused ------------------------------------
# $1 becomes a path, and the helper is now general enough for a future caller to
# build one from PKG_PC_FILES, which recipes already declare. Inert today, which
# is why it is asserted rather than assumed: the failure mode is a write outside
# lib/pkgconfig, and nothing else in the tree would notice.
#
# A REACHABLE target is planted first, and that is the whole difficulty. With no
# guard, "../escaped" resolves to $PREFIX/lib/escaped.pc -- and if nothing is
# there the existence check dies anyway, so an assertion that only looks for
# `DIED` passes either way. Mutation-found: the first version of this was blind
# for exactly that reason. So the file exists, and what is asserted is that it
# comes back UNTOUCHED and that the refusal is the reason given.
_reasons=""
_escaped="$_tmp/prefix/lib/escaped.pc"
printf 'Name: escaped\nLibs: -lescaped\n' > "$_escaped"
_escaped_before=$(cat "$_escaped")
for _bad_name in '../escaped' 'has space' '' 'semi;colon'; do
  : > "$_tmp/out"
  if _drive '' mf_pc_add_stdcxx "$_bad_name"; then
    _reasons="$_reasons '$_bad_name' was accepted."
  elif ! grep -q 'refusing .pc name' "$_tmp/out"; then
    _reasons="$_reasons '$_bad_name' was rejected for the wrong reason: $(tail -1 "$_tmp/out")"
  fi
done
[ "$(cat "$_escaped")" = "$_escaped_before" ] \
  || _reasons="$_reasons a traversing name rewrote a file outside lib/pkgconfig."
_verdict pc-name-must-be-a-bare-name "$_reasons"

# --- a failed rewrite strands no .tmp in the prefix -------------------------
# Nothing caught removing either `rm -f` from the die paths. The leak is a stale
# temp file rather than a wrong link, so this is hygiene, not correctness -- but
# it is one drive and the prefix is what reconcile audits, where a file no
# manifest names is exactly what GH-77 is about.
# The definedness guard is not ceremony: without it this assertion PASSES on the
# merge base, where _mf_pc_rewrite does not exist, the drive fails for that
# reason, and "no .tmp was stranded" is trivially true of a rewrite that never
# ran. tests/oracle-baseline.sh caught exactly that.
_reasons=""
_code_only lib/framework.sh | grep -qE '^_mf_pc_rewrite\(\)' \
  || _reasons=" _mf_pc_rewrite is not defined, so nothing here ran."
_broken="$_tmp/prefix/lib/pkgconfig/broken.pc"
printf 'Name: broken\nLibs: -lbroken\n' > "$_broken"
: > "$_tmp/out"
# An awk program that parses but fails at runtime, so the redirection has
# already created the .tmp before awk dies.
_drive '' _mf_pc_rewrite broken '{ exit 1 }' \
  && _reasons=" a failing awk program reported success."
[ -e "$_broken.tmp" ] && _reasons="$_reasons the failed rewrite left $_broken.tmp behind, which no manifest names."
_verdict failed-rewrite-strands-no-tmp "$_reasons"

# --- -lstdc++: appended once, and only to Libs: -----------------------------
# Libs.private is in the fixture to pin the `^Libs:` anchor: without it the
# probe has one Libs line and loosening the pattern to /Libs/ survives.
_reasons=""
_probe="$_tmp/prefix/lib/pkgconfig/probe.pc"
printf 'Name: probe\nLibs: -L/x -lprobe\nLibs.private: -lm\n' > "$_probe"
: > "$_tmp/out"
_drive '' mf_pc_add_stdcxx probe || _reasons=" the rewrite failed on a well-formed .pc."
grep -q '^Libs: -L/x -lprobe -lstdc++$' "$_probe" \
  || _reasons="$_reasons Libs: was not appended to: $(sed -n 2p "$_probe")"
grep -q '^Libs.private: -lm$' "$_probe" \
  || _reasons="$_reasons Libs.private was touched: $(sed -n 3p "$_probe")"
# Idempotent, which the `!/-lstdc\+\+/` guard is for: post_install runs again on
# a rebuild that did not reinstall the .pc. grep -o, not grep -c: -c counts
# matching LINES, so a doubled "-lstdc++ -lstdc++" on one line still counts 1.
_drive '' mf_pc_add_stdcxx probe || _reasons="$_reasons the second application failed."
_n=$(grep -o -- '-lstdc++' "$_probe" | wc -l | tr -d ' ')
[ "$_n" = 1 ] || _reasons="$_reasons applying it twice left $_n copies of -lstdc++."
_verdict stdcxx-rewrite-is-correct-and-idempotent "$_reasons"

# --- -lgcc_s -> -lgcc_eh, and ONLY under LDEXEFLAGS -------------------------
# The boundary pair. Without the second half nothing pins the guard the helper
# absorbed from its two call sites, and `return 0` as the function's first line
# survives -- both mutations did, before this existed.
_reasons=""
_g="$_tmp/prefix/lib/pkgconfig/gprobe.pc"
printf 'Name: gprobe\nLibs: -lfoo -lgcc_s\n' > "$_g"
: > "$_tmp/out"
_drive '-static' mf_pc_static_libgcc gprobe || _reasons=" the rewrite failed under LDEXEFLAGS."
grep -q '^Libs: -lfoo -lgcc_eh$' "$_g" \
  || _reasons="$_reasons under LDEXEFLAGS the unwinder was not swapped: $(sed -n 2p "$_g")"
printf 'Name: gprobe\nLibs: -lfoo -lgcc_s\n' > "$_g"
_before=$(cat "$_g")
_drive '' mf_pc_static_libgcc gprobe || _reasons="$_reasons the empty-LDEXEFLAGS call failed."
[ "$(cat "$_g")" = "$_before" ] \
  || _reasons="$_reasons with LDEXEFLAGS empty it rewrote anyway: $(sed -n 2p "$_g")"
_verdict libgcc-swap-is-gated-on-ldexeflags "$_reasons"

printf 'DONE: pc-rewrite-single-entry\n'
exit "$_fail"
