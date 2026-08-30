#!/bin/sh
# No recipe may fetch a GitLab or gitiles GENERATED archive (GH-69).
#
# SCOPE, STATED FIRST BECAUSE IT IS NARROWER THAN THE MOTIVATION BELOW. The
# assertion matches two URL shapes and only two: `/-/archive/` (GitLab) and
# `/+archive/` (gitiles). GitHub's `/<owner>/<repo>/archive/refs/tags/...` is a
# generated archive by the same definition and is NOT matched -- 38 recipes in
# this tree fetch one, including recipes/ffmpeg.sh, which the scan below reads.
#
# That is a deliberate line, not an oversight, and it is drawn where the harm
# is: the two matched hosts regenerate per request AND front the endpoint with
# bot protection, which is what broke real builds here. GitHub's archives are
# the reason the byte-stability half of this file's argument is stated at all
# (its 2023 codeload change invalidated recorded digests tree-wide), but they
# are served without a challenge and their sidecars verify today -- all 38 pass
# on a full build. Widening the pattern would mean converting 38 recipes, which
# is its own change with its own risk, not a line in this one.
#
# So: a new GitHub tag-archive recipe will NOT be rejected here. If that becomes
# the rule, widen the pattern and grandfather the 38 the same way lv2 and svtav1
# are grandfathered below.
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
# The replacement has two branches: a static release tarball where upstream
# publishes one, and fetch_git where the pin is a commit. Nothing else -- for a
# recipe this rule covers, per the scope note above.
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
#
# The RESOLVED value is asserted, not the source text. These three build their
# URL through videolan_release_url (lib/download.sh), so a grep for the literal
# host string reports on how the URL is spelled rather than on where the recipe
# actually fetches from -- it went red on the refactor that introduced the
# helper, while every resolved URL was byte-identical, and it would stay green
# for a recipe that spelled the host in a comment and fetched elsewhere.
# Sourcing answers the question the assertion is named for.
for _pair in "recipes/video/dav1d.sh:dav1d" \
             "recipes/other/libdvdread.sh:libdvdread" \
             "recipes/other/libdvdnav.sh:libdvdnav"; do
  _r=${_pair%%:*}; _n=${_pair#*:}
  _url=$(
    PKG_URL=''
    # SCRIPT_DIR is how lib/utils.sh finds lib/stage.sh, and framework.sh is
    # what defines ffmpeg_version_ge, which two of these three call at source
    # time. Without either, the source fails and the URL comes back empty --
    # which reads identically to "fetches from the wrong host", so both are
    # named here rather than discovered again from a blank failure detail.
    SCRIPT_DIR="$ROOT"; export SCRIPT_DIR
    # shellcheck source=lib/utils.sh
    . "$ROOT/lib/utils.sh" > /dev/null 2>&1 || exit 0
    # shellcheck source=lib/framework.sh
    . "$ROOT/lib/framework.sh" > /dev/null 2>&1 || exit 0
    # shellcheck source=lib/download.sh
    . "$ROOT/lib/download.sh" > /dev/null 2>&1 || exit 0
    # shellcheck disable=SC1090
    . "$ROOT/$_r" > /dev/null 2>&1 || exit 0
    printf '%s' "${PKG_URL:-}"
  ) || _url=""
  case "$_url" in
    https://download.videolan.org/pub/videolan/"$_n"/*) _pass "release-server-$_n" ;;
    *) _bad "release-server-$_n" "$_r resolves to '${_url:-<empty>}'" ;;
  esac
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
