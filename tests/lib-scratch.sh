# shellcheck shell=sh
# Run mediaforge from a TOPDIR the test owns, so a dry run cannot read — or
# write — the developer's own build tree.
#
# mediaforge derives both working directories from the INVOCATION directory:
#
#     TOPDIR=$(pwd); DISTDIR="$TOPDIR/packages"; PREFIX="$TOPDIR/workspace"
#
# so a test that `cd`s to the repo root and calls ./mediaforge.sh gets the
# repo's own workspace/ as $PREFIX, whatever state that happens to be in. Eight
# test files did exactly that (#55). The coupling was latent for as long as the
# only thing $PREFIX contributed to a dry run was a stamp list, and the
# mixed-debug-level guard (#53) turned it into a hard failure: on a machine
# carrying a --debug=full workspace, a dry run of a NON-debug build is refused
# before it reaches the assertion under test, and the suite fails for a reason
# that has nothing to do with the tree being tested.
#
# The guard is right. Depending on a build tree the tests do not own is the
# defect, and the fix is a prefix of their own — which needs no production code
# change, only a different cwd and an absolute path to the script.
#
# Usage:
#
#     . "$ROOT/tests/lib-scratch.sh"
#     _scratch_init "$ROOT"
#     _out=$(_mf build --dry-run --yes 2>&1)
#     ...
#     _scratch_cleanup
#
# NO EXIT TRAP IS REGISTERED HERE, deliberately. `trap ... EXIT` has no append
# form in POSIX sh, so a second registration silently replaces the first, and
# three of the callers already own one. Each caller therefore calls
# _scratch_cleanup from its own handler (or registers one when it has none),
# which keeps every file's cleanup visible in that file.
#
# The scratch dir is a plain temporary directory, not a copy of anything: a dry
# run reads no source and downloads nothing, so an empty TOPDIR is all it needs.
# mediaforge creates packages/ and workspace/ inside it on the way past.

# _scratch_init <repo-root>: create the scratch TOPDIR and remember the root
# whose mediaforge.sh will be run from it.
_scratch_init() {
  _MF_ROOT=$1
  _MF_SCRATCH=$(mktemp -d) || exit 1
}

# Idempotent, and it never ends on a false test: it is called from EXIT
# handlers in files running under `set -e`, where a trailing `[ -n "$x" ] &&`
# that finds nothing makes the handler — and so the script — exit non-zero.
_scratch_cleanup() {
  if [ -n "${_MF_SCRATCH:-}" ]; then
    rm -rf "$_MF_SCRATCH"
    _MF_SCRATCH=""
  fi
}

# _mf <args...>: mediaforge, run from the scratch TOPDIR.
#
# The subshell is what keeps the caller's cwd — every one of these tests reads
# recipes and lib sources by repo-relative path — while the command itself sees
# the scratch dir as $(pwd). Called by absolute path for the same reason:
# ./mediaforge.sh would not resolve from there, and $SCRIPT_DIR is derived from
# $0 rather than from the cwd, so the framework still loads from the repo.
#
# The missing-directory case is reported rather than left to `cd` — an early
# _scratch_cleanup, or a /tmp reaper on a long run, and `cd` fails, mediaforge
# never runs, and this returns EMPTY OUTPUT with a non-zero status that every
# caller here discards with `|| true`. Empty output satisfies every `_run_no` in
# tests/dry-run-matrix.sh and each of the stamp-leak checks in tests/negative.sh,
# so the failure mode is a green suite that ran nothing.
# 127 rather than 1 so a caller that does look at the status sees "could not
# execute" rather than "mediaforge said no".
_mf() {
  if [ ! -d "${_MF_SCRATCH:-}" ]; then
    printf 'lib-scratch: the scratch TOPDIR is gone (_scratch_init not run, or removed early)\n' >&2
    return 127
  fi
  ( cd "$_MF_SCRATCH" && "$_MF_ROOT/mediaforge.sh" "$@" )
}
