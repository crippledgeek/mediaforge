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

# One stub for every driver below. lib/framework.sh defines no die() and sources
# nothing when loaded, so this survives into each subshell -- three copies of it
# was the shape this file exists to argue against.
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
grep -rl 'pkg_install\|pkg_post_install' recipes/ 2>/dev/null | sort -u > "$_tmp/phasefiles"
for _fn in pkg_install pkg_post_install; do
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    _body=$(_fn_body "$_f" "$_fn" | sed 's/[[:space:]]*#.*$//')
    printf '%s\n' "$_body" | grep -qE '(awk|sed).*(lstdc\+\+|lgcc_s)' \
      && _offenders="$_offenders $_f:$_fn(hand-rolled)"
    printf '%s\n' "$_body" | grep -qE '(^|[^_[:alnum:]])_mf_pc_rewrite' \
      && _offenders="$_offenders $_f:$_fn(reaches past the wrappers)"
  done < "$_tmp/phasefiles"
done
_verdict pc-rewrites-go-through-the-wrappers "$_offenders"

# --- the framework really defines them --------------------------------------
_reasons=""
for _fn in _mf_pc_rewrite mf_pc_add_stdcxx mf_pc_static_libgcc; do
  _code_only lib/framework.sh | grep -qE "^$_fn\(\)" || _reasons="$_reasons lib/framework.sh defines no $_fn."
done
_verdict pc-helpers-are-defined "$_reasons"

# Run one helper against the scratch prefix. PREFIX and PKG_NAME are read by the
# sourced lib/framework.sh, a cross-file consumer the linter cannot follow --
# the same rationale lib/framework.sh gives for its own file-level SC2034.
# shellcheck disable=SC2034
_drive() { # helper  pc-name  ldexeflags
  ( set -eu
    PREFIX="$_tmp/prefix"; PKG_NAME=probe; LDEXEFLAGS="$3"
    # shellcheck source=/dev/null
    . "$ROOT/lib/framework.sh" 2>/dev/null || true
    "$1" "$2" ) >>"$_tmp/out" 2>&1
}

# --- the missing-.pc path DIES rather than passing silently -----------------
# The one property none of the eight copies had.
_reasons=""
if ! _code_only lib/framework.sh | grep -qE '^_mf_pc_rewrite\(\)'; then
  _reasons=" _mf_pc_rewrite is not defined, so the silent path is still open."
else
  : > "$_tmp/out"
  if _drive mf_pc_add_stdcxx absent ''; then
    _reasons=" rewriting a .pc that does not exist reported success."
  elif ! grep -q '^DIED' "$_tmp/out"; then
    _reasons=" a missing .pc failed without reaching die, so a recipe would carry on unfixed."
  fi
fi
_verdict missing-pc-is-fatal "$_reasons"

# --- -lstdc++: appended once, and only to Libs: -----------------------------
# Libs.private is in the fixture to pin the `^Libs:` anchor: without it the
# probe has one Libs line and loosening the pattern to /Libs/ survives.
_reasons=""
_probe="$_tmp/prefix/lib/pkgconfig/probe.pc"
printf 'Name: probe\nLibs: -L/x -lprobe\nLibs.private: -lm\n' > "$_probe"
: > "$_tmp/out"
_drive mf_pc_add_stdcxx probe '' || _reasons=" the rewrite failed on a well-formed .pc."
grep -q '^Libs: -L/x -lprobe -lstdc++$' "$_probe" \
  || _reasons="$_reasons Libs: was not appended to: $(sed -n 2p "$_probe")"
grep -q '^Libs.private: -lm$' "$_probe" \
  || _reasons="$_reasons Libs.private was touched: $(sed -n 3p "$_probe")"
# Idempotent, which the `!/-lstdc\+\+/` guard is for: post_install runs again on
# a rebuild that did not reinstall the .pc. grep -o, not grep -c: -c counts
# matching LINES, so a doubled "-lstdc++ -lstdc++" on one line still counts 1.
_drive mf_pc_add_stdcxx probe '' || _reasons="$_reasons the second application failed."
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
_drive mf_pc_static_libgcc gprobe '-static' || _reasons=" the rewrite failed under LDEXEFLAGS."
grep -q '^Libs: -lfoo -lgcc_eh$' "$_g" \
  || _reasons="$_reasons under LDEXEFLAGS the unwinder was not swapped: $(sed -n 2p "$_g")"
printf 'Name: gprobe\nLibs: -lfoo -lgcc_s\n' > "$_g"
_before=$(cat "$_g")
_drive mf_pc_static_libgcc gprobe '' || _reasons="$_reasons the empty-LDEXEFLAGS call failed."
[ "$(cat "$_g")" = "$_before" ] \
  || _reasons="$_reasons with LDEXEFLAGS empty it rewrote anyway: $(sed -n 2p "$_g")"
_verdict libgcc-swap-is-gated-on-ldexeflags "$_reasons"

printf 'DONE: pc-rewrite-single-entry\n'
exit "$_fail"
