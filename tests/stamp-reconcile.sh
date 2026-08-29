#!/bin/sh
# Stamps are evidence, not claims (GH-59).
#
# A stamp used to be an empty file asserting that a recipe had been built, and
# nothing ever compared that assertion against the workspace. Both drift
# directions were reachable and neither was noticed: three stamps went missing
# while their libraries sat in workspace/lib for days, and the reverse -- a
# stamp outliving its artifact -- makes the next build SKIP a recipe it never
# built, so the failure lands at FFmpeg's configure or link step, nowhere near
# the recipe that caused it.
#
# Two halves are tested, and they need different fixtures:
#
#   the RECORDING half (lib/stage.sh) is driven by sourcing the library and
#   calling it against a fake prefix, because staging a real recipe means
#   building one;
#   the REPORTING half (reconcile) is driven through the real CLI against a
#   scratch workspace, because the exit status and the report ARE the interface.
#
# lib/stage.sh is sourced conditionally for the reason tests/ccache.sh and
# tests/storage-guard.sh give: on the merge base the file does not exist, and an
# unguarded source under `set -e` aborts before the DONE sentinel, which
# tests/oracle-baseline.sh reports as a crashed test rather than as the absent
# feature.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

_tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$_tmp"' EXIT
_cleanup_on_signal

# --- the wiring, read from source ------------------------------------------
#
# Cheap assertions that do not need a fixture, and that catch the failure mode
# the behavioural tests below cannot see: a correct lib/stage.sh that nothing
# calls.
_wired stage-sourced          lib/utils.sh     'lib/stage.sh'
_wired stamp-records-manifest lib/utils.sh     'mf_stage_pending_extant > '
_wired staging-wraps-install  lib/framework.sh 'mf_stage_begin'
_wired preflight-defined      mediaforge.sh    'mf_build_preflight_stamps() {'
_wired reconcile-dispatched   mediaforge.sh    'reconcile)      cmd_reconcile'
_wired reconcile-documented   mediaforge.sh    'reconcile          Check build stamps'
_wired stage-discarded-on-exit lib/cleanup.sh  'mf_stage_discard'

# The ORDER of the two commits around pkg_post_install, which is the whole
# reason staging is not simply folded into stamp_write. Thirteen recipes'
# post_install reads back or deletes a file pkg_install put in the live prefix;
# every one of them breaks if the merge waits for the stamp. A grep for
# "mf_stage_commit is called" cannot tell the working order from the broken one.
_ci=$(grep -n 'mf_stage_commit' lib/framework.sh | grep -v '^[0-9]*: *#' | head -1 | cut -d: -f1)
_pi=$(grep -n '^  pkg_post_install$' lib/framework.sh | head -1 | cut -d: -f1)
if [ -n "$_ci" ] && [ -n "$_pi" ] && [ "$_ci" -lt "$_pi" ]; then
  _pass commit-precedes-post-install
else
  _bad commit-precedes-post-install "expected a mf_stage_commit before pkg_post_install (commit=${_ci:-none} post_install=${_pi:-none})"
fi

# --- the recording half ----------------------------------------------------
if [ -f "$ROOT/lib/stage.sh" ]; then
  # A fake prefix, sourced with the two globals lib/stage.sh reads. No build is
  # involved: the library's contract is "merge what is in the stage, record what
  # came across", and a directory tree is a complete fixture for that.
  PREFIX="$_tmp/prefix"
  SCRIPT_DIR="$ROOT"
  mkdir -p "$PREFIX"
  # shellcheck source=lib/utils.sh
  . "$ROOT/lib/utils.sh"

  mf_stage_begin
  _stage="$DESTDIR$PREFIX"
  mkdir -p "$_stage/lib/pkgconfig" "$_stage/include"
  echo archive       > "$_stage/lib/libprobe.a"
  echo pc            > "$_stage/lib/pkgconfig/probe.pc"
  echo hdr           > "$_stage/include/probe.h"
  # A symlinked shared lib, because the merge is a tar pipe specifically so this
  # survives: POSIX leaves cp -R's symlink handling unspecified when none of
  # -H/-L/-P is given, and this must work on GNU and BSD userlands alike.
  echo so            > "$_stage/lib/libprobe.so.1.2.3"
  ln -s libprobe.so.1.2.3 "$_stage/lib/libprobe.so"
  chmod 0755 "$_stage/lib/libprobe.so.1.2.3"

  mf_stage_commit

  if [ -f "$PREFIX/lib/libprobe.a" ] && [ -f "$PREFIX/include/probe.h" ]; then
    _pass merge-lands-files-in-prefix
  else
    _bad merge-lands-files-in-prefix "staged files never reached $PREFIX"
  fi

  # Symlink AND mode in one assertion: both are properties the tar pipe exists
  # to preserve, and a merge that flattened either would corrupt the workspace
  # it is meant to protect.
  #
  # The executable bit BOTH ways: the 0755 library keeps it and the 0644 header
  # does not. Asserting only the first passes against a merge that chmods
  # everything executable, which is a plausible way to get modes wrong.
  if [ -L "$PREFIX/lib/libprobe.so" ] \
     && [ -x "$PREFIX/lib/libprobe.so.1.2.3" ] \
     && [ ! -x "$PREFIX/include/probe.h" ]; then
    _pass merge-preserves-symlink-and-mode
  else
    _bad merge-preserves-symlink-and-mode "link=$([ -L "$PREFIX/lib/libprobe.so" ] && echo yes || echo no) lib-exec=$([ -x "$PREFIX/lib/libprobe.so.1.2.3" ] && echo yes || echo NO) hdr-exec=$([ -x "$PREFIX/include/probe.h" ] && echo YES || echo no)"
  fi

  # The stage is emptied by a commit, so a second commit cannot re-record the
  # same files and inflate the next stamp with another package's manifest.
  mf_stage_commit
  _n=$(mf_stage_pending_extant | wc -l | tr -d ' ')
  if [ "$_n" = 5 ]; then
    _pass commit-drains-the-stage
  else
    _bad commit-drains-the-stage "expected 5 recorded paths after two commits, got $_n"
  fi

  # The existence filter, which is what makes a manifest SOUND. xevd, xeve,
  # brotli and xvidcore all delete in post_install a shared library their own
  # make install produced; a manifest naming a deliberately-removed file would
  # report as drift on every later reconcile -- a permanent false positive in
  # the one place a false positive is most expensive.
  rm -f "$PREFIX/lib/libprobe.so.1.2.3"
  if mf_stage_pending_extant | grep -q 'libprobe.so.1.2.3'; then
    _bad deleted-file-drops-from-manifest "a path removed after staging is still recorded"
  else
    _pass deleted-file-drops-from-manifest
  fi

  stamp_write probe 1.0
  if [ -s "$PREFIX/.stamps/probe-1.0" ]; then
    _pass stamp-carries-the-manifest
  else
    _bad stamp-carries-the-manifest "stamp_write left an empty stamp despite staged files"
  fi
  if [ -z "$(mf_stage_pending_extant)" ]; then
    _pass stamp-drains-the-accumulator
  else
    _bad stamp-drains-the-accumulator "the accumulator survived stamp_write, so the next stamp would inherit these files"
  fi

  # A recipe that deletes what it just installed, in the SAME phase.
  # recipes/video/xeve.sh and recipes/video/xevd.sh both call default_install
  # and then `rm -f "$PREFIX/lib/libxeve.so"` to drop the shared library
  # upstream ships beside the static one. If the install is still sitting in the
  # stage when the rm runs, the rm matches nothing and the merge publishes the
  # .so anyway -- so FFmpeg's static link can resolve against a shared library
  # the recipe explicitly removed. The ordering below is what default_install
  # guarantees by committing before it returns.
  mf_stage_begin
  _stage="$DESTDIR$PREFIX"
  mkdir -p "$_stage/lib"
  echo shared > "$_stage/lib/libunwanted.so"
  echo static > "$_stage/lib/libwanted.a"
  mf_stage_commit                      # what default_install now does
  rm -f "$PREFIX/lib/libunwanted.so"   # what the recipe does next
  mf_stage_commit                      # the framework's own commit, after the phase
  if [ ! -e "$PREFIX/lib/libunwanted.so" ] && [ -f "$PREFIX/lib/libwanted.a" ]; then
    _pass recipe-can-delete-what-it-just-installed
  else
    _bad recipe-can-delete-what-it-just-installed "unwanted=$([ -e "$PREFIX/lib/libunwanted.so" ] && echo PUBLISHED || echo gone) wanted=$([ -f "$PREFIX/lib/libwanted.a" ] && echo kept || echo MISSING)"
  fi
  # And the deleted file must not linger in the manifest either, or every later
  # reconcile reports drift for a file the recipe meant to remove.
  if mf_stage_pending_extant | grep -q 'libunwanted.so'; then
    _bad deleted-install-drops-from-manifest "the removed .so is still recorded"
  else
    _pass deleted-install-drops-from-manifest
  fi
  mf_stage_pending_reset

  # default_install must be the thing that guarantees it, not the caller. A
  # recipe author writing `default_install; rm "$PREFIX/x"` has no reason to
  # suspect staging exists.
  #
  # Anchored to a STATEMENT, not a mention. The first spelling of this grep was
  # a bare needle, and the explanatory comment inside default_install contains
  # the word -- so deleting the call left the assertion green (mutation-verified).
  if _fn_body lib/framework.sh default_install | grep -qE '^[[:space:]]*mf_stage_commit[[:space:]]*$'; then
    _pass default-install-publishes-before-returning
  else
    _bad default-install-publishes-before-returning "default_install returns without committing the stage"
  fi

  # A recipe that stages nothing -- gsm, ladspa and amf install with a bare
  # shell cp, which DESTDIR does not redirect -- must still get a stamp, and an
  # EMPTY one. That is the "unverifiable" signal, and it is also every stamp
  # written before this change.
  stamp_write shellcp 2.0
  if [ -f "$PREFIX/.stamps/shellcp-2.0" ] && [ ! -s "$PREFIX/.stamps/shellcp-2.0" ]; then
    _pass empty-manifest-still-stamps
  else
    _bad empty-manifest-still-stamps "a recipe that stages nothing must still be stamped, with an empty manifest"
  fi
  mf_stage_end
else
  _bad merge-lands-files-in-prefix "lib/stage.sh does not exist"
  _bad merge-preserves-symlink-and-mode "lib/stage.sh does not exist"
  _bad commit-drains-the-stage "lib/stage.sh does not exist"
  _bad deleted-file-drops-from-manifest "lib/stage.sh does not exist"
  _bad stamp-carries-the-manifest "lib/stage.sh does not exist"
  _bad stamp-drains-the-accumulator "lib/stage.sh does not exist"
  _bad empty-manifest-still-stamps "lib/stage.sh does not exist"
fi

# --- the reporting half, through the real CLI ------------------------------
#
# A workspace built by hand: reconcile reads .stamps and the prefix, and knows
# nothing about how either got there.
_ws="$_tmp/topdir"
mkdir -p "$_ws/workspace/.stamps" "$_ws/workspace/lib/pkgconfig"

_reconcile() { ( cd "$_ws" && "$ROOT/mediaforge.sh" reconcile "$@" 2>&1 ); }

# Clean: one stamp, its file present.
echo lib > "$_ws/workspace/lib/libclean.a"
printf 'lib/libclean.a\n' > "$_ws/workspace/.stamps/clean-1.0"
_out=$(_reconcile) && _rc=0 || _rc=$?
if [ "$_rc" = 0 ]; then
  _pass clean-workspace-exits-zero
else
  _bad clean-workspace-exits-zero "$(printf '%s' "$_out" | _evidence 3 'DRIFT|FATAL')"
fi

# Drifted: the stamp names a file that is gone. This is the direction worth a
# gate -- the next build would skip the recipe without building it.
printf 'lib/libgone.a\n' > "$_ws/workspace/.stamps/gone-2.0"
_out=$(_reconcile) && _rc=0 || _rc=$?
if [ "$_rc" != 0 ] && printf '%s' "$_out" | grep -q 'DRIFTED'; then
  _pass drift-is-reported-and-fails
else
  _bad drift-is-reported-and-fails "exit=$_rc $(printf '%s' "$_out" | _evidence 3 'DRIFT|verified')"
fi

# An empty stamp is "no evidence", never "evidence of a problem". Every stamp
# written before GH-59 is empty; reporting those as drift would be a false
# positive on a majority of a legacy workspace.
printf '' > "$_ws/workspace/.stamps/legacy-3.0"
_out=$(_reconcile)  || true
if printf '%s' "$_out" | grep -q 'unverifiable.*legacy-3.0'; then
  _pass empty-stamp-is-unverifiable-not-drift
else
  _bad empty-stamp-is-unverifiable-not-drift "$(printf '%s' "$_out" | _evidence 3 'legacy|unverifiable')"
fi

# --prune removes exactly the drifted stamp. The "and no others" half is what
# stops a prune that simply empties .stamps from passing.
_out=$(_reconcile --prune) || true
if [ ! -f "$_ws/workspace/.stamps/gone-2.0" ] \
   && [ -f "$_ws/workspace/.stamps/clean-1.0" ] \
   && [ -f "$_ws/workspace/.stamps/legacy-3.0" ]; then
  _pass prune-removes-only-the-drifted
else
  _bad prune-removes-only-the-drifted "gone=$([ -f "$_ws/workspace/.stamps/gone-2.0" ] && echo kept || echo pruned) clean=$([ -f "$_ws/workspace/.stamps/clean-1.0" ] && echo kept || echo PRUNED) legacy=$([ -f "$_ws/workspace/.stamps/legacy-3.0" ] && echo kept || echo PRUNED)"
fi

# After the prune the workspace is consistent again, which is the point of the
# prune: the next build redoes exactly the pruned recipe.
_out=$(_reconcile) && _rc=0 || _rc=$?
if [ "$_rc" = 0 ]; then
  _pass prune-restores-a-clean-verdict
else
  _bad prune-restores-a-clean-verdict "exit=$_rc $(printf '%s' "$_out" | _evidence 3 'DRIFT')"
fi

# The other direction: an artifact present with no stamp. Advisory only -- the
# issue calls it "wasteful, not incorrect" -- so it is reported and does not
# change the exit status.
echo pc > "$_ws/workspace/lib/pkgconfig/x264.pc"
_out=$(_reconcile) || true
if printf '%s' "$_out" | grep -q 'lost stamp.*x264'; then
  _pass artifact-without-stamp-is-reported
else
  _bad artifact-without-stamp-is-reported "$(printf '%s' "$_out" | _evidence 3 'lost|x264')"
fi

# --- the preflight, driven through a real build ----------------------------
#
# Behavioural, not a grep. A `_wired` needle for mf_build_preflight_stamps is
# satisfied by the function's own DEFINITION, so deleting the CALL from
# cmd_build left every other assertion in this file green -- mutation-verified,
# and the same trap tests/storage-guard.sh records for its own guard. What the
# preflight claims is that a build DROPS a drifted stamp before it starts, so
# that is what gets asserted.
#
# --dry-run because the claim is about the preflight, which runs before the
# recipe loop; a dry run reaches it, downloads nothing, and is exempt from the
# tmpfs guard that would otherwise refuse a build from a /tmp scratch dir.
_pf="$_tmp/preflight"
mkdir -p "$_pf/workspace/.stamps" "$_pf/workspace/lib"
echo lib > "$_pf/workspace/lib/libkept.a"
printf 'lib/libkept.a\n'  > "$_pf/workspace/.stamps/kept-1.0"
printf 'lib/libvanished.a\n' > "$_pf/workspace/.stamps/vanished-1.0"
printf '' > "$_pf/workspace/.stamps/legacy-1.0"

_pf_out=$( cd "$_pf" && "$ROOT/mediaforge.sh" build --dry-run --yes 2>&1 ) || true
if [ ! -f "$_pf/workspace/.stamps/vanished-1.0" ] \
   && [ -f "$_pf/workspace/.stamps/kept-1.0" ] \
   && [ -f "$_pf/workspace/.stamps/legacy-1.0" ]; then
  _pass build-preflight-drops-drifted-stamps
else
  _bad build-preflight-drops-drifted-stamps "vanished=$([ -f "$_pf/workspace/.stamps/vanished-1.0" ] && echo KEPT || echo dropped) kept=$([ -f "$_pf/workspace/.stamps/kept-1.0" ] && echo kept || echo DROPPED) legacy=$([ -f "$_pf/workspace/.stamps/legacy-1.0" ] && echo kept || echo DROPPED) $(printf '%s' "$_pf_out" | _evidence 2 'stamp|drift')"
fi

printf 'DONE: stamp-reconcile\n'
exit "$_fail"
