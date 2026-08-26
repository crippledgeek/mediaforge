#!/bin/sh
# Upstream-digest provenance tests for the recipe sidecars (issue #36).
#
# WHAT THIS PINS. A sidecar's provenance comment is the only thing that
# distinguishes "these are the bytes we received" from "these are the bytes
# upstream published". Nothing else in the tree reads that comment, so a
# comment naming a digest the block does not actually record -- or claiming an
# upstream URL for a value computed here -- is invisible: it reads as an
# upstream attestation and is not one. That is worse than no comment, because
# it is believed.
#
# The convention, following Buildroot's .hash files (manual section 18.4,
# "The .hash file"):
#   # <algo> from <URL>            -- that algo's record came from upstream
#   # Locally calculated <date>    -- every digest in the block is ours
# A mixed block carries one comment line per provenance. `size` is derived here
# for every block and is never claimed by a provenance comment.
#
# Every assertion here must FAIL on the merge base -- see tests/oracle-baseline.sh.
# That is why each one also requires the upstream-provenance set to be non-empty:
# on a tree with no such comments the well-formedness checks are vacuous, and a
# vacuous check that reports PASS is exactly the defect that gate exists to catch.
# Two properties this file deliberately does NOT assert, because they hold on the
# base and are covered elsewhere: that verify_file actually checks an optional
# sha512 (tests/checksum-verification.sh, verify-optional-sha512-mismatch), and
# that every sidecar in the tree parses (same file, sidecars-in-tree-validate).
#
# Hermetic: reads the tree, no network.
#
# Usage: tests/upstream-provenance.sh
# Exit 0 = pass, 1 = regression.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT" || exit 1
_fail=0

_pass() { printf 'PASS [%s]\n' "$1"; }
_bad()  { printf 'FAIL [%s] %s\n' "$1" "$(printf '%s' "${2-}" | tr '\n' ' ')" >&2; _fail=1; }

# Floor, not an exact count: #36 recorded 19 upstream digests, and a sidecar
# legitimately loses a block when a profile drops a pinned version. Ten is far
# enough below 19 to survive that, and far enough above zero that no stray
# comment can satisfy it -- which is what makes the checks below non-vacuous.
_MIN_UPSTREAM_CLAIMS=10

# One awk pass per sidecar. For each comment of the form "<algo> from <URL>",
# the block it heads must carry a record with that keyword.
_claims_ok=true
_claims_seen=0
for _h in recipes/*/*.hash recipes/*.hash; do
  [ -f "$_h" ] || continue
  _out=$(awk -v F="$_h" '
    function check(  i, a) {
      for (i = 1; i <= nc; i++) {
        a = calgo[i]
        if (!(a in rec))
          printf("%s: comment claims %s from %s but the block records no %s\n", F, a, curl[i], a)
      }
    }
    function reset() { check(); nc = 0; delete rec; delete calgo; delete curl }
    /^[[:space:]]*$/ { reset(); next }
    /^[[:space:]]*#/ {
      l = $0; sub(/^[[:space:]]*#[[:space:]]*/, "", l)
      if (l ~ /^(sha256|sha512|sha1)[[:space:]]+from[[:space:]]+https:\/\//) {
        split(l, w, /[[:space:]]+/); nc++; calgo[nc] = w[1]; curl[nc] = w[3]; claims++
      }
      next
    }
    NF == 3 { rec[$1] = 1; next }
    END { check(); printf("CLAIMS %d\n", claims + 0) }
  ' "$_h")
  _claims_seen=$((_claims_seen + $(printf '%s\n' "$_out" | awk '/^CLAIMS /{print $2}')))
  _errs=$(printf '%s\n' "$_out" | grep -v '^CLAIMS ' || true)
  if [ -n "$_errs" ]; then _claims_ok=false; _bad provenance-claims-recorded "$_errs"; fi
done

if [ "$_claims_seen" -lt "$_MIN_UPSTREAM_CLAIMS" ]; then
  _bad provenance-claims-recorded \
    "only $_claims_seen upstream-provenance comment(s) found, want >= $_MIN_UPSTREAM_CLAIMS"
elif [ "$_claims_ok" = true ]; then
  _pass provenance-claims-recorded
fi

# `size` is derived here for every block, upstream ones included, so no
# provenance comment may claim upstream published it.
_szclaim=$(grep -hE '^#.*\bsize[[:space:]]+from[[:space:]]+https://' recipes/*/*.hash recipes/*.hash 2>/dev/null || true)
if [ "$_claims_seen" -lt "$_MIN_UPSTREAM_CLAIMS" ]; then
  _bad provenance-never-claims-size \
    "vacuous: only $_claims_seen upstream-provenance comment(s) to check"
elif [ -z "$_szclaim" ]; then
  _pass provenance-never-claims-size
else
  _bad provenance-never-claims-size "$_szclaim"
fi

# openssl and libgme moved off GitHub's /archive/refs/tags/ generated archives
# onto tarballs upstream actually uploaded (#36, closing part of #19's
# byte-instability exposure). A revert would be silent: the generated archive
# downloads fine, and only its BYTES are unstable.
for _r in recipes/crypto/openssl.sh recipes/other/libgme.sh; do
  _name=$(basename "$_r" .sh)
  _u=$(grep -m1 '^PKG_URL=' "$_r")
  case "$_u" in
    *"/archive/refs/tags/"*) _bad "release-asset-$_name" "still fetches a generated tag archive" ;;
    *"/releases/download/"*) _pass "release-asset-$_name" ;;
    *) _bad "release-asset-$_name" "unexpected URL: $_u" ;;
  esac
done

if [ "$_fail" = 0 ]; then printf 'DONE: upstream-provenance OK\n'; exit 0; fi
printf 'DONE: upstream-provenance FAILED\n' >&2; exit 1
