#!/bin/sh
# The recipes that install with a shell cp write into the STAGE (GH-68).
#
# DESTDIR redirects a build system's install target and nothing else, so a
# recipe installing by hand at an absolute "$PREFIX/..." path wrote straight
# past the staging window GH-59 opened around it: it staged nothing, its stamp
# carried no manifest, and `reconcile` reported it `unverifiable` forever --
# honest, and unfalsifiable. Eight recipes were in that state.
#
# The failure this guards is SILENT in both directions, which is why it is
# tested behaviourally rather than by grep. A recipe that reverts to $PREFIX
# still installs the right files to the right paths and still builds FFmpeg;
# only its manifest goes quiet again. And a recipe that writes to the stage but
# bakes the stage path into a file's CONTENTS -- a .pc prefix= line, meson's
# launcher -- also builds, until something resolves that path after the stage is
# deleted. Neither is visible in a green build.
#
# So each recipe's install phase is run for real against a fixture, with DESTDIR
# pointed at a scratch stage, and two things are asserted: every file it created
# landed in the stage, and NOTHING landed in the live prefix. The second half is
# the one that fails on the merge base.
#
# lib/stage.sh is sourced conditionally for the reason tests/stamp-reconcile.sh
# gives: an unguarded source under `set -e` aborts before the DONE sentinel,
# which tests/oracle-baseline.sh reports as a crashed test rather than as the
# absent feature.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

_tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$_tmp"' EXIT
_cleanup_on_signal

# meson resolves its source tree by version out of $DISTDIR (which _install_into
# points at the fixture), so the fixture has
# to know which version the recipe will ask for. Pinning it here rather than
# reading the recipe's default keeps the fixture from silently missing the day
# the default moves.
PKG_VERSION_MESON=9.9.9
export PKG_VERSION_MESON

# --- the helper -------------------------------------------------------------
if [ -f "$ROOT/lib/stage.sh" ]; then
  # shellcheck source=lib/stage.sh
  . "$ROOT/lib/stage.sh"
fi

if ! command -v mf_dest_prefix >/dev/null 2>&1; then
  _bad dest-prefix-defined "lib/stage.sh defines no mf_dest_prefix, so a shell install has nowhere to write but the live prefix"
else
  _reasons=""
  _staged=$(PREFIX=/p DESTDIR=/s mf_dest_prefix)
  [ "$_staged" = /s/p ] || _reasons="$_reasons with DESTDIR=/s and PREFIX=/p it returned '$_staged', not /s/p."
  # Unset, not empty: the phases are callable outside a staging window and must
  # then name the live prefix exactly as they did before staging existed.
  _live=$(PREFIX=/p; unset DESTDIR; mf_dest_prefix)
  [ "$_live" = /p ] || _reasons="$_reasons with DESTDIR unset it returned '$_live', not /p."
  _verdict dest-prefix-defined "$_reasons"
fi

# --- fixtures ---------------------------------------------------------------
# The minimum each pkg_install reads. Enough for the phase to run to completion
# on a tree it did not build; not a substitute for building the real thing.
_fixture() { # name  dir
  mkdir -p "$2"
  case "$1" in
    amf)
      mkdir -p "$2/AMF/components" "$2/AMF/core"
      : > "$2/AMF/core/Platform.h" ;;
    bzip2)
      : > "$2/bzlib.h"; : > "$2/libbz2.a" ;;
    flite)
      mkdir -p "$2/include" "$2/build/x86_64-linux-gnu/lib"
      : > "$2/include/flite.h"; : > "$2/build/x86_64-linux-gnu/lib/libflite.a" ;;
    gsm)
      mkdir -p "$2/inc" "$2/lib"
      : > "$2/inc/gsm.h"; : > "$2/lib/libgsm.a" ;;
    ladspa)
      mkdir -p "$2/src"; : > "$2/src/ladspa.h" ;;
    meson)
      mkdir -p "$2/meson-$PKG_VERSION_MESON/mesonbuild"
      : > "$2/meson-$PKG_VERSION_MESON/meson.py"
      : > "$2/meson-$PKG_VERSION_MESON/mesonbuild/__init__.py" ;;
    quirc)
      mkdir -p "$2/lib"; : > "$2/lib/quirc.h"; : > "$2/libquirc.a" ;;
    vapoursynth)
      mkdir -p "$2/include"; : > "$2/include/VapourSynth4.h" ;;
    *) return 1 ;;
  esac
}

# Run one recipe's install phases with DESTDIR pointing at a scratch stage.
#
# A subshell with stubs rather than the real framework: run() and die() are all
# these phases reach for, and driving lib/framework.sh would mean a fetch, a
# configure and a build to observe a copy. The recipe file is SOURCED, so its
# top-level code (amf's layout case, quirc's version guard) runs as it does in a
# real build.
_install_into() { # recipe-path  fixture-name  work-dir
  # DISTDIR and the four stubs are read by the recipe sourced below, from a path
  # the linter cannot follow, so its "unused"/"never invoked" findings are wrong
  # here rather than tolerated: deleting any one of them breaks a recipe.
  # shellcheck disable=SC2034,SC2329
  (
    set -eu
    PREFIX="$3/prefix"
    DESTDIR="$3/stage"
    DISTDIR="$3/src/$2"
    export DESTDIR
    mkdir -p "$PREFIX" "$DESTDIR" "$DESTDIR$PREFIX"
    die() { printf 'die: %s\n' "$*" >&2; exit 1; }
    run() { "$@"; }
    default_noop() { :; }
    ffmpeg_version_ge() { return 0; }
    . "$ROOT/lib/stage.sh"
    # shellcheck disable=SC1090
    . "$ROOT/$1"
    cd "$3/src/$2"
    pkg_install
    # bzip2 writes its hand-made .pc here, and post_install runs inside the same
    # staging window (lib/framework.sh claims again after it), so it is part of
    # what this recipe stages. An `&&` here would make the subshell's status the
    # test for a phase most recipes do not define, and report every one of them
    # as a failed install.
    if command -v pkg_post_install >/dev/null 2>&1; then
      pkg_post_install
    fi
  ) >"$3/out" 2>&1
}

# --- one assertion per recipe ----------------------------------------------
# Fields: name  recipe-path  expected-staged-paths (space-separated, $PREFIX-
# relative). The expectations are the files the recipe installed before this
# change, so they also pin the "installs the same files to the same paths"
# half of GH-68's acceptance.
while read -r _name _recipe _expected; do
  [ -n "$_name" ] || continue
  _work="$_tmp/$_name"
  _fixture "$_name" "$_work/src/$_name" || { _bad "$_name-installs-into-the-stage" "no fixture"; continue; }
  _reasons=""
  if ! _install_into "$_recipe" "$_name" "$_work"; then
    _reasons=" the install phase failed: $(tail -3 "$_work/out" | tr '\n' ' ')"
  fi
  _stray=$(find "$_work/prefix" \( -type f -o -type l \) 2>/dev/null | wc -l | tr -d ' ')
  [ "$_stray" = 0 ] || _reasons="$_reasons wrote $_stray file(s) straight to the live prefix, which stages nothing and records nothing."
  for _p in $_expected; do
    [ -e "$_work/stage$_work/prefix/$_p" ] \
      || _reasons="$_reasons $_p is not in the stage."
  done
  _verdict "$_name-installs-into-the-stage" "$_reasons"
done <<'TABLE'
amf recipes/hwaccel/amf.sh include/AMF/core/Platform.h
bzip2 recipes/syslib/bzip2.sh include/bzlib.h lib/libbz2.a lib/pkgconfig/bzip2.pc
flite recipes/other/flite.sh include/flite/flite.h lib/libflite.a
gsm recipes/audio/gsm.sh include/gsm/gsm.h lib/libgsm.a
ladspa recipes/other/ladspa.sh include/ladspa.h
meson recipes/tools/meson.sh share/meson/meson.py share/meson/mesonbuild/__init__.py bin/meson
quirc recipes/other/quirc.sh include/quirc.h lib/libquirc.a lib/pkgconfig/libquirc.pc
vapoursynth recipes/other/vapoursynth.sh include/vapoursynth/VapourSynth4.h
TABLE

# --- the paths that must NOT follow the files into the stage ---------------
# DESTDIR must never reach a file's CONTENTS (GNU Coding Standards). Both
# generated .pc files and meson's launcher name a path that is resolved long
# after the stage is deleted, so a stage path baked into one of them is a build
# that works until it doesn't.
_work="$_tmp/contents"
_reasons=""
for _c in quirc:recipes/other/quirc.sh:lib/pkgconfig/libquirc.pc \
          bzip2:recipes/syslib/bzip2.sh:lib/pkgconfig/bzip2.pc \
          meson:recipes/tools/meson.sh:bin/meson; do
  _n=${_c%%:*}; _rest=${_c#*:}; _r=${_rest%%:*}; _file=${_rest#*:}
  _w="$_work/$_n"
  _fixture "$_n" "$_w/src/$_n" || continue
  _install_into "$_r" "$_n" "$_w" || true
  _got="$_w/stage$_w/prefix/$_file"
  if [ ! -e "$_got" ]; then
    _reasons="$_reasons $_file never reached the stage."
  elif grep -qF -- "$_w/stage" "$_got"; then
    _reasons="$_reasons $_file names the stage in its contents: $(grep -F -- "$_w/stage" "$_got" | head -1)."
  elif ! grep -qF -- "$_w/prefix" "$_got"; then
    _reasons="$_reasons $_file names neither the stage nor the real prefix."
  fi
done
_verdict generated-contents-name-the-real-prefix "$_reasons"

printf 'DONE: staged-shell-installs\n'
exit "$_fail"
