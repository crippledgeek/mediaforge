#!/bin/sh
# Pins the compiler cache: the tri-state flag, its default, and the ONE mechanism
# that answers for all five build systems.
#
# The MECHANISM is the part worth pinning. ccache can be wired either by
# prefixing CC/CXX or by putting a directory of compiler-named symlinks ahead of
# PATH, and the two are not interchangeable here:
#
#   - recipes/audio/gsm.sh passes CC="gcc" on its make line, which beats any
#     exported CC. A PATH entry it resolves that name through does not, so the
#     prefix form would silently skip that recipe.
#   - cmake 4.3.2 given CC="ccache gcc" records CMAKE_C_COMPILER=/usr/bin/ccache
#     and moves gcc into ARG1 (measured), so its cache file stops naming a
#     compiler.
#
# A future change from the directory to the prefix form is therefore a
# regression, and these assertions are what says so.
#
# The SECOND half is the one GH-61 was filed about. meson finds ccache by itself
# and compiles through it whether or not mediaforge asked for a cache, so a tree
# whose flag is merely absent is cached for meson recipes and uncached for the
# other four. Both directions of the flag are therefore asserted here: "on"
# builds the masquerade directory, and "off" exports CCACHE_DISABLE, which is
# what reaches the ccache that meson invokes without our help.
#
# lib/ccache.sh is sourced conditionally for the same reason tests/debug-levels.sh
# guards lib/flags.sh: on the merge base the file does not exist, and an
# unguarded source under `set -e` aborts before the DONE sentinel, which
# tests/oracle-baseline.sh reports as an abort rather than as the absent feature.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

# --- the CLI surface --------------------------------------------------------
_wired flag-parsed     mediaforge.sh '--ccache)'
_wired flag-off-parsed mediaforge.sh '--no-ccache)'
_wired flag-documented mediaforge.sh '--ccache              Compile through ccache'
_wired apply-called    mediaforge.sh 'mf_ccache_apply'
# The default is the part a reader has to be TOLD. tests/debug-levels.sh already
# checks that every flag appears in some document; which way an unpassed flag
# resolves appears in none of them unless it is written down, and this change
# moved it.
_wired default-documented Documentation/usage.md 'default is to use ccache when it is installed'
# The default is the third state, not either flag: `auto` uses the cache when one
# is installed and disables it when none is. Asserted against the assignment,
# because a default that flips is a build that silently changes its toolchain.
if grep -qE '^MF_CCACHE=auto' mediaforge.sh; then
  _pass default-is-auto
else
  _bad default-is-auto "MF_CCACHE does not default to auto"
fi

# One mechanism, not one per build system. The masquerade directory and
# CCACHE_DISABLE are both process-wide, so a per-build-system launcher option
# added later would be a second answer that agrees with the first only by
# inspection -- the split GH-61 was filed about, reintroduced from the other
# side. Same shape as tests/meson-single-entry.sh: a grep for the wiring that
# must not appear.
# Comment lines are dropped first: lib/ccache.sh's header explains why it does
# NOT use the prefix form, quoting `CC="ccache gcc"` verbatim, and a grep that
# cannot tell prose from wiring would report that explanation as the defect.
# The quote form is not fixed either -- CC='ccache gcc' and a bare CC=ccache are
# the same wiring -- so the pattern allows one optional quote character.
_launchers=$(grep -rnE 'C(XX)?_COMPILER_LAUNCHER|-Dccache|C(XX)?=.?ccache' \
               lib/ recipes/ mediaforge.sh 2>/dev/null |
             grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
if ! grep -q '^mf_ccache_setup()' lib/ccache.sh 2>/dev/null; then
  # The floor tests/meson-single-entry.sh carries for the same shape of claim:
  # every clause above is "grep found nothing", which an empty lib/ satisfies
  # having checked nothing. Note the `! -f lib/ccache.sh` guard further down
  # does not cover this -- it runs after.
  _bad one-mechanism "no mf_ccache_setup to be the one mechanism"
elif [ -z "$_launchers" ]; then
  _pass one-mechanism
else
  _bad one-mechanism "per-build-system cache wiring in: $(printf '%s' "$_launchers" | tr '\n' ' ')"
fi

# --- the mechanism ----------------------------------------------------------
if [ ! -f lib/ccache.sh ]; then
  for _a in masquerade-dir-built only-existing-compilers path-is-prepended \
            auto-uses-cache auto-degrades-without-ccache off-disables-everywhere \
            off-builds-no-masquerade explicit-clears-inherited-disable \
            auto-respects-inherited-disable auto-defers-on-empty-disable \
            unknown-state-dies \
            dies-without-ccache; do
    _bad "$_a" "lib/ccache.sh absent — claim would be vacuous"
  done
  printf 'DONE: ccache\n'
  exit "$_fail"
fi

# Both sandboxes below need real tools reachable through their restricted PATH,
# and the two loops that built them differed only in whether a missing tool was
# reported -- so the one that skipped the check would have produced a dangling
# symlink and a confusing failure three assertions later.
_link_tools() { # dir  tool...
  _lt_dir="$1"; shift
  for _lt in "$@"; do
    _lt_real=$(command -v "$_lt") || { printf 'FAIL [sandbox] no %s\n' "$_lt" >&2; exit 1; }
    ln -sf "$_lt_real" "$_lt_dir/$_lt"
  done
}

_tmp=$(mktemp -d) || { printf 'FAIL [tmpdir]\n' >&2; exit 1; }
trap 'rm -rf "$_tmp"' EXIT INT TERM

# A SANDBOX PATH holding exactly one compiler name (cc), a stub ccache, and the
# three tools the function shells out to. Restricting PATH is what makes the
# "only link what resolves" rule testable at all: on a host that has gcc, clang
# and the rest, a full PATH links all six and the rule can only be asserted
# vacuously. A stub ccache rather than the host's, so this file runs on a
# machine that has none.
mkdir -p "$_tmp/bin"
printf '#!/bin/sh\nexit 0\n' > "$_tmp/bin/ccache"; chmod +x "$_tmp/bin/ccache"
printf '#!/bin/sh\nexit 0\n' > "$_tmp/bin/cc";     chmod +x "$_tmp/bin/cc"
_link_tools "$_tmp/bin" mkdir rm ln
# The same sandbox WITHOUT a ccache, for the two states whose whole subject is a
# host that has none.
mkdir -p "$_tmp/nocache"
printf '#!/bin/sh\nexit 0\n' > "$_tmp/nocache/cc"; chmod +x "$_tmp/nocache/cc"
_link_tools "$_tmp/nocache" mkdir rm ln

# One state, one sandbox, one recording. Written as a helper because the
# assertions below differ only in the state they pass and the bin directory they
# pass it under -- and because what has to be read back is not a return value
# but what the process LEAVES: its PATH, its CCACHE_DISABLE, and how it exited.
# Each tag gets its own PREFIX so a masquerade directory built by one state can
# never be mistaken for one built by another.
_apply() { # tag  bindir  state
  _ap_tag="$1"
  rm -f "$_tmp/path-$_ap_tag" "$_tmp/disable-$_ap_tag"
  set +e
  (
    PATH="$2"; export PATH
    PREFIX="$_tmp/prefix-$_ap_tag"; export PREFIX
    # shellcheck source=lib/utils.sh
    . "$ROOT/lib/utils.sh"
    # shellcheck source=lib/ccache.sh
    . "$ROOT/lib/ccache.sh"
    # Exit rather than run on: without this, a tree where mf_ccache_apply does
    # not exist prints "command not found", carries on to the recordings, and
    # leaves the subshell at 0 -- so every assertion phrased as "nothing
    # happened" passes on precisely the tree that has none of this.
    command -v mf_ccache_apply >/dev/null 2>&1 || { echo "no mf_ccache_apply"; exit 127; }
    mf_ccache_apply "$3"
    printf '%s\n' "$PATH" > "$_tmp/path-$_ap_tag"
    # `-` not `:-`: an exported empty CCACHE_DISABLE is a different fact from an
    # unset one, and collapsing them would let "exported as empty" pass a check
    # for "not exported".
    printf '%s\n' "${CCACHE_DISABLE-UNSET}" > "$_tmp/disable-$_ap_tag"
  ) > "$_tmp/log-$_ap_tag" 2>&1
  _ap_rc=$?
  set -e
}

# Reading one recording back, with the "the subshell died before writing it"
# case reported as the failure it is rather than as an abort: this file runs
# under `set -e`, and a bare read of a missing file would exit before the DONE
# sentinel that tests/oracle-baseline.sh requires.
_recorded() { # tag  what(path|disable)
  if [ -f "$_tmp/$2-$1" ]; then cat "$_tmp/$2-$1"; else printf 'NOTHING-RECORDED\n'; fi
}

# The failure detail for one run, bounded. _bad flattens newlines, so an
# unbounded log becomes a single multi-kilobyte line -- the exact failure
# tests/lib-assert.sh says _evidence exists to prevent. The pattern names the
# words these logs fail with; _evidence falls back to the last lines when none
# of them appears.
_why() { # tag
  _evidence 3 'ccache|not installed|no mf_ccache_apply|unknown ccache state' < "$_tmp/log-$1"
}

# --- state: explicit --ccache -----------------------------------------------
_apply on "$_tmp/bin" true
if [ "$_ap_rc" -eq 0 ]; then
  _pass setup-ran
else
  _bad setup-ran "exited $_ap_rc: $(_why on)"
fi

_dir="$_tmp/prefix-on/.ccache-bin"
if [ -L "$_dir/cc" ] && [ "$(readlink "$_dir/cc")" = "$_tmp/bin/ccache" ]; then
  _pass masquerade-dir-built
else
  _bad masquerade-dir-built "no cc symlink to the ccache found on PATH in $_dir"
fi

# The other five names do not resolve in the sandbox, so none may be linked.
# Linking one would make `command -v gcc` succeed and hand a build system a
# compiler that cannot run -- the opposite of a cache's job, which is to change
# nothing but how long the build takes.
_linked=""
for _n in gcc c++ g++ clang clang++; do
  if [ -e "$_dir/$_n" ]; then _linked="$_linked $_n"; fi
done
if [ ! -d "$_dir" ]; then
  # "none of the five were linked" is true of a directory that does not exist,
  # so on a tree that builds no masquerade at all this claim would pass having
  # checked nothing.
  _bad only-existing-compilers "no masquerade directory to inspect"
elif [ -z "$_linked" ]; then
  _pass only-existing-compilers
else
  _bad only-existing-compilers "linked names that do not resolve:$_linked"
fi

# Prepended, not appended: an appended entry is shadowed by the real compiler
# and caches nothing, which looks identical to working.
_first=$(_recorded on path | cut -d: -f1)
if [ "$_first" = "$_dir" ]; then
  _pass path-is-prepended
else
  _bad path-is-prepended "PATH starts with [$_first]"
fi

# --- state: auto (the default) ----------------------------------------------
# With a cache installed, `auto` is `true`. Asserted on the masquerade directory
# rather than on a log line, because the directory is what the build resolves
# its compiler names through.
_apply auto-yes "$_tmp/bin" auto
if [ "$_ap_rc" -eq 0 ] && [ -L "$_tmp/prefix-auto-yes/.ccache-bin/cc" ]; then
  _pass auto-uses-cache
else
  _bad auto-uses-cache "rc=$_ap_rc, no masquerade dir: $(_why auto-yes)"
fi

# With no cache installed, `auto` is not an error. A host without ccache is the
# ordinary case, and the default state may not refuse to build on one -- which is
# the one thing separating `auto` from simply defaulting the flag to on.
_apply auto-no "$_tmp/nocache" auto
_degraded=$(_recorded auto-no disable)
if [ "$_ap_rc" -eq 0 ] && [ "$_degraded" = "1" ]; then
  _pass auto-degrades-without-ccache
else
  _bad auto-degrades-without-ccache "rc=$_ap_rc, CCACHE_DISABLE=[$_degraded]: $(_why auto-no)"
fi

# --- state: --no-ccache -----------------------------------------------------
# The assertion GH-61 exists for. Our masquerade directory is not what meson
# uses -- meson finds ccache itself -- so "off" can only be made true for meson
# by an environment variable the ccache it invokes reads. Anything weaker leaves
# the default tree cached for meson recipes and uncached for the other four.
_apply off "$_tmp/bin" false
_disable=$(_recorded off disable)
if [ "$_disable" = "1" ]; then
  _pass off-disables-everywhere
else
  _bad off-disables-everywhere "CCACHE_DISABLE=[$_disable], not 1"
fi

# And it must not ALSO build the masquerade directory: a state that wires the
# cache in and disables it again is two mechanisms disagreeing, which is the
# defect this file's header describes.
if [ "$_ap_rc" -ne 0 ]; then
  _bad off-builds-no-masquerade "the off state exited $_ap_rc: $(_why off)"
elif [ -e "$_tmp/prefix-off/.ccache-bin" ]; then
  _bad off-builds-no-masquerade "built a masquerade directory while the cache is off"
else
  _pass off-builds-no-masquerade
fi

# --- inherited environment --------------------------------------------------
# An operator whose shell already exports CCACHE_DISABLE=1 and who then asks for
# --ccache must get a cache. Without this the flag builds the masquerade
# directory, every compile runs through ccache, and none of them caches -- the
# silent no-op that dies-without-ccache below refuses to allow from the other
# direction.
#
# Exported around the call rather than given its own sandbox: the difference
# from every other state here is exactly one inherited variable, and _apply's
# subshell inherits it.
CCACHE_DISABLE=1; export CCACHE_DISABLE
_apply inherit "$_tmp/bin" true
unset CCACHE_DISABLE
_inherited=$(_recorded inherit disable)
if [ "$_ap_rc" -eq 0 ] && [ "$_inherited" = "UNSET" ]; then
  _pass explicit-clears-inherited-disable
else
  _bad explicit-clears-inherited-disable "rc=$_ap_rc, CCACHE_DISABLE=[$_inherited]"
fi

# The same variable, the same host, the other state -- and the opposite answer.
# An operator who exported CCACHE_DISABLE has configured ccache the way ccache
# documents; the default state did not ask for a cache and may not overrule
# that. Before this pair existed the `unset` lived in mf_ccache_setup, which
# BOTH states reach, so the default silently re-enabled a cache the operator had
# turned off host-wide.
CCACHE_DISABLE=1; export CCACHE_DISABLE
_apply defer "$_tmp/bin" auto
unset CCACHE_DISABLE
_deferred=$(_recorded defer disable)
if [ "$_ap_rc" -ne 0 ]; then
  _bad auto-respects-inherited-disable "exited $_ap_rc: $(_why defer)"
elif [ "$_deferred" != "1" ]; then
  _bad auto-respects-inherited-disable "CCACHE_DISABLE=[$_deferred], not the inherited 1"
elif [ -e "$_tmp/prefix-defer/.ccache-bin" ]; then
  # Left alone means left alone: wiring the masquerade directory in anyway would
  # route every compile through a ccache the environment has disabled, which is
  # the silent no-op in its third disguise.
  _bad auto-respects-inherited-disable "built a masquerade directory over an inherited CCACHE_DISABLE"
else
  _pass auto-respects-inherited-disable
fi

# The same claim one state over, and the reason the presence test is spelled
# `+` rather than `:-`. ccache reads an exported-but-empty CCACHE_DISABLE as
# disabled just like `1` (measured, 4.13.6), so an implementation testing the
# VALUE would build the masquerade directory over an operator who had disabled
# the cache -- and every other assertion in this file would stay green, because
# each of them exports the value 1.
CCACHE_DISABLE=; export CCACHE_DISABLE
_apply defer-empty "$_tmp/bin" auto
unset CCACHE_DISABLE
_empty=$(_recorded defer-empty disable)
if [ "$_ap_rc" -ne 0 ]; then
  _bad auto-defers-on-empty-disable "exited $_ap_rc: $(_why defer-empty)"
elif [ "$_empty" != "" ]; then
  # _recorded prints UNSET for a variable that is not set, so exported-empty and
  # never-set are distinguishable here -- which is what makes the claim testable.
  _bad auto-defers-on-empty-disable "CCACHE_DISABLE=[$_empty], not the inherited empty value"
elif [ -e "$_tmp/prefix-defer-empty/.ccache-bin" ]; then
  _bad auto-defers-on-empty-disable "built a masquerade directory over an empty CCACHE_DISABLE"
else
  _pass auto-defers-on-empty-disable
fi

# --- refusals ---------------------------------------------------------------
# Asking for a cache that is not installed is an error, not a silent no-op: the
# operator asked for a faster build and would otherwise get a slower one with no
# explanation. This is the one thing `true` still does that `auto` does not.
_apply die "$_tmp/nocache" true
if [ "$_ap_rc" -eq 0 ]; then
  _bad dies-without-ccache "exited 0 with no ccache on PATH"
else
  case "$(cat "$_tmp/log-die")" in
    *"not installed"*) _pass dies-without-ccache ;;
    *) _bad dies-without-ccache "died without naming the cause: $(_why die)" ;;
  esac
fi

# A state that is none of the three is a caller bug -- a flag added without a
# case arm -- and must stop the build rather than pick a policy on its own.
_apply bogus "$_tmp/bin" maybe
if [ "$_ap_rc" -eq 0 ]; then
  _bad unknown-state-dies "accepted the state 'maybe'"
else
  # Named, not merely non-zero: the sandbox's own missing-function guard exits
  # non-zero too, so "it died" is satisfied by a tree that has no ccache support
  # at all.
  case "$(cat "$_tmp/log-bogus")" in
    *maybe*) _pass unknown-state-dies ;;
    *) _bad unknown-state-dies "died without naming the state: $(_why bogus)" ;;
  esac
fi

printf 'DONE: ccache\n'
exit "$_fail"
