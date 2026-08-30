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

# One stub for all three drivers below. lib/framework.sh defines no die() and
# sources nothing when loaded, so this survives into each subshell -- three
# copies of it was the shape this whole file exists to argue against.
# shellcheck disable=SC2329
die() { printf 'DIED %s\n' "$*"; exit 3; }

_tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$_tmp"' EXIT
_cleanup_on_signal

# --- no recipe rewrites a .pc by hand any more ------------------------------
# Read through _code_only: this repo quotes the old idiom in prose, including in
# the helper's own doc block, so an unstripped grep answers "what does the tree
# SAY" when the question is "what does it DO".
_offenders=""
for _f in $(find recipes -name '*.sh' | sort); do
  _code_only "$_f" | grep -qE 'awk .*(lstdc|lgcc_s).*pkgconfig|_pc\.tmp' \
    && _offenders="$_offenders $_f"
done
_verdict pc-rewrites-go-through-the-helper "$_offenders"

# --- and the framework really defines them ----------------------------------
_reasons=""
for _fn in mf_pc_rewrite mf_pc_add_stdcxx mf_pc_static_libgcc; do
  _code_only lib/framework.sh | grep -qE "^$_fn\(\)" || _reasons="$_reasons lib/framework.sh defines no $_fn."
done
_verdict pc-helpers-are-defined "$_reasons"

# --- the missing-.pc path DIES rather than passing silently -----------------
# The one property none of the eight copies had. Driven for real: a prefix with
# no pkgconfig dir at all, and a stub die() that records being reached.
_reasons=""
if ! _code_only lib/framework.sh | grep -qE '^mf_pc_rewrite\(\)'; then
  _reasons=" mf_pc_rewrite is not defined, so the silent path is still open."
else
  mkdir -p "$_tmp/prefix/lib/pkgconfig"
  if ( set -eu
       PREFIX="$_tmp/prefix"; PKG_NAME=probe
       # shellcheck source=/dev/null
       . "$ROOT/lib/framework.sh" 2>/dev/null || true
       mf_pc_rewrite absent '{print}' ) >"$_tmp/out" 2>&1; then
    _reasons=" rewriting a .pc that does not exist reported success."
  elif ! grep -q '^DIED' "$_tmp/out"; then
    _reasons=" a missing .pc failed without reaching die, so a recipe would carry on unfixed."
  fi
fi
_verdict missing-pc-is-fatal "$_reasons"

# --- and the rewrite itself still does what the copies did ------------------
_reasons=""
if _code_only lib/framework.sh | grep -qE '^mf_pc_add_stdcxx\(\)'; then
  printf 'Name: probe\nLibs: -L/x -lprobe\n' > "$_tmp/prefix/lib/pkgconfig/probe.pc"
  ( set -eu
    PREFIX="$_tmp/prefix"; PKG_NAME=probe
    # shellcheck source=/dev/null
    . "$ROOT/lib/framework.sh" 2>/dev/null || true
    mf_pc_add_stdcxx probe ) >>"$_tmp/out" 2>&1 || _reasons=" the rewrite failed on a well-formed .pc."
  grep -q '^Libs: -L/x -lprobe -lstdc++$' "$_tmp/prefix/lib/pkgconfig/probe.pc" \
    || _reasons="$_reasons Libs: was not appended to: $(sed -n 2p "$_tmp/prefix/lib/pkgconfig/probe.pc")"
  # Idempotent, which the `!/-lstdc\+\+/` guard is there for: pkg_post_install
  # runs again on a rebuild that did not reinstall the .pc.
  # shellcheck disable=SC2034
  ( set -eu
    PREFIX="$_tmp/prefix"; PKG_NAME=probe
    # shellcheck source=/dev/null
    . "$ROOT/lib/framework.sh" 2>/dev/null || true
    mf_pc_add_stdcxx probe ) >/dev/null 2>&1 || true
  # grep -o, not grep -c: -c counts matching LINES, so a doubled
  # "-lstdc++ -lstdc++" on one line still counts as 1 and the check passes.
  # Mutation-found -- removing the guard left this assertion green.
  _n=$(grep -o -- '-lstdc++' "$_tmp/prefix/lib/pkgconfig/probe.pc" | wc -l | tr -d ' ')
  [ "$_n" = 1 ] || _reasons="$_reasons applying it twice left $_n copies of -lstdc++."
else
  _reasons=" mf_pc_add_stdcxx is not defined."
fi
_verdict stdcxx-rewrite-is-correct-and-idempotent "$_reasons"

printf 'DONE: pc-rewrite-single-entry\n'
exit "$_fail"
