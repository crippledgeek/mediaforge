#!/bin/sh
# shellcheck shell=sh
# Compiler-flag composition — who owns CFLAGS, and what mediaforge may add.
#
# The GNU coding standards reserve CFLAGS for the user: "Users expect to be able
# to specify CFLAGS freely themselves", and a package must "arrange to pass the
# necessary options to the C compiler independently of CFLAGS". They also
# require CFLAGS to come LAST on the command line "so the user can use CFLAGS to
# override the others".
#
# mediaforge did the opposite for its whole history: mediaforge.sh ASSIGNED
# CFLAGS="-I$PREFIX/include" at startup. That discarded any CFLAGS the user had
# exported, and -- because autotools supplies its own "-g -O2" only when CFLAGS
# is UNSET -- it suppressed that default too, so every autotools recipe compiled
# at gcc's no-flag -O0. The symptom was invisible: nothing errored, and the
# cmake and meson recipes were unaffected because those build systems set
# optimization themselves, so the tree never looked uniformly slow.
#
# Measured before the fix, on lame-3.100 built exactly as mediaforge builds it:
# zero -O and zero -g flags in the build log, and 0.34s to encode a 20s fixture
# against 0.11s for the same source at -O2. Three times slower. tests/
# compiler-flags.sh pins the composition rules below.
#
# SCOPE OF "the user's flags win": composing them last settles precedence on the
# COMMAND LINE, which is the whole story for the autotools recipes. It is not
# the whole story elsewhere. cmake appends CMAKE_C_FLAGS_<CONFIG> AFTER
# CMAKE_C_FLAGS, so a recipe pinned to Release contributes "-O3 -DNDEBUG" after
# the operator's flags and an explicit -O0 does NOT survive there; meson happens
# to place env CFLAGS after its own buildtype flags, so there it does. Measured
# both ways. Anything that wants a coherent tree-wide optimization level has to
# turn PKG_CMAKE_BUILD_TYPE / PKG_MESON_BUILDTYPE too, not just set CFLAGS.

# The optimization mediaforge supplies when the user has expressed no
# preference. -O2 rather than -O3 because it is what autotools itself defaulted
# to before the assignment above suppressed it, so this restores the historical
# behaviour rather than choosing a new one.
MF_DEFAULT_OPT="-O2"

# --- debug levels ------------------------------------------------------------
#
# Three levels, named for what they give you, selected by --debug[=LEVEL].
# The costs below were measured on this tree (lame, dav1d, svtav1 built at each
# level), not estimated:
#
#   symbols   -O2 -g3   assertions off   no measurable cost on the three measured
#   balanced  -Og -g3   assertions ON     ~2x slower
#   full      -O0 -g3   assertions ON     4-5x slower  (bare --debug)
#
# "Measured" means lame, dav1d and svtav1 built at each level and timed on one
# fixture each -- three packages, not the whole tree, and one machine. Treat the
# multipliers as the right order of magnitude rather than as a promise.
#
# The shape follows the tools we drive rather than an invented vocabulary.
# FFmpeg's own configure separates --enable-debug=LEVEL from
# --disable-optimizations and --disable-stripping; meson separates `debug` from
# `optimization`, with `buildtype` as a shorthand; Debian's DEB_BUILD_OPTIONS
# separates `noopt` from `nostrip`. Only cmake conflates them into build types.
# So debug is modelled here as two independent axes -- an optimization level and
# a symbol level -- with the three named levels as the shorthand people type.
#
# -g3 rather than -g2: level 3 adds macro definitions, which is worth having in
# a tree as macro-dense as libav*. -fno-omit-frame-pointer so a backtrace is
# reliable at every level, including `symbols`, where the whole point is getting
# a usable trace out of an optimized build.
#
# -g3 SURVIVES cmake, which is not obvious and was raised in review as a defect.
# cmake appends CMAKE_<LANG>_FLAGS_<CONFIG> after CMAKE_<LANG>_FLAGS, and both
# configs this table selects end in a plain -g (Debug = "-g", RelWithDebInfo =
# "-O2 -g -DNDEBUG"), so the compile line really does read "-g3 ... -g". But a
# trailing -g does not DOWNGRADE an earlier -g3. Measured on gcc 16.2.1 with a
# macro-defining probe: `-g3` and `-g3 -g` both keep the macro definitions,
# while `-g` alone and `-g3 -g0` do not -- so -g0 overrides and plain -g does
# not. No CMAKE_C_FLAGS_DEBUG override is needed, and adding one would be four
# extra -D flags on every cmake invocation for no gain.
#
# The -O half is the mirror image and also holds: Debug supplies no -O at all,
# which is what lets this table's -Og/-O0 arrive through CFLAGS and survive.

# THE LEVEL TABLE. One row per level, and every consumer below reads a field
# from it, so adding a level is adding a row rather than editing five parallel
# case statements that agree only by inspection. The first draft of this file
# had exactly those five, plus a sixth for the accepted-level set, and carried a
# comment noting they had to be kept in step -- which is a hazard described
# rather than removed.
#
# Fields, in order:
#   1 optimization   flows through MF_DEFAULT_OPT so the operator's -O still wins
#   2 symbol flags   empty when no level is active, so a normal build is unchanged
#   3 cmake type     forced OVER the recipe's own; empty leaves the recipe alone
#   4 meson args     buildtype AND b_ndebug, which meson does not tie together
#   5 ffmpeg opts    without --disable-stripping the final binary is stripped
#                    whatever the ~110 libraries did
#   6 canonical name  the level's own name, empty for the no-level row. Validity
#                    is derived from THIS rather than from the symbol flags: a
#                    future strip-only or NDEBUG-only level would legitimately
#                    contribute none, and tying validity to them would reject it
#                    silently. One extra column buys that.
#
# The no-level row is a real row, not a fallback: it states that an ordinary
# build keeps -O2, adds no symbols, leaves both build systems to the recipes,
# and passes the --disable-debug that recipes/ffmpeg.sh has always passed.
mf_debug_field() { # level field-number
  _mf_dbg_f="$2"
  case "$1" in
    symbols)
      set -- '-O2' '-g3 -fno-omit-frame-pointer' 'RelWithDebInfo' \
             '--buildtype=debugoptimized -Db_ndebug=true' \
             '--enable-debug=3 --disable-stripping' 'symbols' ;;
    balanced)
      set -- '-Og' '-g3 -fno-omit-frame-pointer' 'Debug' \
             '--buildtype=debug --optimization=g -Db_ndebug=false' \
             '--enable-debug=3 --disable-stripping --disable-optimizations' 'balanced' ;;
    full)
      set -- '-O0' '-g3 -fno-omit-frame-pointer' 'Debug' \
             '--buildtype=debug -Db_ndebug=false' \
             '--enable-debug=3 --disable-stripping --disable-optimizations' 'full' ;;
    *)
      set -- '-O2' '' '' '' '--disable-debug' '' ;;
  esac
  shift $((_mf_dbg_f - 1))
  printf '%s' "$1"
}

# Named readers. These exist so call sites say what they want rather than
# indexing a table, and so the field numbers appear exactly once each.
mf_debug_opt()         { mf_debug_field "$1" 1; }
mf_debug_cflags()      { mf_debug_field "$1" 2; }
mf_debug_cmake_type()  { mf_debug_field "$1" 3; }
mf_debug_meson_args()  { mf_debug_field "$1" 4; }
mf_debug_ffmpeg_opts() { mf_debug_field "$1" 5; }
mf_debug_name()        { mf_debug_field "$1" 6; }

# Validity is DERIVED from the table rather than being a separate list to keep
# in step: a level is real exactly when the table echoes its own name back. An
# unknown level and the no-level case both fall to the last row, whose name is
# empty, so neither can equal a non-empty input -- bare --debug sets "full",
# never "".
#
# Keyed on the NAME rather than on the symbol flags, which is what the first
# version did. That worked only because every level today happens to contribute
# -g3; a strip-only level would have been rejected as unreal.
mf_debug_level_valid() { [ -n "$1" ] && [ "$(mf_debug_name "$1")" = "$1" ]; }

# True when $1 already contains an -O flag of any spelling: -O, -O0..-O3, -Os,
# -Og, -Ofast.
#
# Anchored on a LEADING SPACE, which is the whole subtlety. The obvious
# `case $flags in *-O*)` also matches flags that merely contain the two
# characters -- "-Wno-Overlength-strings" is the in-tree-plausible one -- and
# would conclude the user had chosen an optimization level, drop the default,
# and put that recipe back at -O0. That is the original defect reintroduced
# through its own fix, so tests/compiler-flags.sh asserts this case directly.
#
# Tabs are folded to spaces first. The anchor needs a space immediately before
# the -O, so a tab-separated CFLAGS ("-g<TAB>-O2" -- what a here-doc or an
# editor-mangled profile produces) would otherwise read as "no -O chosen" and
# get -O2 appended a second time. The duplicate is harmless in effect, since the
# last -O wins, but this function's whole job is that decision.
mf_has_opt_flag() {
  case " $(printf '%s' "$1" | tr '\t' ' ') " in
    *' -O'*) return 0 ;;
    *)       return 1 ;;
  esac
}

# Compose a compiler-flag line: mediaforge's own flags, then the default
# optimization if the user chose none, then the user's flags LAST so they win.
#
# $1 = mediaforge's own flags, $2 = the user's (optional).
#
# The default is SUPPRESSED rather than merely out-ranked when the user has
# chosen a level. Appending it anyway would still give the right answer -- both
# gcc and clang take the last -O -- but a command line showing "-O2 ... -O0" is
# a thing every future reader has to re-derive the precedence rule for.
mf_compose_cflags() {
  _mf_user="${2-}"
  if mf_has_opt_flag "$_mf_user"; then
    _mf_opt=""
  else
    _mf_opt="$MF_DEFAULT_OPT"
  fi
  mf_compose_flags "$1 $_mf_opt" "$_mf_user"
}

# Recompose $CFLAGS/$CXXFLAGS/$LDFLAGS from mediaforge's own accumulated flags
# (MF_OWN_*) plus the user's (MF_USER_*), and export the compiler pair.
#
# Called at EVERY point where mediaforge has finished contributing flags of its
# own -- once at startup, again after option parsing adds -fPIC, and again after
# the per-recipe accumulator files are read. Recomposing rather than appending
# is what keeps the user's flags last no matter how late mediaforge discovers
# one of its own; appending to the already-composed line silently reverses the
# precedence the GNU standards require.
#
# LDFLAGS is deliberately not exported, matching the long-standing behaviour:
# recipes read it as a shell variable and pass it explicitly where they need it.
mf_export_flags() {
  CFLAGS=$(mf_compose_cflags "$MF_OWN_CFLAGS" "${MF_USER_CFLAGS-}")
  CXXFLAGS=$(mf_compose_cflags "$MF_OWN_CXXFLAGS" "${MF_USER_CXXFLAGS-}")
  # SC2034 is wrong here specifically: LDFLAGS has no reader in THIS file, but
  # recipes are sourced into the same shell and read it as a plain variable --
  # the pkg_configure of recipes/crypto/gnutls.sh and recipes/crypto/nettle.sh
  # pass it as LDFLAGS="$LDFLAGS", recipes/image/libpng.sh re-exports it, and
  # recipes/ffmpeg.sh hands it to --extra-ldflags. shellcheck cannot see a
  # cross-file consumer; lib/framework.sh and lib/platform.sh carry the same
  # disable in their headers for the same reason.
  # shellcheck disable=SC2034
  LDFLAGS=$(mf_compose_flags "$MF_OWN_LDFLAGS" "${MF_USER_LDFLAGS-}")
  export CFLAGS CXXFLAGS
}

# The same ownership rule without the optimization default: mediaforge's flags
# first, the user's last. LDFLAGS was assigned the same way CFLAGS was and lost
# the user's value for the same reason, but no linker flag plays the role -O
# plays for the compiler, so there is nothing to default.
#
# mf_compose_cflags is written in terms of this rather than repeating the
# splitting, so the rule "the user goes last" has one implementation and cannot
# drift between the two.
mf_compose_flags() {
  # Unquoted expansion does TWO things, and only one of them is wanted here.
  #
  # Wanted: field splitting. The parts are flag LISTS, and re-splitting them on
  # IFS is what collapses an empty middle part and incidental double spaces into
  # one clean line. Quoting would emit "" as an empty argument and keep the gaps.
  #
  # NOT wanted: pathname expansion. Without `set -f` a glob character anywhere in
  # the operator's CFLAGS is expanded against whatever directory the build
  # happens to be in. Reproduced under dash with two files named `-DFOO=a.h` and
  # `-DFOO=b.h` present: a single `-DFOO=*.h` became `-DFOO=a.h -DFOO=b.h`, and
  # every later compiler invocation inherited both. The old flat assignment never
  # re-split, so this exposure would have been introduced by this refactor.
  #
  # The caller's own noglob setting is saved and restored rather than assumed:
  # POSIX sh has no function-local options, so a bare `set +f` would silently
  # switch globbing back ON for a caller that had deliberately turned it off.
  case $- in
    *f*) _mf_had_noglob=1 ;;
    *)   _mf_had_noglob=0 ;;
  esac
  set -f
  # shellcheck disable=SC2086
  set -- $1 ${2-}
  [ "$_mf_had_noglob" = 1 ] || set +f
  printf '%s' "$*"
}
