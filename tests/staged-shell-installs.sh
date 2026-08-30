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

# The directory step has to FAIL THE BUILD when it cannot create the directory.
# That is the whole reason mf_dest_mkdir exists: the call sites it replaced
# spelled this four ways, and five of them could not tell you their mkdir had
# failed. A non-zero return is not enough on its own -- no recipe checks the
# status -- so what is asserted is that die() is reached.
if ! command -v mf_dest_mkdir >/dev/null 2>&1; then
  _bad dest-mkdir-fails-loudly "lib/stage.sh defines no mf_dest_mkdir, so an install phase whose mkdir fails carries on to write nothing, quietly"
else
  _blocked="$_tmp/a-file-where-a-directory-is-wanted"
  : > "$_blocked"
  _reasons=""
  if ( PREFIX="$_blocked/prefix"; unset DESTDIR
       die() { printf 'DIED\n'; exit 3; }
       mf_dest_mkdir lib ) >"$_tmp/mkdir-out" 2>&1; then
    _reasons=" it reported success though mkdir could not create the directory."
  elif ! grep -q DIED "$_tmp/mkdir-out"; then
    _reasons=" it failed without calling die, and no recipe checks the status, so the build would carry on."
  fi
  # And an empty argument list, which is a mis-expansion rather than a request
  # to do nothing: `for` over it returns 0, so the failure would surface later
  # as the cp that had nowhere to land.
  if ( PREFIX="$_tmp/p"; unset DESTDIR
       die() { printf 'DIED\n'; exit 3; }
       mf_dest_mkdir ) >"$_tmp/mkdir-none" 2>&1 || ! grep -q DIED "$_tmp/mkdir-none"; then
    _reasons="$_reasons called with no directories it returned quietly instead of failing the build."
  fi
  _verdict dest-mkdir-fails-loudly "$_reasons"
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
    shaderc)
      : ;;  # its input is the .pc planted in the live prefix, not a source file
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
# What lib/framework.sh gives a recipe, reduced to what its install phases
# reach for. Defined once because two drivers need it: the table below, and the
# libressl block at the end, whose phase merges mid-flight and so cannot use the
# same assertions.
#
# The phase defaults mirror reset_recipe's, and must be in place BEFORE the
# recipe is sourced so it can override them -- a recipe that defines neither
# (shaderc) is otherwise not runnable at all. Function definitions are global in
# POSIX sh, so making them here reaches the caller.
#
# Everything here is invoked from the sourced recipe, which the linter's call
# graph does not reach: `run` by most install phases, `die` by their failure
# arms, `ffmpeg_version_ge` by quirc at source time, `warn`/`log` by libressl.
# `default_noop` is not reached by these two phases -- meson uses it for
# configure and build -- and is here so a recipe that grows one fails on its own
# terms rather than on a missing stub.
# shellcheck disable=SC2329
_recipe_stubs() {
  die()  { printf 'die: %s\n' "$*" >&2; exit 1; }
  run()  { "$@"; }
  log()  { printf 'log: %s\n' "$*"; }
  warn() { printf 'warn: %s\n' "$*" >&2; }
  default_noop()     { :; }
  default_install()  { :; }
  pkg_install()      { default_install; }
  pkg_post_install() { default_noop; }
  ffmpeg_version_ge() { return 0; }
}

# Drive ONE phase of a recipe, with the stage at its real path inside the
# prefix.
#
# Separate from _install_into because these two phases cannot make its
# assertions: libressl's COMMITS mid-flight, so it ends with its file in the
# prefix by design, and lcevc's runs `ar` over archives that have to be in the
# live prefix already. Both need the real stage layout, since what they exercise
# is mf_stage_commit and a live/stage split rather than a plain staged copy.
#
# A caller needing an extra stub defines it before calling: POSIX function
# definitions are global and a subshell inherits them, so no fourth parameter.
_run_phase() { # recipe-path  work-dir  phase
  (
    set -eu
    PREFIX="$2/prefix"
    DESTDIR="$2/prefix/.stage/current"
    export DESTDIR
    mkdir -p "$PREFIX" "$DESTDIR"
    _recipe_stubs
    . "$ROOT/lib/stage.sh"
    # shellcheck disable=SC1090
    . "$ROOT/$1"
    cd "$2/src"
    "$3"
    printf 'PENDING:%s\n' "$MF_STAGE_PENDING"
  ) >"$2/out" 2>&1
}

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
    _recipe_stubs
    . "$ROOT/lib/stage.sh"
    # shellcheck disable=SC1090
    . "$ROOT/$1"
    cd "$3/src/$2"
    pkg_install
    # post_install runs inside the same staging window (lib/framework.sh claims
    # again after it), so what it writes is part of what this recipe stages --
    # bzip2's hand-made .pc, shaderc's renamed one.
    pkg_post_install
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
  # Three recipes delete from the LIVE prefix while installing to the stage, and
  # an empty prefix cannot observe that: a mutation aiming any of those deletes
  # at the stage instead leaves every other assertion green. So the file each
  # one must remove is planted, and its removal asserted.
  #
  # amf and meson drop what a previous version installed and this one does not,
  # since the merge only ever adds. shaderc's is different in kind and the same
  # to test: the .pc it replaces is its own INPUT, so planting it is the phase's
  # precondition as well as the thing that must be gone afterwards.
  _stale=""
  case "$_name" in
    amf)     _stale=include/AMF/dropped-by-upstream.h ;;
    meson)   _stale=share/meson/mesonbuild/dropped_by_upstream.py ;;
    shaderc) _stale=lib/pkgconfig/shaderc_static.pc ;;
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
shaderc recipes/hwaccel/shaderc.sh lib/pkgconfig/shaderc.pc
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

# --- the one phase that merges mid-flight ----------------------------------
# libressl cannot use the assertions above, and the difference is the point.
# Its post_install writes cert.pem -- the one file whose absence fails TLS
# closed at handshake time, with no SSL_CERT_FILE to fall back on -- and then,
# ten lines later, READS THAT PATH BACK to decide whether to advise the
# operator. Staging the write without committing would make that advisory fire
# on every build against a file still sitting in the stage.
#
# So two things are asserted together: the file was STAGED (which is what puts
# it in the manifest, and is what fails on the merge base, where the cp went
# straight to the live prefix), and the advisory stayed silent (which is what
# fails if the commit is dropped). The stage is at its REAL path here, inside
# the prefix, because mf_stage_commit is what is under test rather than stubbed.
_w="$_tmp/libressl"
mkdir -p "$_w/prefix/lib/pkgconfig" "$_w/src"
: > "$_w/prefix/lib/pkgconfig/libtls.pc"
: > "$_w/src/cert.pem"
# Read by the recipe, from a path the linter cannot follow.
# shellcheck disable=SC2034
OPENSSLDIR=""
# The real one probes the host for a directory holding cert.pem and falls back
# to its second argument. Taking the fallback unconditionally is what puts the
# read-back on the very path the cp writes, which is the case that matters --
# and $2 rather than $PREFIX because the recipe passes "$PREFIX/etc/ssl" itself.
# shellcheck disable=SC2329,SC2034
resolve_openssldir() { OPENSSLDIR_RESOLVED="$2"; }
_run_phase recipes/crypto/libressl.sh "$_w" pkg_post_install || true
_reasons=""
grep -q '^PENDING:.*etc/ssl/cert.pem' "$_w/out" \
  || _reasons=" cert.pem was never staged, so no manifest names the file whose absence fails TLS closed: $(tail -2 "$_w/out" | tr '\n' ' ')"
[ -e "$_w/prefix/etc/ssl/cert.pem" ] \
  || _reasons="$_reasons it never reached the prefix either."
grep -q 'baked trust store' "$_w/out" \
  && _reasons="$_reasons the advisory fired against a file the phase had just written, so the commit is missing."
_verdict libressl-stages-and-commits-its-trust-store "$_reasons"

# --- the phase that CREATES a library with ar -------------------------------
# lcevc merges the eight split archives upstream installs into the single
# liblcevc_dec.a that FFmpeg links, and `ar cr` creates a file: written to the
# live prefix it was past the stage, so the one library the recipe exists to
# produce was absent from a stamp that read `verified`, while the eight it
# replaces were recorded and then deleted. Found in review, after two comments
# on this branch had asserted no such case was left.
#
# The scanner cannot see it -- `ar` writes to a variable-bound path -- which is
# exactly why it gets a behavioural assertion instead.
_w="$_tmp/lcevc"
mkdir -p "$_w/prefix/lib" "$_w/src/objs"
: > "$_w/src/objs/one.o"
: > "$_w/src/objs/two.o"
# Real archives, because the phase runs a real `ar x` over them. ar and ranlib
# accept members that are not objects, so no compiler is needed.
( cd "$_w/src/objs" && ar cr "$_w/prefix/lib/liblcevc_dec_api.a" one.o \
                    && ar cr "$_w/prefix/lib/liblcevc_dec_core.a" two.o ) >/dev/null 2>&1
# A stale merged archive from an earlier build, which the phase must replace.
: > "$_w/prefix/lib/liblcevc_dec.a"
_run_phase recipes/other/lcevc.sh "$_w" pkg_post_install || true
_reasons=""
[ -e "$_w/prefix/.stage/current$_w/prefix/lib/liblcevc_dec.a" ] \
  || _reasons=" the merged archive is not in the stage, so the one library FFmpeg links would be missing from lcevc's manifest: $(tail -2 "$_w/out" | tr '\n' ' ')"
[ -e "$_w/prefix/lib/liblcevc_dec.a" ] \
  && _reasons="$_reasons the stale merged archive is still in the live prefix."
ls "$_w/prefix/lib"/liblcevc_dec_*.a >/dev/null 2>&1 \
  && _reasons="$_reasons the split archives were not dropped, so a downstream can still link the broken set."
_verdict lcevc-stages-the-archive-it-creates "$_reasons"

# --- the class, not the instances ------------------------------------------
# Every recipe converted here was found by hand, twice: the issue's survey
# selected on EMPTY stamps and so missed seven whose build-system install staged
# something while a hand-copy beside it did not -- libcaca, svtav1, xeve, xevd,
# libressl, shaderc, and lcevc, whose `ar cr` creates the one archive FFmpeg
# links. A per-file defect does not show up in a per-stamp survey, and nothing
# stops the next recipe from reintroducing it.
#
# So the rule is asserted over the whole tree instead of over a list: inside an
# install phase, a command that CREATES a file at a literal "$PREFIX/... path
# writes past the stage. `>>` is exempt and is the only exemption -- lv2 and
# nv-codec append to $PREFIX/.extra_cflags and .extra_ldflags, accumulators the
# framework reads after the build, and a staged append would be a fresh file
# that the merge then writes over the accumulated one.
#
# RESIDUAL, stated rather than papered over: a path bound to a variable first
# (`_pc="$PREFIX/lib/pkgconfig/xeve.pc"`) is not seen. There are eleven such
# bindings in install phases today and they are NOT all benign, which is the
# part worth writing down -- an earlier draft of this comment claimed they were,
# and lcevc was creating its merged archive in the live prefix underneath that
# claim. Eight are in-place `.pc` rewrites (chromaprint, vmaf, srt, openh264,
# vvenc, x265, xeve, xevd) that overwrite a file default_install already staged
# under the same name, and so are correct against the live prefix. The other
# three are a read source (shaderc's _src), an `rm` target (meson's _live), and
# the directory lcevc reads its split archives from and then deletes them in
# (_libdir). A twelfth was lcevc's `ar` destination; this branch moved it to the
# stage, which is why it is no longer in the census. Closing the gap means
# resolving assignments AND recognising the write-tmp-then-mv idiom the eight
# use -- a parser, not a grep -- so what guards it is that the census is here.
_scanned=0
_offenders=""
for _f in $(find recipes -name '*.sh' | sort); do
  for _fn in pkg_install pkg_post_install; do
    _body=$(_fn_body "$_f" "$_fn")
    [ -n "$_body" ] || continue
    _scanned=$((_scanned + 1))
    _hits=$(printf '%s\n' "$_body" | sed 's/[[:space:]]*#.*$//' \
      | grep -nE '(^|[[:space:]])(cp|install|ln|tee|mv|ar)([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^|;]*"[$]PREFIX/|[^>]>[[:space:]]*"[$]PREFIX/' \
      || true)
    [ -n "$_hits" ] && _offenders="$_offenders $_f:$_fn:$(printf '%s' "$_hits" | head -1 | cut -d: -f1)"
  done
done
# A floor, because the scan is vacuous if _fn_body ever returns nothing: zero
# offenders across zero phases is the same PASS as zero across all of them.
if [ "$_scanned" -lt 50 ]; then
  _bad no-recipe-installs-past-the-stage "only $_scanned install phase(s) scanned — the scan found nothing because it read nothing"
else
  _verdict no-recipe-installs-past-the-stage "$_offenders"
fi

printf 'DONE: staged-shell-installs\n'

exit "$_fail"
