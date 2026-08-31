#!/bin/sh
# A manifest built from a walk that failed is a manifest that under-records,
# forever (GH-80).
#
# lib/stage.sh enumerated the stage as `find ... | sed`, where the status
# belongs to sed and the `2>/dev/null` removes the only other evidence, so a
# subtree find could not descend was dropped from the stamp in silence. GH-77
# had the same shape in the unclaimed audit and fixed it there; the consequence
# is not the same on this side. The audit recomputes its answer on every run and
# says when it is a lower bound. A stamp is written once and nothing ever
# re-derives it: it reads `verified` while vouching for less than the recipe
# installed, and hands that same audit a pile of files no stamp claims --
# findings the audit manufactured itself, shaped exactly like the real ones it
# exists to surface. So staging FAILS THE RECIPE where the audit degrades, and
# that difference in policy over a shared mechanism is what this file pins.
#
# TWO fixtures, because they reach two different failures and only one of them
# is portable:
#
#   a STUB find that prints part of the tree and exits nonzero, which is the
#   only way to separate a failed walk from a failed merge -- an unreadable
#   directory stops `tar c` exactly as it stops find, so the real-permission
#   fixture cannot show what the walk alone contributes;
#   a real mode-000 DIRECTORY, which shows the fix firing on the failure an
#   operator actually meets, and is skipped-as-failed under a UID that ignores
#   the permission bit.
#
# lib/stage.sh is sourced under a guard for the reason tests/stamp-reconcile.sh
# gives: an unguarded source under `set -e` aborts before the DONE sentinel that
# tests/oracle-baseline.sh reads as proof the file ran at all.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

_tmp=$(mktemp -d) || exit 1
# chmod before rm: the mode-000 directory below is unreadable to the trap too,
# and `rm -rf` on it fails silently enough to leave the fixture behind.
trap 'chmod -R u+rwX "$_tmp" 2>/dev/null; rm -rf "$_tmp"' EXIT
_cleanup_on_signal

# --- the mechanism, read from source ---------------------------------------
#
# The extraction is half the fix and it is invisible to the behavioural
# assertions below: fixing the staging walk in place would pass every one of
# them while leaving two spellings of "walk a tree, carry the status" to drift
# apart, which is the state GH-80 was filed against.
_defs=$(_lib_code | grep -c 'mf_stage_walk_files() {' || true)
if [ "$_defs" = 1 ]; then
  _pass walk-mechanism-defined-once
else
  _bad walk-mechanism-defined-once "expected exactly one mf_stage_walk_files definition under lib/, found $_defs"
fi

# Both call sites ON it, not merely near it. Statement-scoped to the functions
# that own each walk, because a mention anywhere else in either file would
# satisfy a whole-file grep while the walk itself stayed hand-rolled.
_commit=$(_fn_body lib/stage.sh mf_stage_commit | _code_only -)
_audit=$(_fn_body mediaforge.sh _reconcile_unclaimed | _code_only -)
_missing=''
printf '%s\n' "$_commit" | grep -q 'mf_stage_walk_files' || _missing="mf_stage_commit"
printf '%s\n' "$_audit"  | grep -q 'mf_stage_walk_files' || _missing="$_missing _reconcile_unclaimed"
if [ -z "$_missing" ]; then
  _pass both-walks-share-the-mechanism
else
  _bad both-walks-share-the-mechanism "still hand-rolling the walk:$_missing"
fi

# --- the behaviour ---------------------------------------------------------
if [ -f "$ROOT/lib/stage.sh" ]; then
  PREFIX="$_tmp/prefix"
  SCRIPT_DIR="$ROOT"
  mkdir -p "$PREFIX"
  # shellcheck source=lib/utils.sh
  . "$ROOT/lib/utils.sh"

  # A find that reports PART of the tree and then fails, which is what an
  # unreadable subdirectory does to the real one. Resolved to an absolute path
  # first, so the stub cannot recurse into itself once it is on PATH.
  _real_find=$(command -v find)
  mkdir -p "$_tmp/bin"
  cat > "$_tmp/bin/find" <<STUB
#!/bin/sh
"$_real_find" "\$@" 2>/dev/null | head -2
exit 1
STUB
  chmod 0755 "$_tmp/bin/find"

  # Four files, so a truncated walk is distinguishable from a complete one by
  # COUNT and not only by which paths it names.
  mf_stage_pending_reset
  mf_stage_begin
  _stage=$(mf_stage_dir)$PREFIX
  mkdir -p "$_stage/lib" "$_stage/include"
  echo a > "$_stage/lib/libprobe.a"
  echo b > "$_stage/lib/libprobe2.a"
  echo c > "$_stage/include/probe.h"
  echo d > "$_stage/include/probe2.h"

  # stamp_write is inside the subshell deliberately: on a tree where the walk's
  # failure is dropped, the commit returns 0 and the stamp is written SHORT,
  # which is the defect. Where the failure is carried, die ends the subshell and
  # no stamp is written at all.
  _out=$( { PATH="$_tmp/bin:$PATH"; export PATH
            mf_stage_commit && stamp_write probe 1.0; } 2>&1 ) && _rc=0 || _rc=$?

  if [ "$_rc" != 0 ]; then
    _pass truncated-walk-fails-the-recipe
  else
    _bad truncated-walk-fails-the-recipe "a walk that reported failure was treated as a complete enumeration (exit=$_rc) $(printf '%s' "$_out" | _evidence 2 'FATAL|manifest')"
  fi

  _stamped=0
  [ -f "$PREFIX/.stamps/probe-1.0" ] && _stamped=$(grep -c . "$PREFIX/.stamps/probe-1.0" || true)
  if [ "$_stamped" = 0 ]; then
    _pass truncated-walk-writes-no-short-manifest
  else
    _bad truncated-walk-writes-no-short-manifest "a stamp claims $_stamped of the 4 staged files, and nothing ever re-derives it"
  fi

  # Nothing merged, because the walk runs BEFORE the tar pipe and the failure is
  # the recipe's. A merge that went ahead would leave files in the prefix that
  # no stamp names -- the audit's own findings, manufactured by the build.
  _merged=0
  for _m in lib/libprobe.a lib/libprobe2.a include/probe.h include/probe2.h; do
    if [ -e "$PREFIX/$_m" ]; then _merged=$((_merged + 1)); fi
  done
  if [ "$_merged" = 0 ]; then
    _pass truncated-walk-merges-nothing
  else
    _bad truncated-walk-merges-nothing "$_merged staged file(s) reached $PREFIX under a walk that failed"
  fi
  mf_stage_end
  mf_stage_pending_reset

  # The failure an operator actually meets: a directory the walk cannot descend.
  # Message-scoped rather than state-scoped, because `tar c` fails on the same
  # directory -- on a tree without the fix the commit still dies, at the merge,
  # having merged whatever it streamed first. WHICH failure is reported is the
  # whole difference, and it is the difference between "rebuild" and "delete
  # your prefix and rebuild".
  PREFIX="$_tmp/prefix2"
  mkdir -p "$PREFIX"
  mf_stage_begin
  _stage=$(mf_stage_dir)$PREFIX
  mkdir -p "$_stage/lib/locked"
  echo secret > "$_stage/lib/locked/hidden.a"
  chmod 000 "$_stage/lib/locked"
  if [ "$(id -u)" = 0 ] || find "$_stage" >/dev/null 2>&1; then
    chmod 755 "$_stage/lib/locked" 2>/dev/null || true
    _bad unreadable-subtree-fails-the-manifest "fixture unavailable: the directory stayed readable after chmod 000 (running as root?)"
  else
    _out=$( (mf_stage_commit) 2>&1 ) && _rc=0 || _rc=$?
    chmod 755 "$_stage/lib/locked" 2>/dev/null || true
    if [ "$_rc" != 0 ] && printf '%s' "$_out" | grep -q 'under-record'; then
      _pass unreadable-subtree-fails-the-manifest
    else
      _bad unreadable-subtree-fails-the-manifest "the manifest walk did not report the unreadable subtree (exit=$_rc) $(printf '%s' "$_out" | _evidence 2 'FATAL|merge')"
    fi
  fi
  mf_stage_end
  mf_stage_pending_reset
else
  _bad walk-behaviour-unavailable "lib/stage.sh is absent, so the staged manifest walk cannot be driven"
fi

printf 'DONE: stage-manifest-walk\n'
exit "$_fail"
