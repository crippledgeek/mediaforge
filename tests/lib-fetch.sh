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
# Which of those three actually bites is worth knowing, because the answer is
# not "all of them" and this comment said so before it was measured:
#
#     _url="${1:-$PKG_URL}"                    bare  -- unset aborts, but only
#                                                       when no URL is passed
#     _file="${2:-${PKG_FILENAME:-...}}"       NESTED `:-` -- unset is always
#                                                       safe, `set -u` or not
#     _dir="${3:-$PKG_DIRNAME}"                bare  -- unset aborts whenever
#                                                       the caller omits $3
#
# So PKG_DIRNAME is the load-bearing one for a caller that passes fewer than
# three arguments. All three are set here anyway: which expansion is bare is a
# property of fetch()'s defaults, not of this helper, and a test should not go
# red the day one of them changes shape.
#
# The failure it prevents is worth naming exactly, because it is silent in one
# direction. A test asserting that fetch FAILS -- tests/fetch-fail-no-cache.sh
# runs `( fetch ... )` and checks for a non-zero status -- cannot tell an abort
# on an unbound variable from the die() it is asserting: the status is non-zero
# either way, so the test goes green having never reached a download. Measured,
# by deleting each assignment in turn: dropping PKG_DIRNAME leaves that test
# PASSING and makes tests/download-retry-verify.sh (which passes all three
# arguments, and asserts a SUCCESS) fail loudly. The quiet direction is the one
# this helper exists for.
#
# Written out in both callers before this existed, and the comment explaining
# it had already drifted into two spellings -- neither of which was accurate
# about which variable mattered. The prose is the part that drifts first, and
# it is the part a reader relies on.
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
