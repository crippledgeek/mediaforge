#!/bin/sh
# Pins --debug: the three levels, and that each one reaches ALL SEVEN places a
# build's optimization and symbol posture is decided.
#
# That last part is the whole risk. A debug mode that turns four of the five
# knobs produces a tree that still compiles and still links, and whose stack
# traces are simply wrong in the recipes it missed -- which is the hardest kind
# of defect to attribute, because nothing fails. The five build systems that
# read the environment are below; the sixth (make on an upstream Makefile) and
# seventh (nvcc) have their own section banners further down. They are:
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
# composed CFLAGS.
#
# ONE exemption, and it is real: nv-codec runs make to install ffnvcodec's
# headers and compiles nothing, so it has no flags to carry. The first version
# of this list also named amf, vaapi, ladspa and vapoursynth "for the same
# reason" -- but those four contain no `make` at all, so they never reach the
# gate below and the exemption never fired for them. Four false citations that
# taught the next reader those recipes run make; rotted before being committed.
_mf_headers_only=' nv-codec.sh '

# Fold backslash continuations before matching: gsm, bzip2 and librtmp all put
# the macro on the line AFTER `run make`, and a line-oriented grep reads those
# as a bare make and reports the defect this file exists to catch.

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

# The READER gets its own assertion, because everything below trusts it. Reverting
# it to the any-line terminator and dropping a defective recipe in the tree does
# not fail anything above -- the recipe simply stops being read, which is the
# failure mode itself. Fixture rather than a real recipe: the shapes that break
# extraction (`${VAR}` at end of line, a brace group) are ones no recipe happens
# to contain today, which is exactly why the bug survived review of the recipes.
_mf_fx=$(mktemp) || { printf 'FAIL [reader-fixture]\n' >&2; exit 1; }
trap 'rm -f "$_mf_fx"' EXIT INT TERM
cat > "$_mf_fx" <<'FIXTURE'
pkg_build() {
  run make CFLAGS="$CFLAGS" libfoo.a
  _v=${SOMEVAR}
  run make libextra.a
}
FIXTURE
if _fn_body "$_mf_fx" pkg_build | grep -q 'libextra'; then
  _pass reader-reads-past-a-line-ending-in-brace
else
  _bad reader-reads-past-a-line-ending-in-brace \
    "extraction stopped early; every scan below silently skips whatever follows"
fi
# ...and a one-line phase must not swallow the rest of the file.
cat > "$_mf_fx" <<'FIXTURE'
pkg_build() { run make CFLAGS="$CFLAGS" libfoo.a; }
PKG_AFTER="not part of the phase"
FIXTURE
if _fn_body "$_mf_fx" pkg_build | grep -q 'PKG_AFTER'; then
  _bad reader-stops-at-a-one-line-phase "read past the closing brace of a one-line phase"
else
  _pass reader-stops-at-a-one-line-phase
fi
rm -f "$_mf_fx"

_mf_scanned=0
_mf_seen=""
for _r in $(find recipes -name '*.sh' | sort); do
  # recipes/ffmpeg.sh is not a recipe in this sense: cmd_build sources it
  # directly rather than through run_recipe(), so it defines no pkg_* phases and
  # the "no pkg_build body" rule below does not describe it. Its own flags come
  # from the ffmpeg column and --extra-cflags, both asserted earlier in this
  # file. It reaches this loop only because the exclusion below is now anchored.
  case "$_r" in recipes/ffmpeg.sh) continue ;; esac
  grep -qE 'run make' "$_r" || continue
  # Anchored on how these are INVOKED, because an unanchored word matches
  # comments too: a future comment in giflib.sh reading "unlike the meson
  # recipes" would drop giflib from the scan entirely, and with five candidates
  # against a floor of four, exactly one recipe can vanish without tripping
  # make-scan-found-recipes below.
  grep -qE 'run \./(configure|Configure)|mf_cmake|mf_meson|run cargo|PKG_CMAKE=true|PKG_REQUIRES_MESON=true' "$_r" && continue
  case "$_mf_headers_only" in *" $(basename "$_r") "*) continue ;; esac
  _mf_scanned=$((_mf_scanned + 1))
  _mf_seen="$_mf_seen $(basename "$_r")"
  _mf_name="make-carries-flags-$(basename "$_r" .sh)"
  _mf_body=$(_fn_body "$_r" pkg_build)
  # An empty body means either the recipe defines no pkg_build -- in which case
  # the framework's default_build runs a bare `make -j`, which is the defect --
  # or the extraction above stopped matching. Both must fail rather than pass an
  # unread recipe: this is the mutation the whole-file version missed.
  if [ -z "$_mf_body" ]; then
    _bad "$_mf_name" "no pkg_build body to read — a bare default_build, or a shape the scan cannot see"
    continue
  fi
  # The EFFECTIVE body: the phase plus the bodies of any same-file helpers it
  # calls. A recipe may delegate its make to a helper -- librtmp runs the same
  # six settings from four call sites and now routes them through one -- and a
  # scan reading only the phase sees a phase with no make in it at all. Both
  # call shapes count: a $(substitution), which giflib uses to PRINT flags, and
  # a plain invocation, which librtmp uses to RUN make.
  #
  # Only helpers defined in this same recipe are followed: a name resolving to a
  # framework function is not a place this recipe's flags could be hiding.
  _mf_eff="$_mf_body"
  for _mf_h in $(printf '%s\n' "$_mf_body" | grep -oE '(^|[^a-z0-9_])_[a-z0-9_]+' |
                 sed 's/[^_a-z0-9]//g' | sort -u); do
    grep -qE "^${_mf_h}\\(\\)" "$_r" || continue
    _mf_eff="$_mf_eff
$(_fn_body "$_r" "$_mf_h")"
  done

  # EVERY compiling invocation, and two claims, because either alone is
  # satisfiable by a recipe that still builds stripped. The macro spelling is
  # upstream's to dictate -- CFLAGS (bzip2, giflib), CCFLAGS (gsm), XCFLAGS
  # (librtmp) -- so the first matches any *FLAGS=, and the second requires the
  # composed CFLAGS to feed it rather than a fresh literal like -O2.
  # `make clean` is exempt: it compiles nothing, and librtmp runs one first.
  # The "." stands in for the dollar, as elsewhere in this file.
  _mf_bare=$(printf '%s\n' "$_mf_eff" | grep -E 'run make' |
             grep -vE 'run make clean[[:space:]]*$' | grep -vE 'FLAGS=' || true)
  _mf_composed=$(printf '%s\n' "$_mf_eff" | grep -E 'run make' |
                 grep -E 'FLAGS=[^;]*.CFLAGS' || true)
  # giflib's helper PRINTS the flags rather than running make, so the composed
  # CFLAGS sits in the helper body while the FLAGS= macro is on the make line.
  # Follow ONLY the helper named inside that macro's value.
  #
  # An earlier version grepped the whole effective body for [$]CFLAGS, which
  # degraded the claim to "this recipe mentions CFLAGS somewhere". Demonstrated
  # in review: rewriting librtmp's helper to a literal XCFLAGS="-O2 ..." AND
  # adding an unrelated same-file helper that happened to mention $CFLAGS made
  # the mutation pass. Latent rather than live -- no recipe has such a helper --
  # but the fallback has to name the helper it is vouching for.
  #
  # [$]CFLAGS, not .CFLAGS: the dot form -- used elsewhere in this file where a
  # dollar cannot be written -- also matches the macro NAMES, since XCFLAGS and
  # CCFLAGS both end in CFLAGS.
  if [ -z "$_mf_composed" ]; then
    for _mf_h in $(printf '%s\n' "$_mf_eff" | grep -oE 'FLAGS="?[$]\(_[a-z0-9_]+\)' |
                   sed 's/[^_a-z0-9]//g' | sort -u); do
      _uses_composed_cflags "$_r" "$_mf_h" || continue
      _mf_composed="via $_mf_h"
      break
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
# The scan itself can rot: a rename of the phase function, or a find that matches
# nothing, leaves every assertion above unrun and the file green.
#
# Named rather than counted. A floor of "at least four" cannot see ONE recipe
# drop out -- and dropping out silently is what the unanchored exclusion regex
# used to allow, since a comment mentioning meson was enough. Measured: with the
# old regex and one word added to a giflib comment, giflib left the scan and
# nothing failed. A name that disappears fails loudly here instead; a recipe
# legitimately converted to another build system fails here too, which is a
# human deciding to update this line rather than a scan quietly shrinking.
for _mf_want in giflib.sh quirc.sh gsm.sh bzip2.sh librtmp.sh; do
  case "$_mf_seen " in
    *" $_mf_want "*) _pass "make-scan-covers-${_mf_want%.sh}" ;;
    *) _bad "make-scan-covers-${_mf_want%.sh}" \
         "not scanned — excluded by mistake, renamed, or no longer runs make. Scanned:$_mf_seen" ;;
  esac
done

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
# Behavioural, not a restatement of the one-line body. The claim that matters is
# the OPERATOR'S: flags they exported must still reach the preprocessor-only
# checks, because that is what CPPFLAGS="$CFLAGS" gave them and what the first
# version of mf_cppflags silently took away -- an operator with a dependency in
# a non-default prefix would have watched a configure check start failing with
# no error to read. Review caught it; these are so the next narrowing does not
# need a reviewer.
if _have mf_cppflags; then
  _glob cppflags-has-the-prefix-path \
    "$(PREFIX=/p MF_USER_CFLAGS='' mf_cppflags)" '*-I/p/include*' 'mf_cppflags'
  _glob cppflags-keeps-operator-include \
    "$(PREFIX=/p MF_USER_CFLAGS='-I/opt/idn2/include' mf_cppflags)" '*-I/opt/idn2/include*' 'mf_cppflags'
  _glob cppflags-keeps-operator-define \
    "$(PREFIX=/p MF_USER_CFLAGS='-DHAVE_BAR' mf_cppflags)" '*-DHAVE_BAR*' 'mf_cppflags'
  # ...while mediaforge's OWN composed optimization and symbol flags stay out,
  # which is the doubling this helper exists to stop. Asserted with an empty
  # operator half: an operator who exports -O2 themselves is entitled to it here.
  _glob_not cppflags-omits-composed-opt \
    "$(PREFIX=/p MF_USER_CFLAGS='' mf_cppflags)" '*-O*' 'mf_cppflags'
  _glob_not cppflags-omits-composed-g \
    "$(PREFIX=/p MF_USER_CFLAGS='' mf_cppflags)" '*-g3*' 'mf_cppflags'
else
  for _a in cppflags-has-the-prefix-path cppflags-keeps-operator-include \
            cppflags-keeps-operator-define cppflags-omits-composed-opt \
            cppflags-omits-composed-g; do
    _bad "$_a" "mf_cppflags absent — claim would be vacuous"
  done
fi

# --- the eighth path: build files that turn the knobs back --------------------
# Three archives came out of a full --debug=full build without what the level
# promised, and none of them was a missing knob -- each was a project's own build
# file overriding one we had already set. They are pinned here by mechanism.
#
# liblc3: its meson.build carries default_options: ['b_lto=true']. Our
# --buildtype replaces the buildtype sitting right beside it and leaves b_lto
# alone, and an LTO object holds GIMPLE rather than DWARF -- so liblc3.a had zero
# .debug_info across all 12 members while meson-info reported buildtype debug,
# debug True and optimization 0, every one of them correctly applied. --debug's
# help text promises "Forces LTO off"; for meson recipes it now does.
for _lv in symbols balanced full; do
  _d "meson-lto-off-$_lv" mf_debug_meson_args "$_lv" '*-Db_lto=false*'
done
if _have mf_debug_meson_args && [ -z "$(mf_debug_meson_args '')" ]; then
  _pass meson-none-when-no-debug
else
  _bad meson-none-when-no-debug "expected empty"
fi

# The assertions column exists because libvpx needed to ASK. Its --enable-debug
# keeps symbols and drops -DNDEBUG in one flag, so a recipe reaching for it at
# `symbols` would turn assertions on at the one level promising no measurable
# cost. The concept was already spelled three ways above -- meson's b_ndebug,
# cmake's Debug-vs-RelWithDebInfo, FFmpeg's --disable-optimizations -- and a
# build system speaking none of them had no way to read it.
_d assertions-symbols-off  mf_debug_assertions symbols  'off'
_d assertions-balanced-on  mf_debug_assertions balanced 'on'
_d assertions-full-on      mf_debug_assertions full     'on'
if _have mf_debug_assertions && [ -z "$(mf_debug_assertions '')" ]; then
  _pass assertions-none-when-no-debug
else
  _bad assertions-none-when-no-debug "expected empty"
fi
# The column must AGREE with the two vocabularies that already encode it, or the
# tree says two different things about the same level.
_d assertions-agree-symbols-meson mf_debug_meson_args symbols  '*-Db_ndebug=true*'
_d assertions-agree-full-meson    mf_debug_meson_args full     '*-Db_ndebug=false*'

# libvpx builds libvpx_g.a with the symbols and installs a stripped copy of it
# (measured: 52.8 MB / 460 debug sections vs 4.9 MB / none). It must disable
# that strip, and it must read the assertions column rather than deciding for
# itself which levels want -DNDEBUG dropped.
_wired vpx-disables-the-strip   recipes/video/libvpx.sh 'HAVE_GNU_STRIP=no'
# ...and disables vpx's OWN -O3, which it appends after the composed CFLAGS and
# which therefore decides. Verified the hard way: with the strip fixed but this
# flag absent, the rebuilt archive's producer read "-g3 -g -O0 -O3" -- every
# symbol the level asked for, compiled at the optimization level it did not.
_wired vpx-disables-its-own-opt recipes/video/libvpx.sh '--disable-optimizations'
_wired vpx-reads-assertions     recipes/video/libvpx.sh 'mf_debug_assertions'
# ...and APPLIES both, rather than defining helpers nothing calls. Matched with
# a regex whose "." stands in for the dollar, the same way the rav1e assertion
# above does it, so this file contains no literal $( inside quotes for the
# linter to read as a failed expansion.
# Folded through _logical_lines first: the call sits on a continuation line, and a
# line-oriented grep reads the invocation and its arguments as separate lines --
# the same trap the bare-make scan above folds for.
if _logical_lines recipes/video/libvpx.sh |
     grep -qE -- 'run ./configure.*.\(_libvpx_debug_configure\)'; then
  _pass vpx-applies-configure
else
  _bad vpx-applies-configure "the configure helper is defined but never called"
fi
if _logical_lines recipes/video/libvpx.sh |
     grep -qE -- 'run make.*.\(_libvpx_debug_make\)'; then
  _pass vpx-applies-make
else
  _bad vpx-applies-make "the make helper is defined but never called"
fi

# libilbc ASSIGNS CMAKE_C_FLAGS, replacing what cmake takes from the
# environment. Fixed by patch, not by a -D: a plain set() in a CMakeLists makes
# a normal variable that shadows the cache entry -DCMAKE_C_FLAGS_DEBUG writes,
# so the flag would be accepted and ignored.
_wired ilbc-applies-the-patch recipes/audio/libilbc.sh 'libilbc-cmake-append-flags.patch'
if [ -f patches/libilbc-cmake-append-flags.patch ]; then
  _pass ilbc-patch-exists
else
  _bad ilbc-patch-exists "recipe applies a patch that is not in the tree"
fi
# The patch must APPEND rather than assign -- for BOTH languages. libilbc
# declares LANGUAGES C CXX and compiles two C++ translation units into the
# library, so a C-only fix leaves those two objects with upstream's assigned
# flags and none of the level's.
for _mf_lang in C CXX; do
  if grep -qE "^\+.*[$]{CMAKE_${_mf_lang}_FLAGS}" patches/libilbc-cmake-append-flags.patch 2>/dev/null; then
    _pass "ilbc-patch-appends-$_mf_lang"
  else
    _bad "ilbc-patch-appends-$_mf_lang" "the patch does not carry the existing ${_mf_lang} flags through"
  fi
done

# ...and the patch must actually APPLY in full. This is the assertion that was
# missing, and its absence let a real defect ship inside the commit that claimed
# to fix it: the header read @@ -53,7 +53,7 @@ while the body carried 12 lines
# either side. GNU patch honours the DECLARED counts -- it consumed seven lines,
# applied the C half, dropped the C++ half, and exited 0. Nothing noticed: the
# recipe's guard only fires on a non-zero exit, and the old assertion here
# grepped the patch TEXT for a string that was present in the half it never
# applied.
#
# Scanned across every patch in the tree rather than this one, because the
# failure is a property of the format, not of libilbc: a hand-edited hunk header
# is silent everywhere. Lives in this file rather than its own because
# tests/oracle-baseline.sh requires every assertion in a NEWLY ADDED file to
# fail on the merge base, and the other patches in patches/ are well-formed
# there -- those assertions would pass, and the gate would reject the file.
# One implementation, two callers: the tree scan below and the fixtures after it.
_mf_scan_hunks() { # patch-file
  awk '
    function flush() {
      if (hdr != "" && (o != declo || n != decln))
        print hdr " declares " declo "/" decln " but body has " o "/" n
      hdr = ""
    }
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        l = line[i]
        # A file header is the PAIR "--- x" / "+++ y". Matching "--- " alone is
        # wrong: a diff that REMOVES a source line beginning with "-- " renders
        # as "--- a comment", which is a body line, and treating it as a header
        # reports a well-formed patch as malformed. SQL, Lua, Haskell and Ada
        # all comment with --, and no patch in the tree happens to today.
        if (l ~ /^--- / && line[i + 1] ~ /^\+\+\+ /) { flush(); i++; continue }
        if (l ~ /^diff /) { flush(); continue }
        # git format-patch ends the diff with the signature delimiter "-- ",
        # followed by a version line; without this the trailer counts as removed
        # lines against the last hunk.
        if (l == "-- ") { flush(); continue }
        if (l ~ /^@@/) {
          flush()
          hdr = l; o = 0; n = 0
          split(l, f, " ")
          declo = f[2]; decln = f[3]
          sub(/^-[0-9]+,?/, "", declo); sub(/^\+[0-9]+,?/, "", decln)
          if (declo == "") declo = 1
          if (decln == "") decln = 1
          continue
        }
        if (hdr == "") continue
        if (l ~ /^\\/) continue
        if (l ~ /^-/) { o++; continue }
        if (l ~ /^\+/) { n++; continue }
        o++; n++
      }
      flush()
    }' "$1"
}

for _mf_patch in patches/*.patch; do
  [ -f "$_mf_patch" ] || continue
  # Three shapes a naive counter gets wrong, each found by running it against
  # the fourteen patches in the tree rather than only against the two being
  # fixed here:
  #   - an EMPTY line is a legitimate context line (a diff may drop the leading
  #     space on a blank line) -- oapv-install-libdir has them, and reading them
  #     as "not context" under-counts;
  #   - a multi-file patch's next "--- a/..." / "+++ b/..." header must END the
  #     current hunk, not be counted as its -/+ lines -- libjxl-static-linking
  #     patches two files and over-counted by exactly one each way;
  #   - "\ No newline at end of file" belongs to neither side.
  # All fourteen pass with these handled, which is what says the scan measures
  # the format rather than its own assumptions.
  _mf_bad_hunk=$(_mf_scan_hunks "$_mf_patch")
  if [ -z "$_mf_bad_hunk" ]; then
    _pass "patch-hunk-counts-$(basename "$_mf_patch" .patch)"
  else
    _bad "patch-hunk-counts-$(basename "$_mf_patch" .patch)" "$_mf_bad_hunk"
  fi
done


# The scanner gets its own fixtures, both directions. Its failure mode is
# a false FAIL on a correct patch -- the pre-push gate stopping a build for a
# patch that is fine -- and nothing in patches/ exercises the shapes that cause
# it, which is exactly why they need synthesising:
#   - a diff that REMOVES a line beginning with "-- " renders as "--- a comment"
#     and is a body line, not a file header (SQL, Lua, Haskell, Ada comment that
#     way);
#   - a diff that ADDS one beginning with "++ " renders as "+++ b tricky";
#   - git format-patch ends with the signature delimiter "-- " and a version.
# All three were reported malformed by the first version of the rule.
_mf_pp=$(mktemp -d) || { printf 'FAIL [patch-scan-fixture]\n' >&2; exit 1; }
trap 'rm -rf "$_mf_pp"' EXIT INT TERM
printf '%s\n' '--- a/x.sql' '+++ b/x.sql' '@@ -1,3 +1,2 @@' ' keep' '--- a comment' ' tail' > "$_mf_pp/removed-dashes.patch"
printf '%s\n' '--- a/z.c' '+++ b/z.c' '@@ -1,3 +1,3 @@' ' a' '-b' '+c' ' d' '-- ' '2.43.0' > "$_mf_pp/format-patch-trailer.patch"
printf '%s\n' '--- a/w.c' '+++ b/w.c' '@@ -1,2 +1,2 @@' ' a' '-b' '+c' ' d' > "$_mf_pp/genuinely-malformed.patch"
for _mf_fx_patch in removed-dashes format-patch-trailer genuinely-malformed; do
  _mf_patch="$_mf_pp/$_mf_fx_patch.patch"
  _mf_out=$(_mf_scan_hunks "$_mf_patch")
  case "$_mf_fx_patch" in
    genuinely-malformed)
      if [ -n "$_mf_out" ]; then _pass "patch-scan-catches-$_mf_fx_patch"
      else _bad "patch-scan-catches-$_mf_fx_patch" "a body longer than its header declares was not reported"; fi ;;
    *)
      if [ -z "$_mf_out" ]; then _pass "patch-scan-allows-$_mf_fx_patch"
      else _bad "patch-scan-allows-$_mf_fx_patch" "reported a well-formed patch: $_mf_out"; fi ;;
  esac
done
rm -rf "$_mf_pp"

# --- the gate that runs the gates ----------------------------------------
# tests/run.sh names its ~30 test files by hand, so adding a test means
# remembering to wire it -- and forgetting is SILENT: the file passes when run
# directly and the pre-push gate never executes it. tests/ccache.sh shipped that
# way and a security review found it, not this suite.
#
# What made it invisible was a coincidence of wording: the oracle gate prints
# "PASS: tests/ccache.sh -- 9 assertions here, 9 failing on the base", which
# reads exactly like the suite ran it. It had not; oracle-baseline runs newly
# ADDED files against the merge base, which is a different thing from run.sh
# invoking them.
#
# Every tests/*.sh must therefore be named in run.sh, except the library and the
# runner itself, which are sourced or are the thing doing the running.
# The exemptions come from run.sh's own NOT-IN-SUITE line rather than from a
# copy here: four tests assert against a built $PREFIX and stay manual, and a
# second list of them in this file would be free to drift from the first.
_mf_manual=$(sed -n 's/^# NOT-IN-SUITE: //p' tests/run.sh)
if [ -z "$_mf_manual" ]; then
  _bad every-test-file-is-wired-into-run "run.sh carries no NOT-IN-SUITE line — the exemptions cannot be read"
else
  _mf_unwired=""
  for _mf_t in tests/*.sh; do
    _mf_base=$(basename "$_mf_t")
    case "$_mf_base" in
      run.sh|lib-assert.sh|lib-provenance.sh) continue ;;
    esac
    case " $_mf_manual " in *" $_mf_base "*) continue ;; esac
    # Anchored on the INVOCATION, not on the name appearing anywhere: run.sh's
    # own comments name test files (this scan's rationale names two of them),
    # and an unanchored grep counts that prose as wiring. Measured -- deleting
    # `sh tests/ccache.sh` from run.sh left this assertion green, because the
    # paragraph explaining why the assertion exists still mentioned the file.
    grep -qE "^[[:space:]]*sh $_mf_t([[:space:]]|\$)" tests/run.sh ||
      _mf_unwired="$_mf_unwired $_mf_base"
  done
fi
if [ -n "$_mf_manual" ]; then
  if [ -z "$_mf_unwired" ]; then
    _pass every-test-file-is-wired-into-run
  else
    _bad every-test-file-is-wired-into-run "never executed by tests/run.sh:$_mf_unwired"
  fi
fi

printf 'DONE: debug-levels\n'
exit "$_fail"
