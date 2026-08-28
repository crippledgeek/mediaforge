#!/bin/sh
# Pins --debug: the three levels, and that each one reaches ALL FIVE places a
# build's optimization and symbol posture is decided.
#
# That last part is the whole risk. A debug mode that turns four of the five
# knobs produces a tree that still compiles and still links, and whose stack
# traces are simply wrong in the recipes it missed -- which is the hardest kind
# of defect to attribute, because nothing fails. The four are:
#
#   autotools  the composed CFLAGS (via MF_DEFAULT_OPT and the symbol flags)
#   cmake      CMAKE_BUILD_TYPE, forced over whatever the recipe declared
#   meson      buildtype AND b_ndebug, which meson does not tie together
#   FFmpeg     its own --enable-debug/--disable-stripping, or the final binary
#              is stripped regardless of what the ~110 libraries did
#   cargo      rav1e is compiled by cargo, and Rust reads no CFLAGS at all, so
#              the level has to be restated in cargo's own vocabulary -- and its
#              manifest pins lto = "thin", which --debug promises to force off
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
# rav1e is the one recipe the composed CFLAGS cannot reach -- cargo compiles
# Rust, which reads no CFLAGS -- so the level is restated in cargo's vocabulary.
# openssl needs none: it reads CFLAGS from the environment and puts it last,
# verified against its generated makefile. Asserted below against the table's
# cargo column and the recipe's use of it, not by grepping for a literal.

# The cargo column, asserted against the TABLE rather than against a copy of it.
# The first version of these assertions re-implemented the recipe's own case
# statement inside this file, so they verified that the TEST mapped full->0 --
# changing the recipe, or deleting its block entirely, left them green. The
# mapping now lives in lib/flags.sh, so the accessor below is the real code.
#
# rav1e is the fifth build system the level has to reach, and the only one the
# composed CFLAGS cannot touch, because cargo compiles Rust.
_d cargo-symbols-debug   mf_debug_cargo_env symbols  '*CARGO_PROFILE_RELEASE_DEBUG=2*'
_d cargo-balanced-opt1   mf_debug_cargo_env balanced '*CARGO_PROFILE_RELEASE_OPT_LEVEL=1*'
_d cargo-full-opt0       mf_debug_cargo_env full     '*CARGO_PROFILE_RELEASE_OPT_LEVEL=0*'
# symbols must NOT pin an opt-level: cargo's release default is opt-level=3, so
# naming 2 would DOWNGRADE the one level that promises no measurable cost.
_d_not cargo-symbols-no-opt-pin mf_debug_cargo_env symbols '*OPT_LEVEL*'
# LTO off at every level. rav1e's manifest pins lto = "thin", and cargo honours
# only the keys the env names -- so without this, --debug leaves rav1e thin-LTO'd
# while the help text promises "Forces LTO off", and LTO is precisely what
# discards the per-function debug info the level exists to produce.
for _lv in symbols balanced full; do
  _d "cargo-lto-off-$_lv" mf_debug_cargo_env "$_lv" '*CARGO_PROFILE_RELEASE_LTO=false*'
done
# ...and nothing at all without a level, so an ordinary build is untouched.
if _have mf_debug_cargo_env && [ -z "$(mf_debug_cargo_env '')" ]; then
  _pass cargo-none-when-no-debug
else
  _bad cargo-none-when-no-debug "expected empty"
fi

# The recipe must APPLY the column rather than rolling its own mapping.
_wired recipe-uses-cargo-column recipes/video/rav1e.sh 'mf_debug_cargo_env'
# ...scoped to the cargo command, not exported: pkg_configure runs in the main
# shell and the framework's save/restore covers only CFLAGS and friends, so an
# export would outlive the recipe.
# Matched with a regex whose "." stands in for the dollar, so this file contains
# no literal $ inside quotes -- the linter reads that as a failed expansion, and
# it is source text being searched for rather than an expansion.
if grep -qE -- 'env .{1}_rav1e_cargo_env' recipes/video/rav1e.sh 2>/dev/null; then
  _pass recipe-scopes-cargo-env
else
  _bad recipe-scopes-cargo-env "rav1e does not scope the overrides to the cargo command"
fi

# --- the sixth path: make run directly on an upstream Makefile ---------------
# Every knob above assumes the recipe's build system READS the environment.
# A recipe that runs make against a hand-written upstream Makefile does not get
# that for free: a Makefile's `CFLAGS = ...` is an ASSIGNMENT, and an assignment
# beats the environment -- only a command-line `make CFLAGS=...` overrides it
# (POSIX make, "Macros": command-line macros take precedence over both).
#
# giflib shipped exactly that shape and nothing caught it. Under --debug=full,
# libgif.a came out of the build with no .debug_* sections at all -- built at
# the Makefile's own -O2, stripped -- while every sibling archive from the same
# run carried -O0 -g3. It compiled, it linked, it ran; the only symptom was
# giflib frames missing from every backtrace. Measured, not reasoned: `readelf`
# on dgif_lib.o found 0 debug sections with the flags in the environment and 2
# with the same flags on the make command line.
#
# So the claim is structural and per-invocation: every make that COMPILES must
# name a flags macro on the command line, and that macro must be fed by the
# composed CFLAGS. The recipes below run make but compile nothing (they install
# headers), so they have nothing to carry.
_mf_headers_only=' amf.sh vaapi.sh ladspa.sh vapoursynth.sh nv-codec.sh '

# Fold backslash continuations before matching: gsm, bzip2 and librtmp all put
# the macro on the line AFTER `run make`, and a line-oriented grep reads those
# as a bare make and reports the defect this file exists to catch.
_mf_logical() { awk '{ if (sub(/\\$/, "")) { buf = buf $0; next } print buf $0; buf = "" }' "$1"; }

# Scoped to pkg_build below, which is the phase that compiles. An earlier
# version scanned the whole recipe and a mutation walked straight through it:
# reverting giflib's BUILD line to a bare `run make` left the file green,
# because its install line still carried the macro and the scan only asked
# whether the recipe mentioned one somewhere. The claim has to be about the
# invocation that does the compiling, not about the file.
#
# Generalized over the function name because the composed-CFLAGS claim below has
# to read a helper's body too, and reading two function bodies two ways is how
# the copies in this file drifted before.
_mf_fn_body() { # file  function-name
  _mf_logical "$1" | awk -v fn="$2" '
    $0 ~ "^[[:space:]]*" fn "\\(\\)" { f = 1 }
    f { print }
    f && /\}[[:space:]]*$/ { f = 0 }'
}

_mf_scanned=0
for _r in $(find recipes -name '*.sh' | sort); do
  grep -qE 'run make' "$_r" || continue
  grep -qE './configure|mf_cmake|meson|cargo|./Configure|PKG_CMAKE=true' "$_r" && continue
  case "$_mf_headers_only" in *" $(basename "$_r") "*) continue ;; esac
  _mf_scanned=$((_mf_scanned + 1))
  _mf_name="make-carries-flags-$(basename "$_r" .sh)"
  _mf_body=$(_mf_fn_body "$_r" pkg_build)
  # An empty body means either the recipe defines no pkg_build -- in which case
  # the framework's default_build runs a bare `make -j`, which is the defect --
  # or the extraction above stopped matching. Both must fail rather than pass an
  # unread recipe: this is the mutation the whole-file version missed.
  if [ -z "$_mf_body" ]; then
    _bad "$_mf_name" "no pkg_build body to read — a bare default_build, or a shape the scan cannot see"
    continue
  fi
  # EVERY compiling invocation, not just one of them, and two claims per recipe
  # because either alone is satisfiable by a recipe that still builds stripped.
  # The macro spelling is upstream's to dictate -- CFLAGS (bzip2, giflib),
  # CCFLAGS (gsm), XCFLAGS (librtmp) -- so the first claim matches any *FLAGS=,
  # and the second requires the composed CFLAGS to feed it rather than a fresh
  # literal like -O2. `make clean` is exempt: it compiles nothing, and librtmp
  # legitimately runs one first. The "." stands in for the dollar, as above.
  _mf_bare=$(printf '%s\n' "$_mf_body" | grep -E 'run make' |
             grep -vE 'run make clean[[:space:]]*$' | grep -vE 'FLAGS=' || true)
  _mf_composed=$(printf '%s\n' "$_mf_body" | grep -E 'run make' |
                 grep -E 'FLAGS=[^;]*.CFLAGS' || true)
  # A recipe may route the value through a helper rather than repeating it at
  # both of its make runs -- giflib does. Follow the helper into its own body
  # instead of demanding the literal on the make line, which would push the
  # recipe to duplicate the string just to satisfy this file.
  if [ -z "$_mf_composed" ]; then
    for _mf_h in $(printf '%s\n' "$_mf_body" | grep -oE '.\(_[a-z0-9_]+\)' | sed 's/[^_a-z0-9]//g'); do
      if _mf_fn_body "$_r" "$_mf_h" | grep -qE '.CFLAGS'; then
        _mf_composed="via $_mf_h"
        break
      fi
    done
  fi
  if [ -n "$_mf_bare" ]; then
    _bad "$_mf_name" "compiles with a make that passes no flags macro: $_mf_bare"
  elif [ -z "$_mf_composed" ]; then
    _bad "$_mf_name" "passes a flags macro that never references the composed CFLAGS"
  else
    _pass "$_mf_name"
  fi
done
# The scan itself can rot: a rename of the phase function, or a find that
# matches nothing, leaves every assertion above unrun and the file green.
if [ "$_mf_scanned" -ge 4 ]; then
  _pass make-scan-found-recipes
else
  _bad make-scan-found-recipes "scanned only $_mf_scanned recipes — the scan matched nothing"
fi

# --- the seventh path: nvcc, and the two ways a recipe can lose the flags -----
# nvcc drives FFmpeg's CUDA compilation and is a third toolchain that reads no
# CFLAGS, so the level has to be restated in its vocabulary exactly as cargo's
# was. It had taken the optimization half through MF_DEFAULT_OPT since before
# --debug existed and took no symbols at all, so a --debug tree carried
# symbol-less CUDA objects while every other object had -g3.
#
# The spelling cannot be copied from the CFLAGS column: nvcc REJECTS -g3
# outright ("nvcc fatal: Unknown option '-g3'", measured against CUDA 13's nvcc,
# which also accepts -g, -lineinfo, -G and any combination of them). So the
# negative assertion below is not stylistic -- a -g3 reaching nvcc fails the
# build rather than degrading it.
_d nvcc-symbols-lineinfo  mf_debug_nvcc symbols  '*-lineinfo*'
_d nvcc-balanced-host-g   mf_debug_nvcc balanced '*-g*'
_d nvcc-full-device-debug mf_debug_nvcc full     '*-G*'
for _lv in symbols balanced full; do
  _d_not "nvcc-no-g3-$_lv" mf_debug_nvcc "$_lv" '*-g3*'
done
if _have mf_debug_nvcc && [ -z "$(mf_debug_nvcc '')" ]; then
  _pass nvcc-none-when-no-debug
else
  _bad nvcc-none-when-no-debug "expected empty"
fi
_wired recipe-uses-nvcc-column recipes/hwaccel/nv-codec.sh 'mf_debug_nvcc'

# meson takes CFLAGS into c_args at SETUP, and `meson configure -Dc_args=...`
# REPLACES that value rather than adding to it. Measured on meson 1.12.0: c_args
# went from [-fPIC, -I/opt/inc, -fno-omit-frame-pointer] to [-march=native]
# alone. recipes/audio/lv2.sh did exactly that to its bundled zix, so that one
# sub-build lost -fPIC, the prefix include path and the frame pointer, while
# keeping -O0/-g from the buildtype -- a partial loss, which is the kind that
# reads as working.
#
# Scanned across every recipe rather than asserted about lv2, because the next
# recipe to reach for `meson configure` will reach for the same option.
# Anchored on meson's option form. An unanchored 'c_args=' also matches
# recipes/other/srt.sh's own _enc_args variable, which has nothing to do with
# meson -- the first version of this assertion reported it as a defect.
_mf_cargs=$(grep -rnE -- '[-]D(c|cpp)_args=' recipes/ 2>/dev/null || true)
if [ -z "$_mf_cargs" ]; then
  _pass no-recipe-replaces-meson-cargs
else
  _bad no-recipe-replaces-meson-cargs "$_mf_cargs"
fi

# The preprocessor-only checks want the include path, not the whole composed
# CFLAGS. Passing CFLAGS as CPPFLAGS works and puts every flag on the compile
# line twice (autoconf compiles with `$CC -c $CFLAGS $CPPFLAGS`), which is how
# nettle and gnutls produced objects whose producer reads "-g3 -g3 -O0 -O0".
# mf_cppflags says it once; these assert nobody goes back to the copy.
_mf_cpp=$(grep -rn 'CPPFLAGS="[$]CFLAGS"' recipes/ 2>/dev/null || true)
if [ -z "$_mf_cpp" ]; then
  _pass no-recipe-passes-cflags-as-cppflags
else
  _bad no-recipe-passes-cflags-as-cppflags "$_mf_cpp"
fi
for _r in recipes/crypto/nettle.sh recipes/crypto/gnutls.sh recipes/image/libpng.sh; do
  _wired "uses-cppflags-helper-$(basename "$_r" .sh)" "$_r" 'mf_cppflags'
done
if _have mf_cppflags; then
  _glob cppflags-is-the-include-path "$(PREFIX=/p mf_cppflags)" '*-I/p/include*' 'mf_cppflags'
  _glob_not cppflags-carries-no-opt  "$(PREFIX=/p mf_cppflags)" '*-O*' 'mf_cppflags'
else
  _bad cppflags-is-the-include-path "mf_cppflags absent — claim would be vacuous"
  _bad cppflags-carries-no-opt      "mf_cppflags absent — claim would be vacuous"
fi

printf 'DONE: debug-levels\n'
exit "$_fail"
