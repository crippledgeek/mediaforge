#!/bin/sh
# Pins --debug: the three levels, and that each one reaches ALL FOUR places a
# build's optimization and symbol posture is decided.
#
# That last part is the whole risk. A debug mode that turns three of the four
# knobs produces a tree that still compiles and still links, and whose stack
# traces are simply wrong in the recipes it missed -- which is the hardest kind
# of defect to attribute, because nothing fails. The four are:
#
#   autotools  the composed CFLAGS (via MF_DEFAULT_OPT and the symbol flags)
#   cmake      CMAKE_BUILD_TYPE, forced over whatever the recipe declared
#   meson      buildtype AND b_ndebug, which meson does not tie together
#   FFmpeg     its own --enable-debug/--disable-stripping, or the final binary
#              is stripped regardless of what the ~110 libraries did
#
# Levels and their measured cost, from building lame/dav1d/svtav1 at each:
# symbols -O2 (no measurable slowdown), balanced -Og (~2x), full -O0 (4-5x).
#
# Sources lib/flags.sh conditionally for the same reason tests/compiler-flags.sh
# does: on the merge base the debug functions do not exist, and an unguarded
# source under `set -e` would abort before the DONE sentinel, which
# tests/oracle-baseline.sh reports as an abort rather than as the absent feature.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

if [ -f lib/flags.sh ]; then
  # shellcheck source=lib/flags.sh
  . lib/flags.sh
fi

_have() { command -v "$1" >/dev/null 2>&1; }

# name  fn  level  glob-that-must-match
_d() {
  if _have "$2"; then _out=$("$2" "$3"); else _out=''; fi
  if [ -z "$_out" ] && [ -n "$4" ]; then
    _bad "$1" "$2 produced nothing — claim would be vacuous"
    return
  fi
  _glob "$1" "$_out" "$4" "$2($3)"
}

# name  fn  level  glob-that-must-NOT-match
_d_not() {
  if _have "$2"; then _out=$("$2" "$3"); else _out=''; fi
  _glob_not "$1" "$_out" "$4" "$2($3)"
}

# --- the optimization axis --------------------------------------------------
# The measured reason the levels exist at all.
_d opt-symbols-keeps-o2      mf_debug_opt symbols  '-O2'
_d opt-balanced-is-og        mf_debug_opt balanced '-Og'
_d opt-full-is-o0            mf_debug_opt full     '-O0'
# No debug level must leave the default exactly as it was, so an ordinary build
# is unchanged by this feature existing.
_d opt-default-unchanged     mf_debug_opt ''       '-O2'

# --- the symbol axis --------------------------------------------------------
# -g3 rather than -g2: level 3 adds macro definitions, and libav* is macro-dense.
_d sym-symbols-has-g3        mf_debug_cflags symbols  '*-g3*'
_d sym-balanced-has-g3       mf_debug_cflags balanced '*-g3*'
_d sym-full-has-g3           mf_debug_cflags full     '*-g3*'
# Frame pointers at EVERY level including symbols -- an optimized build whose
# backtrace is unreliable defeats the only purpose that level has.
_d sym-symbols-frame-pointer mf_debug_cflags symbols  '*-fno-omit-frame-pointer*'
# ...and nothing at all when no level is active.
if _have mf_debug_cflags && [ -z "$(mf_debug_cflags '')" ]; then
  _pass sym-none-when-no-debug
else
  _bad sym-none-when-no-debug "expected empty, got [$( _have mf_debug_cflags && mf_debug_cflags '' )]"
fi

# --- cmake ------------------------------------------------------------------
# Debug is the only stock cmake type that does NOT define NDEBUG, which is how
# assertions come on; it also sets -g and no -O, which is what lets the level's
# own -Og/-O0 arrive through CFLAGS and survive.
_d cmake-symbols-relwithdebinfo mf_debug_cmake_type symbols  'RelWithDebInfo'
_d cmake-balanced-debug         mf_debug_cmake_type balanced 'Debug'
_d cmake-full-debug             mf_debug_cmake_type full     'Debug'
# RelWithDebInfo keeps NDEBUG, so `symbols` must NOT be the assertions-on type.
_d_not cmake-symbols-not-debug  mf_debug_cmake_type symbols  'Debug'
# Empty when no level: the recipe's own declared type stands.
if _have mf_debug_cmake_type && [ -z "$(mf_debug_cmake_type '')" ]; then
  _pass cmake-none-when-no-debug
else
  _bad cmake-none-when-no-debug "expected empty"
fi

# --- meson ------------------------------------------------------------------
# b_ndebug named EXPLICITLY at every level. meson documents that -Ddebug=false
# does not define NDEBUG -- unlike cmake, where the build type carries it -- so
# leaving it implicit is how the cmake and meson halves of one tree end up
# disagreeing about whether assertions are live.
_d meson-symbols-ndebug-true   mf_debug_meson_args symbols  '*-Db_ndebug=true*'
_d meson-balanced-ndebug-false mf_debug_meson_args balanced '*-Db_ndebug=false*'
_d meson-full-ndebug-false     mf_debug_meson_args full     '*-Db_ndebug=false*'
# -Og has no meson buildtype; it is the separate optimization option.
_d meson-balanced-optimization-g mf_debug_meson_args balanced '*--optimization=g*'
_d meson-symbols-debugoptimized  mf_debug_meson_args symbols  '*--buildtype=debugoptimized*'
_d meson-full-debug-buildtype    mf_debug_meson_args full     '*--buildtype=debug*'

# --- FFmpeg -----------------------------------------------------------------
# Without --disable-stripping the final binary is stripped whatever the ~110
# libraries did, because FFmpeg's Makefile derives a stripped ffmpeg from
# ffmpeg_g. This is the knob whose absence would make every other one pointless.
_d ff-symbols-no-strip   mf_debug_ffmpeg_opts symbols  '*--disable-stripping*'
_d ff-balanced-no-strip  mf_debug_ffmpeg_opts balanced '*--disable-stripping*'
_d ff-full-no-strip      mf_debug_ffmpeg_opts full     '*--disable-stripping*'
_d ff-full-enables-debug mf_debug_ffmpeg_opts full     '*--enable-debug=3*'
# balanced/full stop FFmpeg adding its own -O3 over the level's choice...
_d ff-full-disables-opt      mf_debug_ffmpeg_opts full     '*--disable-optimizations*'
# ...but `symbols` keeps FFmpeg optimized, which is that level's entire point.
_d_not ff-symbols-keeps-opt  mf_debug_ffmpeg_opts symbols  '*--disable-optimizations*'
# With no level, the historical flag is unchanged.
_d ff-none-disables-debug    mf_debug_ffmpeg_opts ''       '--disable-debug'

# --- the accepted level set -------------------------------------------------
for _lvl in symbols balanced full; do
  if _have mf_debug_level_valid && mf_debug_level_valid "$_lvl"; then
    _pass "level-accepted-$_lvl"
  else
    _bad "level-accepted-$_lvl" "mf_debug_level_valid rejected it"
  fi
done
# A typo must be rejected rather than silently producing a non-debug build --
# `--debug=fyll` quietly building Release is the failure this guards.
for _bad_lvl in fyll Debug release ''; do
  if _have mf_debug_level_valid && mf_debug_level_valid "$_bad_lvl"; then
    _bad "level-rejected-${_bad_lvl:-empty}" "accepted an invalid level"
  elif _have mf_debug_level_valid; then
    _pass "level-rejected-${_bad_lvl:-empty}"
  else
    _bad "level-rejected-${_bad_lvl:-empty}" "mf_debug_level_valid is not defined"
  fi
done

# --- the wiring, not just the decisions -------------------------------------
# The functions above are pure; these assert that something actually CALLS them.
# A correct table nothing consults is the failure mode this whole file exists
# for, and it is invisible to every assertion above.
_wired() { # name  file  needle
  if grep -qF -- "$3" "$2" 2>/dev/null; then _pass "$1"; else _bad "$1" "$2 never calls $3"; fi
}
_wired wired-cmake       lib/framework.sh 'mf_debug_cmake_type'
_wired wired-meson       lib/framework.sh 'mf_debug_meson_args'
_wired wired-ffmpeg      recipes/ffmpeg.sh 'mf_debug_ffmpeg_opts'
_wired wired-cflags      mediaforge.sh 'mf_debug_cflags'
_wired wired-opt         mediaforge.sh 'mf_debug_opt'

# The two greps above prove only that the identifiers OCCUR. The load-bearing
# fact is ORDER: MF_DEFAULT_OPT is reassigned per level, and mf_export_flags
# recomposes CFLAGS from it afterwards. Move the debug block below that call and
# every grep-based assertion still passes while the build ships with no debug -O
# anywhere. So assert the ordering structurally -- computed, never a line number
# written into a comment, which tests/comment-citations.sh forbids for good
# reason.
_ord_dbg=$(grep -n 'MF_DEFAULT_OPT=.(mf_debug_opt' mediaforge.sh | head -1 | cut -d: -f1)
_ord_ok=no
if [ -n "$_ord_dbg" ]; then
  while IFS= read -r _n; do
    [ "$_n" -gt "$_ord_dbg" ] && _ord_ok=yes
  done <<EOF
$(grep -n 'mf_export_flags' mediaforge.sh | cut -d: -f1)
EOF
fi
if [ "$_ord_ok" = yes ]; then
  _pass level-applied-before-flags-are-composed
else
  _bad level-applied-before-flags-are-composed "no mf_export_flags call follows the debug block"
fi

# ...and the functional counterpart: drive the real composer the way cmd_build
# does and read the resulting CFLAGS. This is what a grep cannot say -- that the
# level's -O and its -g3 both actually arrive.
# No subshell: every call assigns all six inputs before using them, so there is
# nothing for one call to leak into the next, and wrapping it in ( ) only earns
# an SC2030 about a modification that is local by design.
_composed() { # level -> the CFLAGS a build at that level would export
  # Guarded on mf_debug_opt, not mf_export_flags: the latter EXISTS on the merge
  # base (it is this branch's parent's work), so guarding on it let the base run
  # fall through to an undefined mf_debug_cflags and emit a command-not-found.
  # The guard has to name something only this branch introduces.
  command -v mf_debug_opt >/dev/null 2>&1 || { printf ''; return; }
  MF_OWN_CFLAGS="-I/p/include -fPIC $(mf_debug_cflags "$1")"
  MF_OWN_CXXFLAGS="$MF_OWN_CFLAGS"
  MF_OWN_LDFLAGS="-L/p/lib"
  MF_USER_CFLAGS=""
  MF_USER_CXXFLAGS=""
  MF_USER_LDFLAGS=""
  MF_DEFAULT_OPT=$(mf_debug_opt "$1")
  mf_export_flags
  printf '%s' "$CFLAGS"
}
for _pair in 'full:-O0' 'balanced:-Og' 'symbols:-O2'; do
  _lv=${_pair%%:*}; _want=${_pair#*:}
  _got=$(_composed "$_lv")
  case "$_got" in
    *"$_want"*)
      case "$_got" in
        *-g3*) _pass "composed-$_lv-has-opt-and-symbols" ;;
        *)     _bad "composed-$_lv-has-opt-and-symbols" "no -g3 in [$_got]" ;;
      esac ;;
    *) _bad "composed-$_lv-has-opt-and-symbols" "no $_want in [$_got]" ;;
  esac
done

# The cmake counterpart of the meson _mf_bt_count harness below: drive the real
# helper and read the build type it emits. wired-cmake is a grep; this asserts
# the value, including that a recipe's own type still wins when no level is set,
# which is the branch's load-bearing default-path claim.
# ONE harness for "what command line does framework helper X emit at level Y".
# There were two, written by copying: same subshell, same run() stub, same
# eval-the-function-body mechanism, same pair of suppressions, differing only in
# which helper they loaded and how they filtered the output. They had already
# drifted -- the cmake copy sourced lib/flags.sh and the meson copy did not,
# working only because this file sources it at the top. Converged so the
# mechanism has one definition and cannot drift again.
#
# The variables and run() below have no reader the linter can see: their consumer
# is the helper body eval'd two lines down, and shellcheck does not follow eval.
# They ARE read -- that is the entire mechanism -- so the finding is wrong here
# rather than tolerated.
_emitted() { # helper-name  level  [args-to-the-helper...]
  _em_fn="$1"; _em_lvl="$2"; shift 2
  # shellcheck disable=SC2034
  ( PREFIX=/PFX; PKG_CMAKE_BUILD_TYPE="Release"; PKG_MESON_BUILDTYPE=""
    MF_DEBUG_LEVEL="$_em_lvl"
    # shellcheck disable=SC2329
    run() { printf '%s
' "$*"; }
    . lib/flags.sh 2>/dev/null || exit 0
    eval "$(sed -n "/^$_em_fn() {/,/^}/p" lib/framework.sh)"
    "$_em_fn" "$@" ) 2>/dev/null
}

_mf_cmake_bt() { # level -> the -DCMAKE_BUILD_TYPE mf_cmake emits
  _emitted mf_cmake "$1" . | tr ' ' '
' | grep -- '-DCMAKE_BUILD_TYPE=' | head -1
}
for _pair in ':-DCMAKE_BUILD_TYPE=Release' 'symbols:-DCMAKE_BUILD_TYPE=RelWithDebInfo' 'balanced:-DCMAKE_BUILD_TYPE=Debug' 'full:-DCMAKE_BUILD_TYPE=Debug'; do
  _lv=${_pair%%:*}; _want=${_pair#*:}
  # Gated like the meson loop: on the merge base mf_cmake exists and knows
  # nothing of debug levels, so the no-level row -- "a recipe's own Release still
  # wins" -- is true there too and passes having verified nothing.
  if ! command -v mf_debug_cmake_type >/dev/null 2>&1; then
    _bad "cmake-emits-${_lv:-none}" "debug support absent — claim would be vacuous"
    continue
  fi
  _got=$(_mf_cmake_bt "$_lv")
  if [ "$_got" = "$_want" ]; then
    _pass "cmake-emits-${_lv:-none}"
  else
    _bad "cmake-emits-${_lv:-none}" "got [$_got] want [$_want]"
  fi
done
_wired wired-cli-flag    mediaforge.sh '--debug='
# LTO discards the per-function debug info that makes stepping work, so the two
# together yield a slow build with unreliable symbols.
# Anchored on the WARNING text, not on `ENABLE_LTO=false` -- that string is the
# global default and exists on the base, so the first version of this assertion
# passed there and guarded nothing. oracle-baseline caught it.
_wired wired-lto-conflict mediaforge.sh 'forces LTO off'
# FFmpeg's configure picks optflags in the order small -> optimizations -> none,
# so --enable-small silently beats the level for libav* while the ~110
# dependencies still honour it. Warned about rather than left to be discovered.
_wired wired-small-conflict mediaforge.sh 'overrides --debug for FFmpeg itself'
# A dry run must not record a level for a build that never happened, or the next
# real build believes the workspace already matches and skips the guard.
_wired wired-dryrun-no-write mediaforge.sh 'DRY_RUN:-false}" != true'

# --- exactly one --buildtype reaches meson ----------------------------------
# The first wiring passed the recipe's buildtype AND the level's, in that order.
# meson accepts the duplicate and takes the last, so it WORKED -- which is what
# makes it worth pinning: nothing would have failed, and the build log would
# have read `--buildtype=release --buildtype=debug` forever.
_mf_bt_count() { # level -> how many --buildtype the helper emits
  _emitted mf_meson "$1" build | tr ' ' '
' | grep -c -- '--buildtype=' || printf '0'
}
for _lvl in '' symbols balanced full; do
  # On the merge base mf_meson exists but knows nothing of debug levels, so it
  # emits exactly one --buildtype for every input and this claim passes having
  # verified nothing. Gate on the debug support being present, which is the
  # thing actually under test.
  if ! _have mf_debug_meson_args; then
    _bad "meson-one-buildtype-${_lvl:-none}" "debug support absent — claim would be vacuous"
    continue
  fi
  _n=$(_mf_bt_count "$_lvl")
  if [ "$_n" = 1 ]; then
    _pass "meson-one-buildtype-${_lvl:-none}"
  else
    _bad "meson-one-buildtype-${_lvl:-none}" "emitted $_n --buildtype flags"
  fi
done

printf 'DONE: debug-levels\n'
exit "$_fail"
