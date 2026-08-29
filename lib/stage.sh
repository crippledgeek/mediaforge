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
#      and `ninja install` alike, so one `export` redirects every build-system
#      install in the tree. (CMake documents DESTDIR as an environment variable
#      whose "initial value is taken from the calling process environment";
#      Meson documents `DESTDIR=/path meson install`; the GNU Coding Standards
#      tell Makefile authors never to set it themselves, i.e. it comes from
#      outside.)
#   2. DESTDIR does NOT reach installed file CONTENTS. GNU: "Specifying DESTDIR
#      should not change the operation of the software in any way, so its value
#      should not be included in any file contents." That is what keeps a staged
#      .pc correct -- it records the REAL prefix while the file itself sits in
#      the stage.
#   3. DESTDIR does NOT redirect a plain shell `cp`/`mv`/`rm`/`>` aimed at an
#      absolute "$PREFIX/..." path. Recipes that install that way (gsm, ladspa,
#      amf, bzip2, quirc) keep writing straight to the live prefix exactly as
#      before, and simply record nothing. That is why this change is a retrofit
#      rather than a rewrite.
#
# The merge uses a tar pipe, not `cp -R`. POSIX leaves cp's symlink handling
# UNSPECIFIED when none of -H/-L/-P is given ("it is unspecified which of -H,
# -L, or -P will be used as a default"), and this must work on both GNU and BSD
# userlands. GNU cp happens to preserve links; that is an implementation's
# choice, not a guarantee to build a workspace on.

# The stage is a single directory per build step rather than one per package.
# DESTDIR prepends the whole absolute prefix path, so an install of $PREFIX/lib/x
# lands at $MF_STAGE_DIR$PREFIX/lib/x.
#
# One directory, not one per recipe, because the ATTRIBUTION comes from when
# stage_commit runs, not from where the files sit: lib/framework.sh commits
# between phases and stamp_write commits before it records, so each stamp
# receives exactly the files staged since the previous stamp. That is what makes
# the sub-package recipes work -- recipes/audio/lv2.sh builds seven packages
# inside one pkg_install and writes a stamp for each.
mf_stage_root() {
  printf '%s\n' "$PREFIX/.stage"
}

mf_stage_dir() {
  printf '%s\n' "$(mf_stage_root)/current"
}

# Drop the whole staging area.
#
# Called from the EXIT trap, because a build that dies inside pkg_install leaves
# a partial staged tree behind and nothing else would ever remove it. Worth
# noting what that partial tree means: before staging, a failed install left its
# half-written files in the LIVE prefix, where the next build would link against
# them. Now they die with the stage, which is the better failure.
mf_stage_discard() {
  rm -rf "$(mf_stage_root)" 2>/dev/null || true
}

# Paths committed since the last stamp, newline-separated, $PREFIX-relative.
# Reset per recipe by lib/framework.sh and drained by stamp_write.
MF_STAGE_PENDING=""

# Start staging: empty the stage and point DESTDIR at it.
#
# Exported, because that is the whole mechanism -- make, ninja and cmake each
# read DESTDIR from the environment, so nothing has to be threaded through a
# recipe's own install line.
mf_stage_begin() {
  _st_dir=$(mf_stage_dir)
  rm -rf "$_st_dir"
  mkdir -p "$_st_dir" 2>/dev/null || die "Cannot create the staging dir at $_st_dir"
  DESTDIR="$_st_dir"
  export DESTDIR
}

# Stop staging, so anything after this point writes to the live prefix again.
mf_stage_end() {
  unset DESTDIR
  rm -rf "$(mf_stage_dir)"
}

# Merge the stage into $PREFIX and remember what came across.
#
# Called between pkg_install and pkg_post_install, again after
# pkg_post_install, and once more from stamp_write. The FIRST of those is
# load-bearing and is the reason this is not simply folded into stamp_write:
# thirteen recipes' pkg_post_install reads back or deletes a file that
# pkg_install just wrote to the live prefix (chromaprint, srt, vmaf, openh264,
# vvenc, x265, xevd, xeve rewrite an installed .pc; shaderc renames one; brotli,
# xvidcore, xevd and xeve delete shared libraries make install produced; libressl
# asserts libtls.pc exists). Merging only at the stamp would leave every one of
# those reading a path that is still sitting in the stage.
mf_stage_commit() {
  _st_dir=$(mf_stage_dir)
  _st_src="$_st_dir$PREFIX"

  [ -d "$_st_src" ] || { mf_stage_warn_stray "$_st_dir" "$_st_src"; return 0; }

  # Record BEFORE merging: the stage holds this step's files and nothing else,
  # which is the entire reason for staging. Enumerating $PREFIX after the merge
  # would be back to guessing which of thousands of files were ours.
  _st_new=$(cd "$_st_src" && find . \( -type f -o -type l \) 2>/dev/null | sed 's|^\./||')

  if [ -n "$_st_new" ]; then
    # tar, not cp -R: see the header. `tar cf - .` from inside the source keeps
    # every path relative, so the extraction lands exactly on $PREFIX.
    (cd "$_st_src" && tar cf - .) | (cd "$PREFIX" && tar xf -) \
      || die "Cannot merge the staged install at $_st_src into $PREFIX"
    MF_STAGE_PENDING="$MF_STAGE_PENDING$_st_new
"
  fi

  mf_stage_warn_stray "$_st_dir" "$_st_src"

  rm -rf "$_st_dir"
  mkdir -p "$_st_dir" 2>/dev/null || die "Cannot re-create the staging dir at $_st_dir"
}

# Report anything staged OUTSIDE $PREFIX, which the merge above cannot carry.
#
# A recipe configured with a prefix other than the workspace stages to a path
# this function is the only thing that ever looks at. Left silent, its files
# would be deleted with the stage and the recipe would appear to have installed
# nothing -- a build failure displaced to whatever links against it later, which
# is the exact class of bug GH-59 exists to stop.
mf_stage_warn_stray() {
  [ -d "$1" ] || return 0
  _st_stray=$(find "$1" \( -type f -o -type l \) 2>/dev/null \
    | grep -v "^$2/" | head -5)
  [ -n "$_st_stray" ] || return 0
  warn "Staged files landed OUTSIDE the workspace prefix and will NOT be merged:"
  printf '%s\n' "$_st_stray" | while IFS= read -r _st_f; do
    warn "    ${_st_f#"$1"}"
  done
  warn "  The recipe installed to a prefix other than $PREFIX."
}

# The pending paths that ACTUALLY exist in $PREFIX right now, one per line.
#
# The existence filter is what makes a manifest sound. A recipe's
# pkg_post_install may delete a file its own pkg_install produced -- xevd, xeve,
# brotli and xvidcore all drop shared libraries that make install wrote -- and a
# manifest naming a file deliberately removed would report as drift on every
# later reconcile: a permanent false positive in the one place a false positive
# is most expensive, since it would train the reader to ignore the report.
#
# The result is sound but not complete: every recorded path is one the recipe
# genuinely produced, while a file created by a bare shell `cp` is absent
# entirely. That asymmetry is acceptable HERE, where the manifest drives an
# audit and an unrecorded file merely weakens verification. It would not be
# acceptable in a package manager, where an omitted file is an orphan.
mf_stage_pending_extant() {
  [ -n "$MF_STAGE_PENDING" ] || return 0
  printf '%s' "$MF_STAGE_PENDING" | while IFS= read -r _st_p; do
    [ -n "$_st_p" ] || continue
    [ -e "$PREFIX/$_st_p" ] && printf '%s\n' "$_st_p"
  done | sort -u
}

# Drop the accumulator, once a stamp has taken responsibility for it.
mf_stage_pending_reset() {
  MF_STAGE_PENDING=""
}
