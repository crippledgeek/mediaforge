#!/bin/sh
# Commit-pinning regression tests for the three git-sourced recipes
# (recipes/other/librtmp.sh, recipes/hwaccel/libplacebo.sh,
# recipes/video/av1.sh).
#
# THE BUG THIS PINS. librtmp cloned with `--branch "v${PKG_VERSION}"`, which
# accepts only branches and tags. Every profile sets PKG_VERSION_LIBRTMP to a
# 40-hex commit SHA, so the interpolated ref was `v<sha>` -- a ref that cannot
# exist. `git clone` exits non-zero, `run` (lib/utils.sh) dies, and every
# `--profile=` build failed at the librtmp line of recipes/_order.conf. Without a profile it
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
# ORACLE EVIDENCE, RECORDED BY HAND. tests/oracle-baseline.sh only gates test
# files a branch ADDED; this one is MODIFIED by the av1 work, so that gate SKIPs
# it (its own header documents the gap). Verified manually instead by exporting
# the merge base and running this file against it:
#   base a806750 -> 24 PASS, 13 FAIL, DONE printed.
# The 13 failures are this branch's real oracles: the non-clone-DEST and
# dangling-symlink cases, the two av1 fetch assertions, PKG_COMMIT_AV1 unset in
# all four profiles, and PKG_VERSION_AV1 holding a SHA in all four (the #28
# shape, on the base).
#
# Usage: tests/git-commit-pinning.sh
# Exit 0 = pass, 1 = regression.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT" || exit 1
_fail=0

# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

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
) || { printf 'ERROR: could not build the fixture repo\n' >&2; exit 1; }
_OLD=$(git -C "$_repo" rev-parse HEAD~1)
_NEW=$(git -C "$_repo" rev-parse HEAD)

# shellcheck source=lib/utils.sh
. lib/utils.sh
# shellcheck source=lib/framework.sh
. lib/framework.sh
# shellcheck source=lib/download.sh
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
  _bad fixture-branch-sha-must-fail "clone unexpectedly succeeded"
else
  printf 'INFO: --branch v<sha> is rejected by git (the #28 failure mode)\n'
fi
# ...while the same shape over a real TAG succeeds -- proving the failure above
# is the SHA, not a broken fixture.
if git clone -q --depth 1 --branch "v9.9.9" "$_repo" "$_fx/tagshape" 2>/dev/null; then
  printf 'INFO: --branch <real tag> succeeds, so the fixture is sound\n'
else
  _bad fixture-branch-tag-must-succeed "fixture repo is broken"
fi

# -- 2. fetch_git checks out exactly the requested commit. -------------------
PREFIX="$_fx/prefix"; mkdir -p "$PREFIX"   # run() writes logs under $PREFIX
if command -v fetch_git > /dev/null 2>&1; then
  _d="$_fx/c1"
  if ( fetch_git "$_repo" "$_d" "$_OLD" ) > /dev/null 2>&1; then
    _got=$(git -C "$_d" rev-parse HEAD 2>/dev/null)
    if [ "$_got" = "$_OLD" ]; then
      _pass fetch-git-checks-out-requested-commit
    else
      _bad fetch-git-checks-out-requested-commit "want=$_OLD got=$_got"
    fi
    # Content, not just the ref: the OLD commit's file must be there.
    if [ "$(cat "$_d/f.txt" 2>/dev/null)" = old ]; then
      _pass fetch-git-delivers-that-content
    else
      _bad fetch-git-delivers-that-content "f.txt != 'old'"
    fi
  else
    _bad fetch-git-checks-out-requested-commit "fetch_git returned non-zero"
  fi

  # -- 3. A stale clone at the WRONG commit is re-fetched, not reused. -------
  # Same unconditionally-trusted-cache weakness #19 identifies for tarballs:
  # the old recipes reused $DISTDIR/<pkg> whenever the directory merely existed.
  _d2="$_fx/c2"
  ( fetch_git "$_repo" "$_d2" "$_NEW" ) > /dev/null 2>&1
  if ( fetch_git "$_repo" "$_d2" "$_OLD" ) > /dev/null 2>&1; then
    _got=$(git -C "$_d2" rev-parse HEAD 2>/dev/null)
    if [ "$_got" = "$_OLD" ]; then
      _pass stale-clone-refetched
    else
      _bad stale-clone-refetched "want=$_OLD got=$_got (reused)"
    fi
  else
    _bad stale-clone-refetched "fetch_git returned non-zero"
  fi

  # -- 4. A clone already AT the commit is reused (no needless refetch). -----
  _d3="$_fx/c3"
  ( fetch_git "$_repo" "$_d3" "$_OLD" ) > /dev/null 2>&1
  : > "$_d3/.reuse-marker"
  ( fetch_git "$_repo" "$_d3" "$_OLD" ) > /dev/null 2>&1
  if [ -f "$_d3/.reuse-marker" ]; then
    _pass matching-clone-reused
  else
    _bad matching-clone-reused "directory was rebuilt"
  fi

  # -- 4b. A DEST that exists but is not a clone is replaced, not git-init'd.
  # The tarball->git conversion case: recipes/video/av1.sh previously extracted
  # a flat archive into $DISTDIR/av1, so every workspace that ever built it has
  # that directory with no .git. Without this, fetch_git git-inits over the
  # debris and `git checkout FETCH_HEAD` aborts with "untracked working tree
  # files would be overwritten" on any file the archive and the commit share --
  # README.md, CMakeLists.txt, and so on for libaom, i.e. certainly.
  _d5="$_fx/c5"
  mkdir -p "$_d5"
  printf 'stale tarball debris\n' > "$_d5/f.txt"
  if ( fetch_git "$_repo" "$_d5" "$_OLD" ) > /dev/null 2>&1; then
    _got=$(git -C "$_d5" rev-parse HEAD 2>/dev/null)
    if [ "$_got" = "$_OLD" ] && [ "$(cat "$_d5/f.txt" 2>/dev/null)" = old ]; then
      _pass non-clone-dest-replaced
    else
      _bad non-clone-dest-replaced "HEAD=$_got f.txt=$(cat "$_d5/f.txt" 2>/dev/null)"
    fi
  else
    _bad non-clone-dest-replaced "fetch_git failed on a non-clone DEST"
  fi

  # -- 4c. A dangling SYMLINK at DEST is replaced too. -----------------------
  # `[ -e ]` follows symlinks, so a broken one is -e-FALSE and slipped past the
  # non-clone branch into `mkdir -p`, which fails with "File exists" and dies
  # saying nothing useful. `[ -L ]` is what sees it.
  _d6="$_fx/c6"
  ln -s "$_fx/does-not-exist" "$_d6"
  if ( fetch_git "$_repo" "$_d6" "$_OLD" ) > /dev/null 2>&1; then
    _got=$(git -C "$_d6" rev-parse HEAD 2>/dev/null)
    if [ "$_got" = "$_OLD" ]; then
      _pass dangling-symlink-dest-replaced
    else
      _bad dangling-symlink-dest-replaced "HEAD=$_got"
    fi
  else
    _bad dangling-symlink-dest-replaced "fetch_git failed on a symlink DEST"
  fi

  # -- 5. An unreachable commit fails loudly. -------------------------------
  # 40 hex digits, valid shape, no such object -- so this exercises the fetch
  # failure path rather than an argument-validation path.
  _ghost=0123456789abcdef0123456789abcdef01234567
  if ( fetch_git "$_repo" "$_fx/c4" "$_ghost" ) > /dev/null 2>&1; then
    _bad unreachable-commit-fails-loudly "fetch_git returned success"
  else
    _pass unreachable-commit-fails-loudly
  fi
else
  _bad fetch-git-helper-exists "no fetch_git helper in lib/download.sh"
fi

# -- 6. Neither recipe interpolates a version into a --branch ref any more. --
# Comment lines are stripped first: both recipes now DESCRIBE the removed
# `--branch "v${PKG_VERSION}"` shape in a comment explaining the pin, and an
# oracle that matched prose would fail on the fixed tree for the wrong reason.
for _r in recipes/other/librtmp.sh recipes/hwaccel/libplacebo.sh; do
  if sed 's/[[:space:]]*#.*$//' "$_r" | grep -qE 'branch[^|]*\$\{?PKG_VERSION'; then
    _bad "no-branch-from-version-$_r" "still builds a ref from PKG_VERSION"
  else
    _pass "no-branch-from-version-$_r"
  fi
done

# -- 6b. av1 no longer fetches a gitiles archive. ---------------------------
# recipes/video/av1.sh pulled https://aomedia.googlesource.com/aom/+archive/
# <sha>.tar.gz. Gitiles builds that tarball per request and stamps the CURRENT
# time into the tar headers, so the same URL returns different bytes every time
# and no digest can pin it (google/gitiles#217, open; #84, its closed duplicate;
# and mediaforge #19, #27). Measured twice a second apart: two different
# sha256s. Naming a commit in the URL is a REQUEST parameter, not a verified
# property of the response; fetching the commit through git makes it
# self-verifying.
#
# Asserted as PRESENCE of the fetch_git call rather than mere absence of the
# string '+archive': absence alone stays green if PKG_URL is repointed at some
# other unpinned mirror, or if fetch_git is dropped entirely.
if sed 's/[[:space:]]*#.*$//' recipes/video/av1.sh \
   | grep -qE 'fetch_git[^#]*PKG_COMMIT'; then
  _pass av1-fetches-via-fetch-git-at-commit
else
  _bad av1-fetches-via-fetch-git-at-commit "no fetch_git call using PKG_COMMIT"
fi
if sed 's/[[:space:]]*#.*$//' recipes/video/av1.sh | grep -q '+archive'; then
  _bad av1-not-a-gitiles-archive-tarball "PKG_URL still uses +archive"
else
  _pass av1-not-a-gitiles-archive-tarball
fi

# -- 7. Every profile supplies a 40-hex commit for all three recipes. --------
# The regression test for the reported failure: a profile value that is not a
# commit is what produced `v<sha>`, and a MISSING one silently reintroduces the
# tag-pinning the rest of this file removes.
for _p in profiles/ffmpeg-*.conf; do
  for _v in PKG_COMMIT_LIBRTMP PKG_COMMIT_LIBPLACEBO PKG_COMMIT_AV1; do
    _val=$(awk -F'"' -v k="^$_v=" '$0 ~ k { print $2; exit }' "$_p")
    _hex=$(printf '%s' "$_val" | tr -d '0-9a-f')
    _len=${#_val}
    if [ -z "$_val" ]; then
      _bad "commit-var-is-40-hex-$(basename "$_p")-$_v" "unset"
    elif [ "$_len" -eq 40 ] && [ -z "$_hex" ]; then
      _pass "commit-var-is-40-hex-$(basename "$_p")-$_v"
    else
      _bad "commit-var-is-40-hex-$(basename "$_p")-$_v" "not a commit: $_val"
    fi
  done
done

# -- 7b. A profile must not put a COMMIT where a VERSION belongs. -----------
# PKG_VERSION_* and PKG_COMMIT_* are now independent knobs and nothing couples
# them. A profile that sets only PKG_VERSION_* to a SHA -- the exact #28 shape
# -- silently gets the recipe's DEFAULT commit under a foreign version label,
# and the stamp (av1-$PKG_VERSION, named by stamp_check in lib/utils.sh) then
# records the lie.
for _p in profiles/ffmpeg-*.conf; do
  for _v in PKG_VERSION_LIBRTMP PKG_VERSION_LIBPLACEBO PKG_VERSION_AV1; do
    _val=$(awk -F'"' -v k="^$_v=" '$0 ~ k { print $2; exit }' "$_p")
    _hex=$(printf '%s' "$_val" | tr -d '0-9a-f')
    if [ "${#_val}" -eq 40 ] && [ -z "$_hex" ]; then
      _bad "version-var-is-not-a-sha-$(basename "$_p")-$_v" "holds a SHA: $_val"
    else
      _pass "version-var-is-not-a-sha-$(basename "$_p")-$_v"
    fi
  done
done

# -- 8. Each git-sourced recipe declares the git it shells out to. ----------
for _r in recipes/other/librtmp.sh recipes/video/av1.sh; do
  if grep -qE '^PKG_REQUIRES_CMD=.*git' "$_r"; then
    _pass "declares-git-dependency-$_r"
  else
    _bad "declares-git-dependency-$_r" "PKG_REQUIRES_CMD does not name git"
  fi
done

[ "$_fail" -eq 0 ] && printf 'git-commit-pinning: all assertions passed.\n'
# Completion sentinel for tests/oracle-baseline.sh: proves the file ran to the
# end on the baseline tree rather than aborting early and scoring a free pass.
printf 'DONE: git-commit-pinning\n'
exit "$_fail"
