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
#      absolute "$PREFIX/..." path. Recipes that install that way (gsm, ladspa,
#      amf, bzip2, quirc, meson) keep writing straight to the live prefix
#      exactly as before, and simply record nothing. That is why this change is
#      a retrofit rather than a rewrite.
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

  [ -d "$_st_src" ] || { mf_stage_warn_stray "$_st_dir" "$_st_src"; return 0; }

  # Record BEFORE merging: the stage holds this step's files and nothing else,
  # which is the entire reason for staging. Enumerating $PREFIX after the merge
  # would be back to guessing which of thousands of files were ours.
  _st_new=$(cd "$_st_src" && find . \( -type f -o -type l \) 2>/dev/null | sed 's|^\./||')

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
mf_stage_filter_paths() {
  while IFS= read -r _st_p; do
    [ -n "$_st_p" ] || continue
    if [ -e "$PREFIX/$_st_p" ]; then
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
mf_stage_warn_stray() {
  [ -d "$1" ] || return 0
  _st_stray=$(find "$1" \( -type f -o -type l \) 2>/dev/null \
    | grep -v -F "$2/" | head -5)
  [ -n "$_st_stray" ] || return 0
  warn "Staged files landed OUTSIDE the workspace prefix and will NOT be merged:"
  printf '%s\n' "$_st_stray" | while IFS= read -r _st_f; do
    warn "    ${_st_f#"$1"}"
  done
  warn "  The recipe installed to a prefix other than $PREFIX."
}
