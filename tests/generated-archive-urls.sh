#!/bin/sh
# No recipe may fetch a FORGE-GENERATED archive (GH-69).
#
# A `/-/archive/<ref>/name.tar.gz` (GitLab) or `/+archive/<sha>.tar.gz`
# (gitiles) URL is not a published artifact: the forge computes it per request.
# Two consequences, and this tree has now been bitten by both.
#
# It is not byte-stable, so no digest can pin it. tests/git-commit-pinning.sh
# records the gitiles half: aomedia stamps the CURRENT time into the tar headers,
# and two fetches a second apart produced two different sha256s (av1, GH-19/#27).
# GitHub's 2023 codeload change did the same to every checksum recorded against
# one of its generated archives.
#
# And generating it is expensive, which is why a forge puts bot protection in
# front of it. code.videolan.org serves an Anubis challenge page on those paths
# -- intermittently, and with HTTP 200, so `curl -fL -sS` reports success and the
# 7KB HTML lands where a tarball should be. A full clean build died twice on it,
# at two different recipes, before this rule existed.
#
# The rule has two branches: a static release tarball where upstream publishes
# one, and fetch_git where the pin is a commit. Nothing else.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

# --- the ban itself --------------------------------------------------------
#
# Comments are stripped first: the converted recipes DESCRIBE the old URL shape
# in the comment explaining why they moved off it, and an oracle that matched
# prose would fail on the fixed tree for the wrong reason -- the trap
# tests/git-commit-pinning.sh documents for its own no-branch check.
# `if` rather than `grep -q ... && printf`: under `set -e` the && form makes the
# loop's status that of the LAST recipe's grep, and a command substitution that
# exits non-zero in an assignment aborts the script -- silently, before the
# first assertion, which is how this file first ran to exit 1 with no output.
_hits=$(for _r in recipes/*/*.sh recipes/ffmpeg.sh; do
          [ -f "$_r" ] || continue
          if _code_only "$_r" | grep -qE '/-/archive/|/\+archive/'; then
            printf '%s ' "$_r"
          fi
        done)
# A RATCHET, not a clean sweep. Two recipes still fetch generated archives from
# gitlab.com -- lv2 (six sub-package tarballs) and svtav1 -- and converting them
# is a materially larger change than GH-69, which was scoped to the host that is
# actively serving challenge pages. They are grandfathered BY NAME and tracked
# separately, so the rule holds for everything else and the exception cannot
# quietly grow.
#
# The list is asserted EXACTLY, not as a floor: adding a recipe to it is a
# deliberate act that shows up in review, and fixing one requires removing it
# here, which is what stops a grandfather clause from becoming permanent.
_expected_legacy="recipes/audio/lv2.sh recipes/video/svtav1.sh"
# tr, not word splitting: the split is deliberate but shellcheck cannot tell it
# from an accident, and saying it explicitly is clearer than a suppression.
_norm() { printf '%s' "$1" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ' | sed 's/ *$//'; }
_got_legacy=$(_norm "$_hits")
_want_legacy=$(_norm "$_expected_legacy")
# COMPOUND, deliberately, for the reason tests/install-manifest-reconcile.sh
# gives: tests/oracle-baseline.sh requires that no assertion passes on the merge
# base, and the floor half -- "we actually scanned the recipes" -- is true there
# too. Standing alone it would be an assertion that cannot detect the change it
# guards; paired with the list check it stays asserted without buying a free
# pass.
#
# The floor matters on its own terms: if recipes/ ever stops being scanned (a
# renamed directory, a glob matching nothing) the loop above finds no hits and
# the list check reports success having verified nothing.
_scanned=$(find recipes -mindepth 2 -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
if [ "$_got_legacy" = "$_want_legacy" ] && [ "$_scanned" -ge 100 ]; then
  _pass generated-archives-confined-to-the-known-two
else
  _bad generated-archives-confined-to-the-known-two "expected exactly [$_want_legacy], found [$_got_legacy]; scanned $_scanned recipes (floor 100)"
fi

# --- the three that moved to VideoLAN's release server ---------------------
#
# download.videolan.org is a plain static file server; code.videolan.org is the
# Anubis-fronted GitLab. Asserting the HOST is what distinguishes them -- both
# serve something at a dav1d path.
for _pair in "recipes/video/dav1d.sh:dav1d" \
             "recipes/other/libdvdread.sh:libdvdread" \
             "recipes/other/libdvdnav.sh:libdvdnav"; do
  _r=${_pair%%:*}; _n=${_pair#*:}
  if _code_only "$_r" | grep -q 'PKG_URL="https://download.videolan.org/pub/videolan/'; then
    _pass "release-server-$_n"
  else
    _bad "release-server-$_n" "$_r does not fetch from download.videolan.org"
  fi
done

# --- the two that moved to git --------------------------------------------
#
# A full object name, not a tag or an abbreviated SHA: fetch_git rejects those,
# and a 40-hex pin is what makes the fetch self-verifying in the absence of a
# .hash sidecar.
for _pair in "recipes/video/x264.sh:x264" "recipes/other/librist.sh:librist"; do
  _r=${_pair%%:*}; _n=${_pair#*:}
  _body=$(_code_only "$_r")
  _sha=$(printf '%s\n' "$_body" | sed -n 's/^PKG_COMMIT=.*:-\([0-9a-f]*\)}"$/\1/p' | head -1)
  if printf '%s\n' "$_body" | grep -q 'fetch_git ' && [ "${#_sha}" -eq 40 ]; then
    _pass "git-pinned-$_n"
  else
    _bad "git-pinned-$_n" "fetch_git=$(printf '%s\n' "$_body" | grep -c 'fetch_git ') pin='${_sha}' (want a 40-hex object name)"
  fi

  # A git-fetched recipe carries NO sidecar -- the commit is the integrity
  # check. libplacebo, librtmp and av1 already have none; a leftover .hash here
  # would read as verification that no longer happens.
  if [ -e "${_r%.sh}.hash" ]; then
    _bad "no-stale-sidecar-$_n" "${_r%.sh}.hash still exists for a git-fetched recipe"
  else
    _pass "no-stale-sidecar-$_n"
  fi
done

printf 'DONE: generated-archive-urls\n'
exit "$_fail"
