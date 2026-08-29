#!/bin/sh
# Pins --ccache: the flag, its default, and the masquerade directory it builds.
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
_wired setup-called    mediaforge.sh 'mf_ccache_setup'
# Default off. Asserted against the assignment: a default that flips is a build
# that silently changes its toolchain.
if grep -qE '^MF_CCACHE=false' mediaforge.sh; then
  _pass default-is-off
else
  _bad default-is-off "MF_CCACHE does not default to false"
fi

# --- the mechanism ----------------------------------------------------------
if [ ! -f lib/ccache.sh ]; then
  for _a in masquerade-dir-built only-existing-compilers path-is-prepended dies-without-ccache; do
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

(
  PATH="$_tmp/bin"; export PATH
  PREFIX="$_tmp/prefix"; export PREFIX
  # shellcheck source=lib/utils.sh
  . "$ROOT/lib/utils.sh"
  # shellcheck source=lib/ccache.sh
  . "$ROOT/lib/ccache.sh"
  mf_ccache_setup > "$_tmp/log" 2>&1
  printf '%s\n' "$PATH" > "$_tmp/path"
) || { printf 'FAIL [setup-ran] exited non-zero: %s\n' "$(tr '\n' ' ' < "$_tmp/log")" >&2; _fail=1; }

_dir="$_tmp/prefix/.ccache-bin"
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
if [ -z "$_linked" ]; then
  _pass only-existing-compilers
else
  _bad only-existing-compilers "linked names that do not resolve:$_linked"
fi

# Prepended, not appended: an appended entry is shadowed by the real compiler
# and caches nothing, which looks identical to working.
_first=$(cut -d: -f1 < "$_tmp/path")
if [ "$_first" = "$_dir" ]; then
  _pass path-is-prepended
else
  _bad path-is-prepended "PATH starts with [$_first]"
fi

# Asking for a cache that is not installed is an error, not a silent no-op: the
# operator asked for a faster build and would otherwise get a slower one with no
# explanation. Run with the tools present but no ccache.
# `sh` is in this list because env resolves the interpreter through PATH too:
# without it the probe dies with "env: 'sh': No such file or directory", which
# is a death for the wrong reason -- caught by the else-branch below, which
# refuses to accept any failure that does not name the missing cache.
mkdir -p "$_tmp/nocache"
_link_tools "$_tmp/nocache" mkdir rm ln sh
# Written to a file rather than passed to `sh -c`: an inline script would carry
# a positional parameter inside single quotes, which the linter reads as a
# failed expansion (SC2016) and which a reader has to decode.
cat > "$_tmp/probe.sh" <<'PROBE'
. "$1/lib/utils.sh"
. "$1/lib/ccache.sh"
mf_ccache_setup
PROBE
set +e
_out=$(env "PATH=$_tmp/nocache" "PREFIX=$_tmp/prefix2" sh "$_tmp/probe.sh" "$ROOT" 2>&1)
_rc=$?
set -e
if [ "$_rc" -eq 0 ]; then
  _bad dies-without-ccache "exited 0 with no ccache on PATH"
else
  case "$_out" in
    *"not installed"*) _pass dies-without-ccache ;;
    *) _bad dies-without-ccache "died without naming the cause: $(printf '%s' "$_out" | tr '\n' ' ')" ;;
  esac
fi

printf 'DONE: ccache\n'
exit "$_fail"
