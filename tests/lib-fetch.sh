# shellcheck shell=sh
# fetch() loaded with the state a recipe would have given it.
#
# Every test that drives lib/download.sh directly needs the same four things,
# and none of them is guessable from the failure you get without them:
#
#   * SCRIPT_DIR, because lib/utils.sh locates lib/stage.sh through it (GH-59).
#     mediaforge.sh sets it from $0; a test sourcing the library supplies it.
#   * lib/utils.sh before lib/download.sh, for log/warn/die/command_exists.
#   * DISTDIR, which fetch() reads as the download directory.
#   * PKG_URL / PKG_FILENAME / PKG_DIRNAME, which fetch() reads as the
#     defaults for its three positional arguments.
#
# The duplication that justified this file is the LAST of those, and it is the
# knowledge rather than the four assignments: retyping them is trivial, and the
# reason they are there is not. Both callers carried that reason in prose, in
# two spellings, and NEITHER was accurate about which variable mattered. One
# home means one account, and one chance for it to be wrong -- which is how the
# corrections below came to be found at all.
#
# Which of the three actually bites, measured rather than reasoned:
#
#     _url="${1:-$PKG_URL}"                bare -- aborts only when no URL is
#                                                  passed, which no caller does
#     _file="${2:-${PKG_FILENAME:-...}}"   NESTED `:-` -- unset is always safe,
#                                                  `set -u` or not
#     _dir="${3:-$PKG_DIRNAME}"            bare -- aborts when $3 is omitted OR
#                                                  EMPTY, since `:-` substitutes
#                                                  for null as well as unset
#
# That last distinction is the one worth having written down: a caller passing
# `fetch "$url" "$file" ""` has NOT omitted $3 and still reaches $PKG_DIRNAME.
# tests/download-retry-verify.sh passes exactly that. Verified in sh, dash and
# bash, which agree.
#
# So PKG_DIRNAME is the load-bearing one for any caller without a non-empty
# third argument -- which is both of them. All three are set here anyway:
# which expansion is bare is a property of fetch()'s defaults, not of this
# helper, and a test should not go red the day one of them changes shape.
#
# The failure mode this guards against was for a time SILENT in one direction,
# and the history is kept because the shape recurs. A test asserting that fetch
# FAILS -- tests/fetch-fail-no-cache.sh runs `( fetch ... )` and checks for a
# non-zero status -- could not tell an abort on an unbound variable from the
# die() it was asserting: non-zero either way, no file written either way, so it
# went green having never reached a download. Dropping PKG_DIRNAME left it
# passing.
#
# It does not any more: the request-count assertion in that same test now says
# the origin served nothing, and both tests fail loudly. The quiet direction is
# closed, so what remains justifying this helper is the prose above -- not the
# false pass, which is now guarded.
#
# $_fail is deliberately NOT set here: it belongs to the reporter contract at
# the head of tests/lib-assert.sh, which asks each test to initialise it, and a
# test that uses the reporters without ever driving fetch() still needs it.

# _load_fetch ROOT DISTDIR
# Source the unit under test and export the recipe state it expects. Sourcing
# from inside a function is what the callers did at top level: POSIX sh has no
# function scope, so the definitions and variables land in the caller's shell
# either way.
_load_fetch() {
  SCRIPT_DIR="$1"
  # shellcheck source=lib/utils.sh
  . "$1/lib/utils.sh"
  # shellcheck source=lib/download.sh
  . "$1/lib/download.sh"

  DISTDIR="$2"
  PKG_URL=''
  PKG_FILENAME=''
  PKG_DIRNAME=''
  export DISTDIR PKG_URL PKG_FILENAME PKG_DIRNAME
}
