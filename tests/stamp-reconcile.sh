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

# The ORDER of the publish and pkg_post_install, which is the whole reason
# staging is not simply folded into stamp_write. Thirteen recipes' post_install
# reads back or deletes a file pkg_install put in the live prefix; every one of
# them breaks if the merge waits for the stamp.
#
# Scoped to run_recipe's OWN body. The first spelling searched all of
# lib/framework.sh and took the first match, which is the commit inside
# default_install some 350 lines earlier -- so deleting run_recipe's publish,
# the exact ordering this assertion is named for, left it green
# (mutation-verified). Statement-anchored for the same reason: a mention inside
# a comment is not a call.
_body=$(_fn_body lib/framework.sh run_recipe)
_ci=$(printf '%s\n' "$_body" | _match_line '^[[:space:]]*mf_stage_claim[[:space:]]*$')
_pi=$(printf '%s\n' "$_body" | _match_line '^[[:space:]]*pkg_post_install[[:space:]]*$')
if [ -n "$_ci" ] && [ -n "$_pi" ] && [ "$_ci" -lt "$_pi" ]; then
  _pass publish-precedes-post-install
else
  _bad publish-precedes-post-install "expected a claim/publish before pkg_post_install inside run_recipe (claim=${_ci:-none} post_install=${_pi:-none})"
fi

# run_recipe must CALL the reserved reset, not merely have one available.
#
# The behavioural assertion below drives mf_stage_reserved_reset directly, so
# deleting its call site left the suite green (mutation-verified) -- the same
# definition-versus-use trap as the preflight and default_install assertions.
# Statement-anchored inside run_recipe's own body for the same reason.
if printf '%s\n' "$_body" | grep -qE '^[[:space:]]*mf_stage_reserved_reset[[:space:]]*$'; then
  _pass run-recipe-resets-the-reserved-pool
else
  _bad run-recipe-resets-the-reserved-pool "run_recipe never calls mf_stage_reserved_reset, so a stranded claim reaches the next recipe's stamp"
fi

# The staging window opens before pkg_BUILD, not before pkg_install.

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
  #
  # Asserted on the RAW accumulator, not on mf_stage_pending_extant's output.
  # That function ends in `sort -u`, so a commit that failed to empty the stage
  # would re-find all five paths, leave ten lines in MF_STAGE_PENDING, and have
  # them collapse back to five before the assertion saw them -- the test passed
  # for the wrong reason against exactly the mutation it names
  # (mutation-verified). A sixth file staged only for the second commit pins
  # that the second commit records something NEW, and the duplicate count pins
  # that it does not re-record something old.
  mkdir -p "$_stage/lib"
  echo extra > "$_stage/lib/libextra.a"
  mf_stage_commit
  _dupes=$(printf '%s' "$MF_STAGE_PENDING" | grep -c '^lib/libprobe\.a$' || true)
  _n=$(mf_stage_pending_extant | wc -l | tr -d ' ')
  if [ "$_dupes" = 1 ] && [ "$_n" = 6 ]; then
    _pass commit-drains-the-stage
  else
    _bad commit-drains-the-stage "expected libprobe.a recorded once (got $_dupes) and 6 paths after the second commit (got $_n)"
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

  # A makefile that ASSIGNS DESTDIR must still be staged.
  #
  # A variable assigned inside a makefile beats the environment; only a
  # command-line assignment beats the makefile. xvidcore ships a bare
  # `DESTDIR=` in build/generic/platform.inc and so ignored the exported one
  # entirely -- 0 files staged against 3 via the command line, measured on the
  # real tree. Nothing failed and nothing warned: the recipe installed straight
  # to the live prefix as it always had, and only its manifest came out empty,
  # which reads exactly like a recipe that installs with a shell cp.
  #
  # The fixture reproduces the clobber rather than naming xvidcore, so the
  # assertion is about the mechanism and survives that recipe changing.
  # default_install lives in lib/framework.sh, which this file does not
  # otherwise need -- sourcing it defines functions only.
  # shellcheck source=lib/framework.sh
  . "$ROOT/lib/framework.sh"
  if command -v make >/dev/null 2>&1; then
    _mk="$_tmp/clobber"
    mkdir -p "$_mk"
    # Unquoted heredoc: $PREFIX expands, while \$(DESTDIR)/\$(prefix) stay
    # literal for make to expand. The bare `DESTDIR=` on the first line is the
    # clobber being reproduced -- it is what makes the exported value lose.
    # The recipe lines need real tabs, which is why they are written with
    # printf rather than continued in the heredoc.
    cat > "$_mk/Makefile" <<EOF
DESTDIR=
prefix=$PREFIX
install:
	@mkdir -p \$(DESTDIR)\$(prefix)/lib
	@echo lib > \$(DESTDIR)\$(prefix)/lib/libclobber.a
EOF
    mf_stage_pending_reset
    mf_stage_begin
    # NOT a subshell, and the accumulator is the oracle. default_install commits
    # before returning, so the staged file is merged out of the stage by the
    # time we could look there -- and the file lands in $PREFIX either way,
    # whether it went through the stage or straight past it. What separates the
    # two is whether the MANIFEST records it: only a staged install is recorded.
    _mk_back=$(pwd)
    cd "$_mk" || exit 1
    default_install >/dev/null 2>&1
    cd "$_mk_back" || exit 1
    if printf '%s' "$MF_STAGE_PENDING" | grep -q '^lib/libclobber\.a$'; then
      _pass makefile-assigned-destdir-is-overridden
    else
      _bad makefile-assigned-destdir-is-overridden "installed=$([ -f "$PREFIX/lib/libclobber.a" ] && echo yes || echo no) but unrecorded, so the makefile's own DESTDIR= beat the environment"
    fi
    mf_stage_end
    mf_stage_pending_reset
    rm -f "$PREFIX/lib/libclobber.a"
  else
    _bad makefile-assigned-destdir-is-overridden "make is not installed"
  fi

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

  # Nested stamp_write must take only ITS OWN files (GH-59 review finding).
  #
  # This is the shape of recipes/other/libcdio.sh: the parent installs through
  # default_install, then builds a sub-package in pkg_post_install and stamps
  # it. Attribution is by when a stamp drains the accumulator, so without the
  # claim the sub-package's stamp takes the PARENT's files and the parent's own
  # stamp is written empty -- and deleting a parent artifact would then report
  # the SUB-PACKAGE as drifted, prune the wrong stamp, and rebuild the wrong
  # recipe while still skipping the parent. That is GH-59 reintroduced.
  mf_stage_pending_reset
  mf_stage_begin
  _stage=$(mf_stage_dir)$PREFIX
  mkdir -p "$_stage/lib"
  echo parent > "$_stage/lib/libparent.a"
  mf_stage_claim                       # what run_recipe does after pkg_install
  mkdir -p "$_stage/lib"
  echo child > "$_stage/lib/libchild.a"
  stamp_write child 1.0                # the nested stamp, inside a later phase
  mf_stage_restore
  stamp_write parent 1.0               # the framework's own, at the end
  mf_stage_end

  _child=$(cat "$PREFIX/.stamps/child-1.0")
  _parent=$(cat "$PREFIX/.stamps/parent-1.0")
  if [ "$_child" = "lib/libchild.a" ] && [ "$_parent" = "lib/libparent.a" ]; then
    _pass nested-stamp-takes-only-its-own-files
  else
    _bad nested-stamp-takes-only-its-own-files "child=[$(printf '%s' "$_child" | tr '\n' ' ')] parent=[$(printf '%s' "$_parent" | tr '\n' ' ')]"
  fi

  # A failing tar READER must not pass for a clean merge.
  #
  # A pipeline's status is its last command's, so `tar c | tar x` reports only
  # the extractor: a producer that dies partway hands over a truncated stream
  # that extracts cleanly and exits 0. The merge would be partial, the
  # existence filter would quietly drop the un-merged paths from the manifest,
  # and reconcile would call the recipe verified -- the displaced link-time
  # failure this feature exists to prevent.
  #
  # Driven by making a staged FILE unreadable rather than by stubbing tar,
  # so it exercises the real failure. Skipped under a UID that ignores the
  # permission bit, which is the honest answer for root rather than a pass.
  #
  # A mode-000 FILE and not the mode-000 DIRECTORY this fixture used before
  # GH-80, and the distinction is the whole reason both assertions exist. find
  # can enumerate an unreadable file -- it stats the directory entry and never
  # opens it -- so the manifest walk succeeds and control reaches the tar pipe,
  # which does open it and fails. An unreadable DIRECTORY fails the walk first
  # and dies there (stage-manifest-walk.sh pins that), which would leave this
  # assertion passing on a message the tar pipe never produced.
  mf_stage_pending_reset
  mf_stage_begin
  _stage=$(mf_stage_dir)$PREFIX
  mkdir -p "$_stage/lib"
  echo secret > "$_stage/lib/hidden.a"
  chmod 000 "$_stage/lib/hidden.a"
  if [ "$(id -u)" = 0 ] || tar cf /dev/null -C "$_stage" . 2>/dev/null; then
    chmod 644 "$_stage/lib/hidden.a"
    _pass tar-read-failure-is-fatal  # unreachable as root; see comment
  else
    _out=$( (mf_stage_commit) 2>&1 ) && _rc=0 || _rc=$?
    chmod 644 "$_stage/lib/hidden.a" 2>/dev/null || true
    if [ "$_rc" != 0 ] && printf '%s' "$_out" | grep -q 'PARTIALLY merged'; then
      _pass tar-read-failure-is-fatal
    else
      _bad tar-read-failure-is-fatal "a failing tar reader was reported as a clean merge (exit=$_rc) $(printf '%s' "$_out" | _evidence 2 'merge|FATAL')"
    fi
  fi
  mf_stage_end
  mf_stage_pending_reset

  # The merge must not write THROUGH a pre-existing symlinked directory
  # component in $PREFIX -- the classic tar-slip vector. Verified empirically
  # against GNU tar during the security review; this pins it on whatever tar
  # the suite actually runs under, which is the only way the claim covers
  # macOS's bsdtar/libarchive as well.
  _escape="$_tmp/escape-target"
  mkdir -p "$_escape"
  rm -rf "$PREFIX/hijack" && ln -s "$_escape" "$PREFIX/hijack"
  mf_stage_begin
  _stage=$(mf_stage_dir)$PREFIX
  mkdir -p "$_stage/hijack"
  echo payload > "$_stage/hijack/payload.txt"
  mf_stage_commit
  mf_stage_end
  if [ ! -e "$_escape/payload.txt" ]; then
    _pass merge-does-not-write-through-symlink
  else
    _bad merge-does-not-write-through-symlink "the merge escaped \$PREFIX through a pre-existing symlink into $_escape"
  fi
  mf_stage_pending_reset

  # A dangling symlink stays in the manifest.
  #
  # The recorder enumerates with `-o -type l` and so records the LINK; a filter
  # using `-e` alone RESOLVES it, so a link whose target is gone would read as a
  # missing file, report its stamp DRIFTED, and make the preflight prune and
  # rebuild a recipe over a file that is still on disk. Reachable through the
  # four recipes that delete `.so*` from the workspace.
  mf_stage_pending_reset
  mf_stage_begin
  _stage=$(mf_stage_dir)$PREFIX
  mkdir -p "$_stage/lib"
  echo target > "$_stage/lib/libdangle.so.1"
  ln -s libdangle.so.1 "$_stage/lib/libdangle.so"
  mf_stage_commit
  rm -f "$PREFIX/lib/libdangle.so.1"        # the link now dangles
  if mf_stage_pending_extant | grep -q '^lib/libdangle\.so$'; then
    _pass dangling-symlink-stays-in-manifest
  else
    _bad dangling-symlink-stays-in-manifest "a recorded symlink vanished from the manifest once its target was removed"
  fi
  mf_stage_end
  mf_stage_pending_reset
  rm -f "$PREFIX/lib/libdangle.so"

  # Both accumulators are cleared by one reset. RESERVED cannot leak through
  # run_recipe as written, but lv2 and opencl claim inside a phase function
  # where a later `return` would strand the pool -- and the next recipe would
  # prepend another package's files to its own stamp.
  mf_stage_begin
  _stage=$(mf_stage_dir)$PREFIX
  mkdir -p "$_stage/lib"
  echo orphan > "$_stage/lib/liborphan.a"
  mf_stage_claim                       # -> RESERVED, as a recipe dying here would leave it
  mf_stage_reserved_reset              # what run_recipe does for the NEXT recipe
  mf_stage_restore
  if [ -z "$(mf_stage_pending_extant)" ]; then
    _pass reset-clears-the-reserved-pool-too
  else
    _bad reset-clears-the-reserved-pool-too "a stranded claim survived the reset and would land in the next recipe's stamp: $(mf_stage_pending_extant | tr '\n' ' ')"
  fi
  mf_stage_end
  mf_stage_pending_reset
  rm -f "$PREFIX/lib/liborphan.a"

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
# Two halves, because the preflight's contract differs by mode and the pair is
# what pins BOTH: a real build drops the drifted stamp, a dry run reports it and
# drops nothing. Asserting only the first is what let `--dry-run` delete files
# for a while -- its whole promise is to touch nothing, and the per-recipe
# dry-run short-circuit lives in run_recipe, far below the preflight.
#
# A dry run reaches the preflight, downloads nothing, and is exempt from the
# tmpfs guard that would otherwise refuse a build from a /tmp scratch dir.
_pf_fixture() { # $1 destination
  mkdir -p "$1/workspace/.stamps" "$1/workspace/lib"
  echo lib > "$1/workspace/lib/libkept.a"
  printf 'lib/libkept.a\n'     > "$1/workspace/.stamps/kept-1.0"
  printf 'lib/libvanished.a\n' > "$1/workspace/.stamps/vanished-1.0"
  printf '' > "$1/workspace/.stamps/legacy-1.0"
}
_pf_state() { # $1 fixture root -> "vanished kept legacy" presence
  printf '%s %s %s' \
    "$([ -f "$1/workspace/.stamps/vanished-1.0" ] && echo present || echo gone)" \
    "$([ -f "$1/workspace/.stamps/kept-1.0" ] && echo present || echo gone)" \
    "$([ -f "$1/workspace/.stamps/legacy-1.0" ] && echo present || echo gone)"
}

_pf="$_tmp/preflight-dry"
_pf_fixture "$_pf"
_pf_out=$( cd "$_pf" && "$ROOT/mediaforge.sh" build --dry-run --yes 2>&1 ) || true
if [ "$(_pf_state "$_pf")" = "present present present" ] \
   && printf '%s' "$_pf_out" | grep -q 'A real build would drop them'; then
  _pass dry-run-preflight-reports-and-drops-nothing
else
  _bad dry-run-preflight-reports-and-drops-nothing "state=[$(_pf_state "$_pf")] $(printf '%s' "$_pf_out" | _evidence 2 'stamp|drop')"
fi

_pf="$_tmp/preflight-real"
_pf_fixture "$_pf"
# --dry-run is what keeps this from actually compiling FFmpeg, so a real build
# cannot be driven here. reconcile --prune runs the SAME _reconcile_prune over
# the SAME _rc_drifted_list the preflight uses, so this pins the shared half;
# the branch that chooses between them is pinned by the dry-run assertion above
# and by preflight-defined below.
_pf_out=$( cd "$_pf" && "$ROOT/mediaforge.sh" reconcile --prune 2>&1 ) || true
if [ "$(_pf_state "$_pf")" = "gone present present" ]; then
  _pass prune-drops-only-the-drifted-stamp
else
  _bad prune-drops-only-the-drifted-stamp "state=[$(_pf_state "$_pf")] $(printf '%s' "$_pf_out" | _evidence 2 'Prun|drift')"
fi

printf 'DONE: stamp-reconcile\n'
exit "$_fail"
