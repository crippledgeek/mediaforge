#!/bin/sh
# Staged installs: build-system installs land in a scratch tree, are recorded,
# and are then merged into $PREFIX (GH-59).
#
# The point is evidence. A build stamp used to be an empty file asserting that a
# recipe had been built, and nothing ever compared that assertion against the
# workspace -- so a stamp could outlive the artifact it vouched for, and the next
# build would SKIP a recipe it had never built. The failure then surfaced at
# FFmpeg's configure or link step, nowhere near the recipe that caused it.
#
# This is the shape every prefix-sharing source-build system converged on:
# install into a staging dir, enumerate THAT tree for the file list, then merge.
# FreeBSD ports stages under STAGEDIR and records pkg-plist; pkgsrc uses DESTDIR
# and PLIST; Portage's image dir ${D} becomes CONTENTS; MacPorts destroots and
# builds file_map.db; Yocto records sstate manifests from ${D}. None of them
# infers what a package installed by inspecting the live prefix afterwards.
#
# Three mechanical properties make the retrofit possible without touching a
# single recipe. All three were probed rather than assumed:
#
#   1. DESTDIR is honoured from the ENVIRONMENT by GNU make, `cmake --install`
#      and `ninja install` alike, so one `export` redirects most of the tree's
#      installs. (CMake documents DESTDIR as an environment variable whose
#      "initial value is taken from the calling process environment"; Meson
#      documents `DESTDIR=/path meson install`; the GNU Coding Standards tell
#      Makefile authors never to set it themselves, i.e. it comes from outside.)
#
#      WITH ONE EXCEPTION, and it is the reason default_install passes DESTDIR
#      on the command line rather than relying on the export: a variable
#      ASSIGNED INSIDE A MAKEFILE beats the environment, and only a
#      command-line assignment beats the makefile. The GNU standards tell
#      authors not to assign it, and xvidcore does anyway -- a bare `DESTDIR=`
#      in build/generic/platform.inc. Measured on the same tree: 0 files staged
#      through the environment, 3 through the command line. The failure is
#      silent, because the recipe still installs correctly (straight to the live
#      prefix, as before staging existed) and only its manifest comes out empty,
#      which is indistinguishable from a recipe that genuinely installs with a
#      shell cp.
#   2. DESTDIR does NOT reach installed file CONTENTS. GNU: "Specifying DESTDIR
#      should not change the operation of the software in any way, so its value
#      should not be included in any file contents." That is what keeps a staged
#      .pc correct -- it records the REAL prefix while the file itself sits in
#      the stage.
#   3. DESTDIR does NOT redirect a plain shell `cp`/`mv`/`rm`/`>` aimed at an
#      absolute "$PREFIX/..." path. Such an install writes straight to the live
#      prefix and records nothing, which is what made this change a retrofit
#      rather than a rewrite: the recipes that installed that way kept working
#      untouched, and only their manifests came out empty.
#
#      PAST TENSE since GH-68. Every one of them now writes through
#      mf_dest_prefix below, and a recipe that reintroduces the shape is caught
#      by tests/staged-shell-installs.sh. The property itself is unchanged and
#      is why that guard has to exist.
#
# The merge uses a tar pipe, not `cp -R`. POSIX leaves cp's symlink handling
# UNSPECIFIED when none of -H/-L/-P is given ("it is unspecified which of -H,
# -L, or -P will be used as a default"), and this must work on both GNU and BSD
# userlands. GNU cp happens to preserve links; that is an implementation's
# choice, not a guarantee to build a workspace on.
#
# THE MANIFEST IS READ-ONLY EVIDENCE. Nothing in mediaforge deletes a path named
# by a stamp: `reconcile --prune` and the build preflight delete the STAMP FILE,
# always taken from a "$PREFIX/.stamps"/* glob and never from a manifest's
# contents. That is why the containment here is lighter than lib/install.sh's
# install manifest, which DOES drive real deletion and carries _enter_contained
# for it (lib/remove-listed-files.sh). A future change that makes a manifest
# path drive a delete or a write inherits none of that containment and must add
# it -- treat this paragraph as the reason it is safe to read a stamp with a
# bare `[ -e "$PREFIX/$path" ]` today, and the warning for when it stops being.

# The stage is a single directory per build step rather than one per package.
# DESTDIR prepends the whole absolute prefix path, so an install of $PREFIX/lib/x
# lands at $MF_STAGE_DIR$PREFIX/lib/x.
mf_stage_root() {
  printf '%s\n' "$PREFIX/.stage"
}

mf_stage_dir() {
  printf '%s\n' "$(mf_stage_root)/current"
}

# Where a recipe's OWN shell install should write (GH-68).
#
# Property 3 above is why this exists: DESTDIR redirects a build system's
# install target, and nothing else. A recipe that installs with `cp`, `install`
# or a redirect aimed at an absolute "$PREFIX/..." path writes straight past the
# stage, so it stages nothing, records nothing, and its stamp reports
# `unverifiable` forever -- honest, but unfalsifiable. A full workspace reported
# ten such stamps, eight of them recipes that install something (the other two,
# vaapi and waflib, install nothing and are right to record nothing). Counting
# empty stamps understates it: a recipe whose build system installs too can have
# a hand-copy go unrecorded inside a stamp that reads `verified`, which is how
# lib/libxeve.a and lib/libxevd.a were on disk and in no manifest. Writing
# through this function instead puts those files in the stage like any other
# install, and the merge carries them to the same paths they reached before.
#
# It is the destination only. A path that ends up in a file's CONTENTS -- a .pc
# prefix= line, meson's launcher -- keeps using $PREFIX directly, because
# DESTDIR must never reach contents (property 2). That split is the whole
# subtlety of using it: the file goes to the stage, the string inside it names
# the real prefix.
#
# `${DESTDIR:-}` because the phases are callable outside a staging window: the
# unset case yields $PREFIX and the pre-GH-59 behaviour exactly.
mf_dest_prefix() {
  printf '%s\n' "${DESTDIR:-}$PREFIX"
}

# Create directories under that destination, failing the build if it cannot.
#
# The step every by-hand install needs, because a freshly reset stage is empty
# where the live prefix had the directory already -- and it had drifted into
# five spellings across the recipes that need it: `mkdir -p` with a bespoke
# `|| die` (amf, VapourSynth), `run mkdir -p` (libressl), a bare `mkdir -p`
# (gsm, flite, meson), `install -d` (bzip2, quirc), and no directory step at
# all (ladspa, xeve, xevd, shaderc, lcevc, and bzip2's post_install). Only the
# first two report a failure. The last group is the one the stage changes: each
# relied on the live prefix already holding the directory, which a stage reset
# moments earlier never does.
#
# Deliberately NOT folded into mf_dest_prefix as an optional argument. That
# function is used in a command substitution, and die() inside one exits the
# SUBSHELL alone -- `_dest=$(mf_dest_prefix lib)` would hand the recipe an empty
# $_dest and carry on writing to /lib. A statement's die is the build's.
mf_dest_mkdir() { # $@ = $PREFIX-relative directories
  # An empty list is a mis-expansion, not a request to do nothing: `for` over it
  # returns 0, and the failure would surface later as the cp that had nowhere to
  # land. Making it the build's is this function's entire purpose.
  [ "$#" -gt 0 ] || die "mf_dest_mkdir: called with no directories"
  _st_root=$(mf_dest_prefix)
  for _st_d in "$@"; do
    mkdir -p "$_st_root/$_st_d" || die "Cannot create $_st_d under $_st_root"
  done
}

# Files staged and merged but not yet claimed by any stamp, newline-separated
# and $PREFIX-relative. Whichever stamp is written next takes them.
#
# `${VAR-}` rather than a bare assignment: lib/utils.sh sources this file, and
# anything that re-sources lib/utils.sh mid-run would otherwise wipe an
# accumulator the current recipe is still filling. Only lib/install.sh does that
# today, and only after every stamp is written, so the bug is unreachable -- but
# it is one call-site move away from being reachable and silent.
MF_STAGE_PENDING="${MF_STAGE_PENDING-}"

# Files claimed for the RECIPE'S OWN stamp, held out of reach of any nested
# stamp_write. See mf_stage_claim.
MF_STAGE_RESERVED="${MF_STAGE_RESERVED-}"

# Empty the stage and recreate it. Both the start of staging and the tail of
# every commit need exactly this, and they had a copy each.
mf_stage_reset() {
  [ -n "${PREFIX:-}" ] || return 0
  _st_dir=$(mf_stage_dir)
  rm -rf "$_st_dir"
  mkdir -p "$_st_dir" 2>/dev/null || die "Cannot create the staging dir at $_st_dir"
}

# Start staging: empty the stage and point DESTDIR at it.
#
# Exported, because that is the whole mechanism -- make, ninja and cmake each
# read DESTDIR from the environment, so nothing has to be threaded through a
# recipe's own install line.
mf_stage_begin() {
  [ -n "${PREFIX:-}" ] || die "mf_stage_begin: PREFIX is unset"
  mf_stage_reset
  DESTDIR=$(mf_stage_dir)
  export DESTDIR
}

# Stop staging, so anything after this point writes to the live prefix again.
mf_stage_end() {
  unset DESTDIR
  [ -n "${PREFIX:-}" ] || return 0
  rm -rf "$(mf_stage_dir)"
}

# Drop the whole staging area.
#
# Called from the EXIT trap, because a build that dies inside pkg_install leaves
# a partial staged tree behind and nothing else would ever remove it. Worth
# noting what that partial tree means: before staging, a failed install left its
# half-written files in the LIVE prefix, where the next build would link against
# them. Now they die with the stage, which is the better failure.
#
# The PREFIX guard is defence in depth, matching recipes/other/lcevc.sh's. This
# runs from a trap that fires even when the run died before PREFIX was
# validated, and the operation is `rm -rf` -- an unset PREFIX would aim it at
# "/.stage".
mf_stage_discard() {
  [ -n "${PREFIX:-}" ] || return 0
  rm -rf "$(mf_stage_root)" 2>/dev/null || true
}

# Walk trees for files and symlinks, carrying find's failure as this function's
# STATUS.
#
# Three callers ask the same question of three different trees -- mf_stage_commit
# enumerating the stage to build a manifest, mf_stage_warn_stray enumerating it
# again for what landed outside the prefix, and mediaforge.sh's
# _reconcile_unclaimed enumerating the prefix for what no stamp claims -- and all
# three need the property a pipeline structurally cannot give them: in
# `find ... | sed`, the status belongs to SED -- and where the caller also sends
# find's diagnostic to /dev/null, as the audit must, that removes the only other
# evidence that a subtree went unread. So the walk is a statement whose status is
# its own.
#
# What that status MEANS is the caller's to decide, and it is a different answer
# each time. Staging fails the recipe, because a manifest that under-records is
# permanent: nothing later re-derives it, and the audit then reports every
# unwalked file as claimed by no stamp -- manufacturing findings indistinguishable
# from the real ones it exists to surface. The audit reports a lower bound,
# because it is advisory and recomputed on every run. The stray warning reports
# the list it has and says the list is short, because those files were never
# going to be merged and failing a build over them would fail it for the wrong
# reason. Sharing the mechanism is what lets the three policies be deliberate
# rather than accidental.
#
# The PREDICATE is fixed at files-and-symlinks, which is what makes this one
# mechanism rather than a thin wrapper over find: the three callers must agree
# on what a manifest entry IS, for the reason mf_stage_filter_paths gives about
# recording the LINK rather than its resolution. A walk whose predicate is the
# caller's own question -- lib/install.sh's header list, lib/remove-listed-files.sh's
# _enumerate -- is a different mechanism and stays where it is.
#
# Roots are whatever the caller hands over -- absolute, or relative to its own
# CWD. Taking the directory as an argument and cd'ing here would need a subshell
# to contain the cd, and the two callers that need one already run inside a
# command substitution that is one.
#
# STDERR IS INHERITED, deliberately, and the redirection lives at the call site
# that wants it. Discarding find's diagnostic is right for the audit, whose
# output is a report an operator reads -- a raw `find: './lib/x': Permission
# denied` in the middle of it is the defect GH-77 fixed. It is wrong for a build,
# whose output is a log: the failing find already knows WHICH directory it could
# not read, and swallowing that here would make the die below name only the stage
# root and leave the operator to hunt for the one path in a tree of hundreds.
# Folding the audit's policy into the shared mechanism would impose it on both.
#
# NO ROOTS is not an error: `for` over an empty list runs nothing and reports
# success, which is what the audit's empty prefix means -- no non-dot entry, so
# nothing to walk. Deliberately unlike mf_dest_mkdir, whose empty list IS a
# mis-expansion; that function is about to create directories a later cp depends
# on, while this one is asked a question whose honest answer can be "nothing".
#
# `-print` is explicit because the expression has a `-o` in it: find's implied
# -print applies to the WHOLE expression only when none is given, and a later
# hand adding a term after the group would otherwise silently change what prints.
mf_stage_walk_files() { # $@ = root paths, absolute or relative to the caller's CWD
  _st_walk_st=0
  for _st_walk_root in "$@"; do
    find "$_st_walk_root" \( -type f -o -type l \) -print || _st_walk_st=1
  done
  return "$_st_walk_st"
}

# Merge the stage into $PREFIX and remember what came across.
#
# Called between pkg_install and pkg_post_install, again after
# pkg_post_install, from default_install, and from stamp_write. The first of
# those is load-bearing and is the reason this is not simply folded into
# stamp_write: thirteen recipes' pkg_post_install reads back or deletes a file
# that pkg_install just wrote to the live prefix -- nine rewrite or rename an
# installed .pc (chromaprint, srt, vmaf, openh264, vvenc, x265, xevd, xeve, and
# shaderc which renames one), brotli and xvidcore delete shared libraries make
# install produced, lcevc reads its own archives back, and libressl asserts
# libtls.pc exists. Merging only at the stamp would leave every one of those
# reading a path still sitting in the stage. (xevd and xeve delete a shared
# library too, but from pkg_install rather than post_install, which is what
# default_install's own commit covers.)
mf_stage_commit() {
  _st_dir=$(mf_stage_dir)
  _st_src="$_st_dir$PREFIX"

  # Reset on this branch too. Without it the stray tree survives into the next
  # commit within the same recipe -- and a default-install recipe commits three
  # times (default_install, and the claim after each install phase), so one
  # foreign-prefix recipe reported itself three times and read as three
  # separate incidents. The strays are discarded at mf_stage_end either way.
  if [ ! -d "$_st_src" ]; then
    mf_stage_warn_stray "$_st_dir" "$_st_src"
    mf_stage_reset
    return 0
  fi

  # Record BEFORE merging: the stage holds this step's files and nothing else,
  # which is the entire reason for staging. Enumerating $PREFIX after the merge
  # would be back to guessing which of thousands of files were ours.
  #
  # A subtree the walk cannot read FAILS THE RECIPE, and does so here -- before
  # the merge, so nothing has been carried into $PREFIX yet and the build can be
  # re-run once the permission is fixed. The alternative, recording the short
  # manifest and warning, was rejected for what a manifest IS: read-only evidence
  # that nothing ever re-derives. A stamp written short stays short for the life
  # of the workspace, reads `verified` while vouching for less than the recipe
  # installed, and hands reconcile's unclaimed audit a pile of files no stamp
  # claims -- findings the audit manufactured itself, shaped exactly like the
  # real ones. That is the displaced failure this whole feature exists to stop,
  # and a warning at build time does not survive to the reconcile that reports it.
  #
  # The status is the walk's own; see mf_stage_walk_files for why it cannot be a
  # pipeline's. The `|| die` on the assignment sees the SUBSHELL's status, which
  # is the cd's when the cd is what failed -- the case the old spelling dropped
  # along with find's.
  _st_walk=$(cd "$_st_src" 2>/dev/null && mf_stage_walk_files .) \
    || die "Cannot read the staged install at $_st_src, so the manifest would under-record what this recipe installed. Nothing has been merged into $PREFIX; fix the permissions on the staged tree and rebuild."
  _st_new=$(printf '%s\n' "$_st_walk" | sed 's|^\./||')

  # Merge on the DIRECTORY existing, not on _st_new being non-empty: an install
  # that creates only directories (an empty include/foo/) has no files to record
  # and still has a tree to carry across. The manifest stays files-and-symlinks
  # only, because a directory is not an artifact anything links against.
  #
  # A pipeline's exit status is its LAST command's, so `|| die` on the pipe
  # below sees `tar x` alone. A `tar c` that dies partway -- an unreadable
  # staged file (`install -m 000` upstream), an EIO, a "file changed as we read
  # it" -- would hand `tar x` a truncated stream that extracts cleanly and exits
  # 0. The result would be a PARTIAL merge that the existence filter then hides,
  # by dropping the un-merged files from the manifest and reporting the recipe
  # verified. That is the displaced link-time failure this whole feature exists
  # to prevent, so the producer's failure is captured in a flag file instead.
  # `set -o pipefail` is not available: it is not in POSIX sh and dash lacks it.
  #
  # The flag lives under the stage ROOT rather than the stage dir, because the
  # dir is removed by mf_stage_reset at the end of this function.
  _st_flag="$(mf_stage_root)/.merge-failed"
  rm -f "$_st_flag"
  ( (cd "$_st_src" && tar cf - .) || : > "$_st_flag" ) | (cd "$PREFIX" && tar xf -) \
    || die "Cannot merge the staged install at $_st_src into $PREFIX"
  if [ -e "$_st_flag" ]; then
    rm -f "$_st_flag"
    die "Reading the staged install at $_st_src failed; $PREFIX is now PARTIALLY merged. Remove $PREFIX and rebuild -- a partial merge is indistinguishable from a complete one once the stage is gone."
  fi

  [ -n "$_st_new" ] && MF_STAGE_PENDING="$MF_STAGE_PENDING$_st_new
"

  mf_stage_warn_stray "$_st_dir" "$_st_src"
  mf_stage_reset
}

# Claim everything staged so far for the CURRENT RECIPE's own stamp, out of
# reach of any nested stamp_write.
#
# Without this, attribution is "whichever stamp is written next takes the pool",
# and two recipes break in exactly the direction GH-59 exists to close:
#
#   recipes/other/libcdio.sh installs itself through default_install, then
#   builds libcdio-paranoia in pkg_post_install and calls stamp_write for it --
#   which would drain libcdio's ~100 files into the PARANOIA stamp and leave
#   libcdio's own stamp empty. Deleting a libcdio artifact would then report
#   libcdio-paranoia as drifted, prune the wrong stamp, and rebuild paranoia
#   while still skipping libcdio, whose empty stamp is unverifiable forever.
#
#   recipes/audio/lv2.sh installs itself and then writes seven sub-package
#   stamps inside its own pkg_install. The first of them (waflib) installs
#   NOTHING and would take all of lv2's files.
#
# The framework claims after each phase; a recipe whose nested stamps live
# INSIDE pkg_install has to claim its own install itself, because the framework
# does not get control until the phase returns. lv2 is the only such recipe.
mf_stage_claim() {
  mf_stage_commit
  MF_STAGE_RESERVED="$MF_STAGE_RESERVED$MF_STAGE_PENDING"
  MF_STAGE_PENDING=""
}

# Hand the reserved files back, for the recipe's own stamp to drain.
mf_stage_restore() {
  MF_STAGE_PENDING="$MF_STAGE_RESERVED$MF_STAGE_PENDING"
  MF_STAGE_RESERVED=""
}

# Filter $PREFIX-relative paths on stdin to those that EXIST ($1 = extant) or
# those that DO NOT ($1 = missing).
#
# One definition of "is this recorded path still there", because the question is
# asked in both polarities in two different files -- here, to keep a manifest
# sound, and in mediaforge.sh's reconcile, to decide that a stamp has drifted.
# The reconcile answer drives a delete, so two copies free to disagree is a copy
# too many.
# `-e` OR `-L`, because the recorder and the filter must agree on what a
# manifest entry IS. mf_stage_commit enumerates with `find ... -o -type l`, so it
# deliberately records the LINK; `-e` alone resolves it, so a symlink whose
# target is gone reads as a missing file.
#
# The disagreement is reachable through the four recipes that delete `.so*` from
# the workspace (brotli, xvidcore, xevd, xeve): a dangling link would report its
# owning stamp as DRIFTED and make the preflight prune and rebuild it, blaming a
# file that is still on disk. Their globs happen to take link and target
# together today, which is what keeps it unreached rather than what makes it
# safe. Recording the directory entry rather than its resolution is also what
# pkg-plist and CONTENTS do.
mf_stage_filter_paths() {
  while IFS= read -r _st_p; do
    [ -n "$_st_p" ] || continue
    if [ -e "$PREFIX/$_st_p" ] || [ -L "$PREFIX/$_st_p" ]; then
      [ "$1" = extant ] && printf '%s\n' "$_st_p"
    else
      [ "$1" = missing ] && printf '%s\n' "$_st_p"
    fi
  done
  return 0
}

# The pending paths that ACTUALLY exist in $PREFIX right now, one per line.
#
# The existence filter is what makes a manifest sound. A recipe's
# pkg_post_install may delete a file its own pkg_install produced -- brotli and
# xvidcore both drop shared libraries that make install wrote, and xevd/xeve do
# the same inside pkg_install -- and a manifest naming a file deliberately
# removed would report as drift on every later reconcile: a permanent false
# positive in the one place a false positive is most expensive, since it would
# train the reader to ignore the report.
#
# The result is sound but not complete: every recorded path is one the recipe
# genuinely produced, while a file created by a bare shell `cp` is absent
# entirely. That asymmetry is acceptable HERE, where the manifest drives an
# audit and an unrecorded file merely weakens verification. It would not be
# acceptable in a package manager, where an omitted file is an orphan.
mf_stage_pending_extant() {
  [ -n "$MF_STAGE_PENDING" ] || return 0
  printf '%s' "$MF_STAGE_PENDING" | mf_stage_filter_paths extant | sort -u
}

# Drop the accumulator, once a stamp has taken responsibility for it.
mf_stage_pending_reset() {
  MF_STAGE_PENDING=""
}

# Drop the reserved pool. SEPARATE from mf_stage_pending_reset, and deliberately
# so: stamp_write calls that one, and a NESTED stamp_write must not be able to
# wipe the parent recipe's reserved files -- holding them out of its reach is
# the entire purpose of the pool. Folding the two together reintroduces the
# Critical bug this pool exists to fix, which
# `nested-stamp-takes-only-its-own-files` catches immediately.
#
# run_recipe calls it once per recipe, for the reason it gives about PENDING: a
# recipe that dies mid-phase must not leave a pool for the next one to prepend
# to its own stamp. It cannot leak through run_recipe as written -- claim and
# restore bracket a straight-line body -- but that is a property of that body,
# not of this state machine, and lv2 and opencl claim inside a phase function
# where a later `return` would strand the pool. Silently, and in the exact
# direction GH-59 exists to close.
mf_stage_reserved_reset() {
  MF_STAGE_RESERVED=""
}

# How many stray paths the warning below lists before it summarises the rest.
#
# A cap because the message is a diagnosis and not an inventory: the actionable
# half is "the recipe installed to a prefix other than $PREFIX", which is read
# once, and a foreign-prefix recipe stages hundreds of files. Five is enough to
# recognise which tree they landed in. NAMED because the listing and the
# "and N more" arithmetic must move together -- two literals free to disagree
# would under- or over-count the remainder.
MF_STAGE_STRAY_MAX=5

# Report anything staged OUTSIDE $PREFIX, which the merge above cannot carry.
#
# A recipe configured with a prefix other than the workspace stages to a path
# this function is the only thing that ever looks at. Left silent, its files
# would be deleted with the stage and the recipe would appear to have installed
# nothing -- a build failure displaced to whatever links against it later, which
# is the exact class of bug GH-59 exists to stop.
#
# `grep -v -F` with an explicit trailing slash, not a regex: $2 is an absolute
# path full of `.` characters, each of which matches ANY character in an ERE, so
# a regex filter suppresses genuine strays whose path differs from the prefix by
# a single character.
#
# The THIRD caller of the shared walk, and the third answer to what a failed one
# means. The manifest walk dies and the unclaimed audit reports a lower bound;
# here the walk feeds a warning that is the only thing which ever looks at these
# files, so a subtree it could not read is a stray nobody will ever be told
# about. Dying is not available -- these files were never going to be merged, so
# failing a build over them would fail it for the wrong reason -- and reporting
# a short list in silence is the defect GH-80 is about. So it reports the list
# it has and says the list is short.
#
# The filter stays OUT of the status-bearing statement, for the reason the
# statement exists: `walk | grep -v | head` is a pipeline again, and its status
# is head's.
#
# The EMPTY case is the quieter half of the same defect and has its own branch:
# a failed walk whose strays are all INSIDE the subtree it could not read leaves
# nothing to print, so without the branch this returns 0 having said nothing at
# all -- a stray that exists, in the only function that would ever mention it,
# reported as a clean stage. It survived a whole green suite when the fixture
# beside it always left a stray standing.
mf_stage_warn_stray() {
  [ -d "$1" ] || return 0
  _st_sw_partial=false
  _st_sw_all=$(mf_stage_walk_files "$1") || _st_sw_partial=true
  # `|| :` because grep exits 1 on NO MATCH, and no match here is the ordinary
  # case: every staged file was under the prefix, which is what a healthy build
  # looks like. That status used to be swallowed by the trailing `head`, so
  # taking the cap out of this statement -- which is what lets the count below be
  # honest -- exposed it, and under a caller running `set -e` (every test file
  # does) the assignment aborted the shell before the function could report
  # anything at all. tests/stamp-reconcile.sh caught it as a suite that stopped
  # mid-file; a "no stray" case is asserted there now rather than left implicit.
  _st_sw_stray=$(printf '%s\n' "$_st_sw_all" | grep -v -F "$2/") || :
  if [ -z "$_st_sw_stray" ]; then
    if [ "$_st_sw_partial" = true ]; then
      warn "Part of the staging area at $1 could not be read, so anything staged outside $2 there is NOT listed below."
    fi
    return 0
  fi
  # Counted BEFORE the cap, because the cap is the third way this function can
  # report a short list without saying so -- the same defect as the partial walk,
  # arriving through a display decision rather than a failure. `tr -d` for the
  # reason mediaforge.sh's unclaimed count gives: BSD wc pads its output.
  _st_sw_n=$(printf '%s\n' "$_st_sw_stray" | wc -l | tr -d " ")
  warn "Staged files landed OUTSIDE the workspace prefix and will NOT be merged:"
  printf '%s\n' "$_st_sw_stray" | head -n "$MF_STAGE_STRAY_MAX" | while IFS= read -r _st_f; do
    warn "    ${_st_f#"$1"}"
  done
  if [ "$_st_sw_n" -gt "$MF_STAGE_STRAY_MAX" ]; then
    warn "    ... and $((_st_sw_n - MF_STAGE_STRAY_MAX)) more."
  fi
  if [ "$_st_sw_partial" = true ]; then
    warn "  Part of the staging area could not be read; the list above is incomplete."
  fi
  warn "  The recipe installed to a prefix other than $PREFIX."
}
