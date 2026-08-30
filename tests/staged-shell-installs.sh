#!/bin/sh
# A recipe that installs with a shell cp writes into the STAGE (GH-68).
#
# DESTDIR redirects a build system's install target and nothing else, so a
# recipe installing by hand at an absolute "$PREFIX/..." path wrote straight
# past the staging window GH-59 opened around it: it staged nothing, its stamp
# carried no manifest, and `reconcile` reported it `unverifiable` forever --
# honest, and unfalsifiable. Eight recipes were in that state outright. Six more
# were worse: a build-system install staged files beside a hand-copy that did
# not, so the stamp read `verified` while missing a file it had installed.
#
# The failure this guards is SILENT in both directions, which is why it is
# tested behaviourally rather than by grep. A recipe that reverts to $PREFIX
# still installs the right files to the right paths and still builds FFmpeg;
# only its manifest goes quiet again. And a recipe that writes to the stage but
# bakes the stage path into a file's CONTENTS -- a .pc prefix= line, meson's
# launcher -- also builds, until something resolves that path after the stage is
# deleted. Neither is visible in a green build.
#
# So each recipe's install phase is run against a fixture, with DESTDIR pointed
# at a scratch stage, and two things are asserted: every file it created landed
# in the stage, and NOTHING landed in the live prefix. The second half is the one
# that fails on the merge base.
#
# It is the real phase, not the real framework, and the difference is worth
# naming: run_recipe claims -- commits AND resets -- between pkg_install and
# pkg_post_install, while _install_into below runs both against one stage. So
# bzip2's `mf_dest_mkdir lib/pkgconfig` in post_install is exercised here with
# the directory already present from its own pkg_install, where a real build
# gives it an empty stage. Removing that call is still caught, because
# lib/pkgconfig is not created by anything else in either arrangement.
#
# lib/stage.sh is sourced conditionally AT THE TOP for the reason
# tests/stamp-reconcile.sh gives: an unguarded source under `set -e` aborts
# before the DONE sentinel, which tests/oracle-baseline.sh reports as a crashed
# test rather than as the absent feature. _install_into sources it unguarded,
# which is safe for the opposite reason -- it runs in a subshell, so a failure
# there is a FAIL line rather than the end of the run.
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
  # Both spellings of "no staging window", because ${DESTDIR:-} treats them
  # alike and a future ${DESTDIR-} would not: the phases are callable outside a
  # window and must then name the live prefix exactly as they did before
  # staging existed.
  _live=$(PREFIX=/p; unset DESTDIR; mf_dest_prefix)
  [ "$_live" = /p ] || _reasons="$_reasons with DESTDIR unset it returned '$_live', not /p."
  _live=$(PREFIX=/p DESTDIR='' mf_dest_prefix)
  [ "$_live" = /p ] || _reasons="$_reasons with DESTDIR empty it returned '$_live', not /p."
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

# Take back the directories the seeding above created, so they are not counted
# as strays.
#
# Walks up removing only what is EMPTY, and stops at the first directory that is
# not -- so anything the recipe itself left behind survives and is still counted.
# A level that no longer exists is skipped rather than ending the walk: the very
# rm being tested deletes the seeded leaf, and stopping there would leave its
# parent standing and fail every run.
_unseed() { # prefix-root  $PREFIX-relative-dir
  _us_d="$1/$2"
  while [ "$_us_d" != "$1" ]; do
    if [ -d "$_us_d" ]; then
      rmdir "$_us_d" 2>/dev/null || break
    fi
    _us_d=$(dirname "$_us_d")
  done
}

# Run one recipe's install phases with DESTDIR pointing at a scratch stage.
#
# A subshell with stubs rather than the real framework: run() and die() are all
# these phases reach for, and driving lib/framework.sh would mean a fetch, a
# configure and a build to observe a copy. The recipe file is SOURCED, so its
# top-level code (amf's layout case, quirc's version guard) runs as it does in a
# real build.
_install_into() { # recipe-path  fixture-name  work-dir
  (
    set -eu
    PREFIX="$3/prefix"
    DESTDIR="$3/stage"
    # Read by the recipe sourced below, from a path the linter cannot follow.
    # shellcheck disable=SC2034
    DISTDIR="$3/src/$2"
    export DESTDIR
    # $DESTDIR$PREFIX is deliberately NOT created. mf_stage_begin makes the
    # stage root and nothing under it, so a phase starts with no directory of
    # its own -- which is the precondition the added mkdir/install -d calls
    # exist for. Pre-creating it would hide their removal.
    mkdir -p "$PREFIX" "$DESTDIR"
    # shellcheck disable=SC2329
    die() { printf 'die: %s\n' "$*" >&2; exit 1; }
    # Invoked from the sourced recipe, which the linter's call graph does not
    # reach: `run` by most install phases, `die` by their failure arms, and
    # `ffmpeg_version_ge` by quirc at source time. `default_noop` is NOT reached
    # by these two phases -- meson uses it for configure/build -- and is here so
    # that a recipe which grows one fails on its own terms rather than on a
    # missing stub.
    # shellcheck disable=SC2329
    run() { "$@"; }
    # shellcheck disable=SC2329
    default_noop() { :; }
    # shellcheck disable=SC2329
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
  # amf and meson keep an `rm -rf` aimed at the LIVE prefix while installing to
  # the stage, because the merge only ever adds and neither would otherwise drop
  # a header or a module the new version stopped shipping. That split is the
  # diff's most delicate decision and an empty prefix cannot observe it: a
  # mutation pointing either rm at the stage leaves every other assertion green.
  # So the stale file is planted, and its removal asserted.
  _stale=""
  case "$_name" in
    amf)   _stale=include/AMF/dropped-by-upstream.h ;;
    meson) _stale=share/meson/mesonbuild/dropped_by_upstream.py ;;
  esac
  if [ -n "$_stale" ]; then
    mkdir -p "$_work/prefix/${_stale%/*}"
    : > "$_work/prefix/$_stale"
  fi
  _reasons=""
  if ! _install_into "$_recipe" "$_name" "$_work"; then
    _reasons=" the install phase failed: $(tail -3 "$_work/out" | tr '\n' ' ')"
  fi
  if [ -n "$_stale" ]; then
    if [ -e "$_work/prefix/$_stale" ]; then
      _reasons="$_reasons $_stale survived in the live prefix, so the rm no longer purges what upstream dropped."
      rm -f "$_work/prefix/$_stale"
    fi
    _unseed "$_work/prefix" "${_stale%/*}"
  fi
  # Directories count, not only files: a regression that recreates a live-prefix
  # directory -- `mkdir -p "$PREFIX/lib/pkgconfig"`, the exact shape found in
  # libcaca -- leaves no file behind and would otherwise be invisible here.
  _stray=$(find "$_work/prefix" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
  [ "$_stray" = 0 ] || _reasons="$_reasons left $_stray path(s) in the live prefix, which stages nothing and records nothing: $(find "$_work/prefix" -mindepth 1 2>/dev/null | head -3 | tr '\n' ' ')"
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
while read -r _n _r _file; do
  [ -n "$_n" ] || continue
  _w="$_work/$_n"
  _reasons=""
  _fixture "$_n" "$_w/src/$_n" || _reasons=" no fixture."
  _install_into "$_r" "$_n" "$_w" || true
  _got="$_w/stage$_w/prefix/$_file"
  if [ ! -e "$_got" ]; then
    _reasons="$_reasons $_file never reached the stage."
  elif grep -qF -- "$_w/stage" "$_got"; then
    _reasons="$_reasons it names the stage in its contents: $(grep -F -- "$_w/stage" "$_got" | head -1)."
  elif ! grep -qF -- "$_w/prefix" "$_got"; then
    _reasons="$_reasons it names neither the stage nor the real prefix."
  fi
  _verdict "$_n-$(basename "$_file")-names-the-real-prefix" "$_reasons"
done <<'TABLE'
quirc recipes/other/quirc.sh lib/pkgconfig/libquirc.pc
bzip2 recipes/syslib/bzip2.sh lib/pkgconfig/bzip2.pc
meson recipes/tools/meson.sh bin/meson
TABLE

# --- the class, not the instances ------------------------------------------
# Every recipe converted here was found by hand, twice: the issue's survey
# selected on EMPTY stamps and so missed five recipes whose build-system install
# staged something while a hand-copy beside it did not (libcaca, svtav1, xeve,
# xevd, libressl, shaderc -- the last two by reading, since neither is in the
# default build). A per-file defect does not show up in a per-stamp survey, and
# nothing stops the next recipe from reintroducing it.
#
# So the rule is asserted over the whole tree instead of over a list: inside an
# install phase, a command that CREATES a file at a literal "$PREFIX/... path
# writes past the stage. `>>` is exempt and is the only exemption -- lv2 and
# nv-codec append to $PREFIX/.extra_cflags, an accumulator the framework reads
# after the build, and a staged append would be a fresh file that the merge then
# writes over the accumulated one.
#
# RESIDUAL, stated rather than papered over: a path bound to a variable first
# (`_pc="$PREFIX/lib/pkgconfig/xeve.pc"`) is not seen. The three in-tree cases
# are all in-place rewrites of a file default_install already staged under the
# same name, which are correct against the live prefix -- but a new recipe could
# evade this scan that way. Catching it means resolving assignments, which is a
# parser, not a grep.
_scanned=0
_offenders=""
for _f in $(find recipes -name '*.sh' | sort); do
  for _fn in pkg_install pkg_post_install; do
    _body=$(_fn_body "$_f" "$_fn")
    [ -n "$_body" ] || continue
    _scanned=$((_scanned + 1))
    _hits=$(printf '%s\n' "$_body" | sed 's/[[:space:]]*#.*$//' \
      | grep -nE '(^|[[:space:]])(cp|install|ln|tee|mv)([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^|;]*"[$]PREFIX/|[^>]>[[:space:]]*"[$]PREFIX/' \
      || true)
    [ -n "$_hits" ] && _offenders="$_offenders $_f:$_fn:$(printf '%s' "$_hits" | head -1 | cut -d: -f1)"
  done
done
# A floor, because the scan is vacuous if _fn_body ever returns nothing: zero
# offenders across zero phases is the same PASS as zero across all of them.
if [ "$_scanned" -lt 40 ]; then
  _bad no-recipe-installs-past-the-stage "only $_scanned install phase(s) scanned — the scan found nothing because it read nothing"
else
  _verdict no-recipe-installs-past-the-stage "$_offenders"
fi

printf 'DONE: staged-shell-installs\n'

exit "$_fail"
