#!/bin/sh
# Lints every shell file under the repo with `sh -n` and (when available) `shellcheck -s sh`.
# Exit non-zero on first failure unless KEEP_GOING=1.
#
# REQUIRE_SHELLCHECK=1 refuses to report a pass when shellcheck is absent. An
# ad-hoc run on a machine without it still wants the syntax half; a gate that
# BLOCKS a push does not, because "syntax is fine" reported as a clean gate is
# the wrong answer to "is this tree lintable". .githooks/pre-push sets it.
# SHELLCHECK names the binary, so the absent-linter path is reachable in a test
# without dismantling PATH.

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

_fail=0
_files=$(find mediaforge.sh lib recipes tests -type f -name '*.sh')

# The hook that RUNS this gate is a shell file too, and git requires hook names
# to be exact -- so .githooks/* carry no extension and the -name '*.sh' filter
# above cannot see them. A syntax error there would block every push with a
# failure nothing in the tree lints.
#
# Executable files only: git runs a hook only if it is executable, so that bit
# is what separates a hook from a README or a .sample sitting beside it. Linting
# those as shell would fail the gate for a reason nobody could connect to their
# edit.
if [ -d .githooks ]; then
  _files="$_files
$(find .githooks -type f -perm -u+x)"
fi

# The entry points the docs tell people to run as ./path. Nothing else depends
# on their mode -- every internal caller uses `sh <file>` -- so the bit can drop
# with no test noticing, and the failure surfaces as a permission error in a
# contributor's very first command. That is not hypothetical: an awk rewrite of
# this file dropped this file's own bit, and the whole suite stayed green.
for f in mediaforge.sh tests/shellcheck.sh; do
  if [ ! -x "$f" ]; then
    printf 'not executable, but documented as ./%s\n' "$f" >&2
    _fail=1
    [ "${KEEP_GOING:-0}" = "1" ] || exit 1
  fi
done

for f in $_files; do
  if ! sh -n "$f"; then
    printf 'sh -n FAILED: %s\n' "$f" >&2
    _fail=1
    [ "${KEEP_GOING:-0}" = "1" ] || exit 1
  fi
done

_shellcheck=${SHELLCHECK:-shellcheck}
if command -v "$_shellcheck" >/dev/null 2>&1; then
  for f in $_files; do
    # `shell=sh` is set in .shellcheckrc so -s sh is implicit.
    # SC1090/SC1091 are info-level findings about non-constant / not-followed
    # `.` sources — unavoidable in mediaforge's dynamic recipe-sourcing model.
    # SC2034 is suppressed per-file in each recipe (PKG_* vars consumed by
    # lib/framework.sh after sourcing) so we do NOT exclude it globally here.
    # Severity -S info enforces every category project-wide.
    if ! "$_shellcheck" -S info -e SC1090,SC1091 "$f"; then
      printf 'shellcheck FAILED: %s\n' "$f" >&2
      _fail=1
      [ "${KEEP_GOING:-0}" = "1" ] || exit 1
    fi
  done
else
  printf 'shellcheck not installed — skipping\n' >&2
  if [ "${REQUIRE_SHELLCHECK:-0}" = "1" ]; then
    printf 'REQUIRE_SHELLCHECK=1: refusing to report a pass on syntax checks alone\n' >&2
    exit 1
  fi
fi

exit "$_fail"
