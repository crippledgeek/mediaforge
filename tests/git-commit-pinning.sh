#!/bin/sh
# Commit-pinning regression tests for the two git-sourced recipes
# (recipes/other/librtmp.sh, recipes/hwaccel/libplacebo.sh).
#
# THE BUG THIS PINS. librtmp cloned with `--branch "v${PKG_VERSION}"`, which
# accepts only branches and tags. Every profile sets PKG_VERSION_LIBRTMP to a
# 40-hex commit SHA, so the interpolated ref was `v<sha>` -- a ref that cannot
# exist. `git clone` exits non-zero, `run` (lib/utils.sh:21-28) dies, and every
# `--profile=` build failed at recipes/_order.conf:99. Without a profile it
# worked only because the recipe default `2.6` happens to be a real tag.
#
# THE INTEGRITY HALF. A git tag is a mutable server-side pointer, so pinning
# `v${PKG_VERSION}` authenticated nothing even when it resolved: whoever
# controls the remote can retarget the tag and every later build silently gets
# different source. Pinning a commit SHA is self-verifying, because a git object
# name IS the hash of its content.
#
# Hermetic: every assertion runs against a local fixture repo built here. No
# network, so these run in tests/run.sh with the rest of the suite.
#
# Usage: tests/git-commit-pinning.sh
# Exit 0 = pass, 1 = regression.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT" || exit 1
_fail=0

_pass() { printf 'PASS [%s]\n' "$1"; }
_bad()  { printf 'FAIL [%s] %s\n' "$1" "${2-}" >&2; _fail=1; }

# -- Fixture: a repo with an OLD commit, then a NEWER one carrying a tag. -----
# Mirrors the real shape: rtmpdump's `v2.6` tag resolves to a commit ten ahead
# of the SHA the profiles pinned.
_fx=$(mktemp -d); trap 'rm -rf "$_fx"' EXIT INT TERM
_repo="$_fx/remote"
mkdir -p "$_repo"
(
  cd "$_repo" || exit 1
  git init -q .
  git config user.email t@t; git config user.name t; git config commit.gpgsign false
  printf 'old\n' > f.txt && git add f.txt && git commit -qm old
  printf 'new\n' > f.txt && git add f.txt && git commit -qm new
  git tag -a v9.9.9 -m tag
  # Serve arbitrary SHAs over file:// the way a real forge does.
  git config uploadpack.allowAnySHA1InWant true
  git config uploadpack.allowReachableSHA1InWant true
) || { printf 'FAIL [fixture] could not build fixture repo\n' >&2; exit 1; }
_OLD=$(git -C "$_repo" rev-parse HEAD~1)
_NEW=$(git -C "$_repo" rev-parse HEAD)

# shellcheck disable=SC1091
. lib/utils.sh
# shellcheck disable=SC1091
. lib/framework.sh
# shellcheck disable=SC1091
. lib/download.sh

# -- 1. Characterise the bug: the OLD shape cannot clone a SHA. --------------
# This is what every profile build did, and it is asserted against real git so
# the description above is checked rather than merely believed.
#
# Deliberately NOT a PASS/FAIL assertion. These two describe GIT's behaviour,
# which is identical on this branch and on the merge base -- so counting them as
# assertions would put two always-passing lines in front of
# tests/oracle-baseline.sh, which correctly rejects any assertion that passes on
# the base as one that cannot be guarding the change. They print as INFO, and
# only speak up as FAIL when the fixture itself is broken.
if git clone -q --depth 1 --branch "v$_OLD" "$_repo" "$_fx/oldshape" 2>/dev/null; then
  _bad "fixture: --branch v<sha> must fail" "clone unexpectedly succeeded"
else
  printf 'INFO: --branch v<sha> is rejected by git (the #28 failure mode)\n'
fi
# ...while the same shape over a real TAG succeeds -- proving the failure above
# is the SHA, not a broken fixture.
if git clone -q --depth 1 --branch "v9.9.9" "$_repo" "$_fx/tagshape" 2>/dev/null; then
  printf 'INFO: --branch <real tag> succeeds, so the fixture is sound\n'
else
  _bad "fixture: --branch <real tag> should succeed" "fixture repo is broken"
fi

# -- 2. fetch_git checks out exactly the requested commit. -------------------
PREFIX="$_fx/prefix"; mkdir -p "$PREFIX"   # run() writes logs under $PREFIX
if command -v fetch_git > /dev/null 2>&1; then
  _d="$_fx/c1"
  if ( fetch_git "$_repo" "$_d" "$_OLD" ) > /dev/null 2>&1; then
    _got=$(git -C "$_d" rev-parse HEAD 2>/dev/null)
    if [ "$_got" = "$_OLD" ]; then
      _pass "fetch_git checks out the requested commit"
    else
      _bad "fetch_git checks out the requested commit" "want=$_OLD got=$_got"
    fi
    # Content, not just the ref: the OLD commit's file must be there.
    if [ "$(cat "$_d/f.txt" 2>/dev/null)" = old ]; then
      _pass "fetch_git delivers that commit's content"
    else
      _bad "fetch_git delivers that commit's content" "f.txt != 'old'"
    fi
  else
    _bad "fetch_git checks out the requested commit" "fetch_git returned non-zero"
  fi

  # -- 3. A stale clone at the WRONG commit is re-fetched, not reused. -------
  # Same unconditionally-trusted-cache weakness #19 identifies for tarballs:
  # the old recipes reused $DISTDIR/<pkg> whenever the directory merely existed.
  _d2="$_fx/c2"
  ( fetch_git "$_repo" "$_d2" "$_NEW" ) > /dev/null 2>&1
  if ( fetch_git "$_repo" "$_d2" "$_OLD" ) > /dev/null 2>&1; then
    _got=$(git -C "$_d2" rev-parse HEAD 2>/dev/null)
    if [ "$_got" = "$_OLD" ]; then
      _pass "stale clone at wrong commit is re-fetched"
    else
      _bad "stale clone at wrong commit is re-fetched" "want=$_OLD got=$_got (reused)"
    fi
  else
    _bad "stale clone at wrong commit is re-fetched" "fetch_git returned non-zero"
  fi

  # -- 4. A clone already AT the commit is reused (no needless refetch). -----
  _d3="$_fx/c3"
  ( fetch_git "$_repo" "$_d3" "$_OLD" ) > /dev/null 2>&1
  : > "$_d3/.reuse-marker"
  ( fetch_git "$_repo" "$_d3" "$_OLD" ) > /dev/null 2>&1
  if [ -f "$_d3/.reuse-marker" ]; then
    _pass "clone already at the commit is reused"
  else
    _bad "clone already at the commit is reused" "directory was rebuilt"
  fi

  # -- 5. An unreachable commit fails loudly. -------------------------------
  # 40 hex digits, valid shape, no such object -- so this exercises the fetch
  # failure path rather than an argument-validation path.
  _ghost=0123456789abcdef0123456789abcdef01234567
  if ( fetch_git "$_repo" "$_fx/c4" "$_ghost" ) > /dev/null 2>&1; then
    _bad "unreachable commit must fail" "fetch_git returned success"
  else
    _pass "unreachable commit fails loudly"
  fi
else
  _bad "fetch_git exists" "no fetch_git helper in lib/download.sh"
fi

# -- 6. Neither recipe interpolates a version into a --branch ref any more. --
# Comment lines are stripped first: both recipes now DESCRIBE the removed
# `--branch "v${PKG_VERSION}"` shape in a comment explaining the pin, and an
# oracle that matched prose would fail on the fixed tree for the wrong reason.
for _r in recipes/other/librtmp.sh recipes/hwaccel/libplacebo.sh; do
  if sed 's/[[:space:]]*#.*$//' "$_r" | grep -qE 'branch[^|]*\$\{?PKG_VERSION'; then
    _bad "$_r does not clone by --branch \$PKG_VERSION" "still builds a ref from PKG_VERSION"
  else
    _pass "$_r does not clone by --branch \$PKG_VERSION"
  fi
done

# -- 7. Every profile supplies a 40-hex commit for both recipes. -------------
# The regression test for the reported failure: a profile value that is not a
# commit is what produced `v<sha>`, and a MISSING one silently reintroduces the
# tag-pinning the rest of this file removes.
for _p in profiles/ffmpeg-*.conf; do
  for _v in PKG_COMMIT_LIBRTMP PKG_COMMIT_LIBPLACEBO; do
    _val=$(awk -F'"' -v k="^$_v=" '$0 ~ k { print $2; exit }' "$_p")
    _hex=$(printf '%s' "$_val" | tr -d '0-9a-f')
    _len=${#_val}
    if [ -z "$_val" ]; then
      _bad "$(basename "$_p") $_v is a 40-hex commit" "unset"
    elif [ "$_len" -eq 40 ] && [ -z "$_hex" ]; then
      _pass "$(basename "$_p") $_v is a 40-hex commit"
    else
      _bad "$(basename "$_p") $_v is a 40-hex commit" "not a commit: $_val"
    fi
  done
done

# -- 8. librtmp declares the git it shells out to. --------------------------
if grep -qE '^PKG_REQUIRES_CMD=.*git' recipes/other/librtmp.sh; then
  _pass "librtmp declares its git dependency"
else
  _bad "librtmp declares its git dependency" "PKG_REQUIRES_CMD does not name git"
fi

[ "$_fail" -eq 0 ] && printf 'git-commit-pinning: all assertions passed.\n'
# Completion sentinel for tests/oracle-baseline.sh: proves the file ran to the
# end on the baseline tree rather than aborting early and scoring a free pass.
printf 'DONE: git-commit-pinning\n'
exit "$_fail"
