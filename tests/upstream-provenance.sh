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

# _scan_claims FILE
# Emit one line per overclaiming comment, then "CLAIMS <n>".
#
# A claim is "<algo> from <URL>"; the block it appears in must carry a record
# with that keyword. Order-insensitive within the block -- a claim written
# below its records is still checked.
#
# The scheme is matched generically, NOT as a literal https://. Anchoring on
# https would mean a comment reading "sha512 from http://example.org/SUMS" is
# neither flagged nor counted -- it would slip past as an unrecognised comment
# while still reading to a human as an upstream attestation, which is the exact
# false-attestation this file exists to catch. Both downloads.xiph.org and
# ftp.gnu.org serve sums files over plain http, so that is a shape this tree
# could really grow.
#
# One definition, used for both the real tree and the fixtures below: a checker
# that the negative test exercises must be the same one the tree is checked
# with, or the test proves nothing about the tree.
_scan_claims() {
  awk -v F="$1" '
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
      if (l ~ /^(sha256|sha512|sha1)[[:space:]]+from[[:space:]]+[a-z][a-z0-9+.-]*:\/\//) {
        split(l, w, /[[:space:]]+/); nc++; calgo[nc] = w[1]; curl[nc] = w[3]; claims++
      }
      next
    }
    NF == 3 { rec[$1] = 1; next }
    END { check(); printf("CLAIMS %d\n", claims + 0) }
  ' "$1"
}

# _size_claims FILE...
# Emit any provenance comment claiming upstream published `size`.
#
# Same generic-scheme reasoning as _scan_claims. `\b` is deliberately absent:
# it is a GNU extension, not POSIX ERE, and on a BSD/macOS grep it can degrade
# to matching nothing -- an always-pass check.
_size_claims() {
  grep -hE '^#([^:]*[[:space:]])?size[[:space:]]+from[[:space:]]+[a-z][a-z0-9+.-]*://' "$@" 2>/dev/null || true
}

_claims_ok=true
_claims_seen=0
for _h in recipes/*/*.hash recipes/*.hash; do
  [ -f "$_h" ] || continue
  _out=$(_scan_claims "$_h")
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
#
# Known limit: this tree-level call is an assert-absence check, so while the
# tree stays clean no mutation of THIS call site can be detected -- there is
# nothing here to find. What is testable is the helper, and
# checker-detects-size-claim below pins it against both schemes.
_szclaim=$(_size_claims recipes/*/*.hash recipes/*.hash)
if [ "$_claims_seen" -lt "$_MIN_UPSTREAM_CLAIMS" ]; then
  _bad provenance-never-claims-size \
    "vacuous: only $_claims_seen upstream-provenance comment(s) to check"
elif [ -z "$_szclaim" ]; then
  _pass provenance-never-claims-size
else
  _bad provenance-never-claims-size "$_szclaim"
fi

# -------------------------------------------------- the checker actually fires
# _MIN_UPSTREAM_CLAIMS makes claim COUNTING non-vacuous; it says nothing about
# claim CHECKING. Sabotage the predicate (`if (!(a in rec))` -> `if (0)`) and
# every assertion above still reports PASS, because the tree has no overclaim to
# find. So the one check carrying this file's whole purpose needs a case where
# an overclaim is known to be present. tests/oracle-baseline.sh cannot supply
# it: on the merge base these assertions fail on the FLOOR, never on the check.
#
# Runs the same _scan_claims / _size_claims the tree is checked with -- a
# fixture exercising a separate copy would prove nothing about the tree.
# Gated on the same floor as the checks above, and for the same reason rather
# than for symmetry: these pin the checker that guards the tree's provenance
# comments, so on a tree with none there is nothing for it to guard and a PASS
# here would be an assertion about nothing. It also keeps the file honest under
# tests/oracle-baseline.sh, whose contract is that every assertion in an added
# test file fails against the merge base.
_fx=''
if [ "$_claims_seen" -lt "$_MIN_UPSTREAM_CLAIMS" ]; then
  for _cf in checker-detects-overclaim checker-counts-every-scheme-and-order checker-detects-size-claim; do
    _bad "$_cf" "vacuous: only $_claims_seen upstream-provenance comment(s) for the checker to guard"
  done
else
  _fx=$(mktemp -d) || { _bad checker-detects-overclaim "mktemp failed"; _fx=''; }
fi
if [ -n "$_fx" ]; then
  trap 'rm -rf "$_fx"' EXIT INT TERM

  _H64=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

  # Claims sha512, records only sha256.
  cat > "$_fx/over-https.hash" <<EOF

# sha512 from https://example.invalid/SUMS
sha256  $_H64  a.tar.gz
size    1  a.tar.gz
EOF
  # The same overclaim over plain http. Anchoring the scanner on https:// made
  # this one INVISIBLE -- neither flagged nor counted -- which is strictly worse
  # than unchecked, because it still reads as an attestation.
  cat > "$_fx/over-http.hash" <<EOF

# sha512 from http://example.invalid/SUMS
sha256  $_H64  a.tar.gz
size    1  a.tar.gz
EOF
  # Claims exactly what it records, in both orders, plus a mixed block.
  cat > "$_fx/clean.hash" <<EOF

# sha256 from https://example.invalid/SUMS
sha256  $_H64  a.tar.gz
size    1  a.tar.gz

sha256  $_H64  b.tar.gz
size    2  b.tar.gz
# sha256 from http://example.invalid/SUMS

# sha512 from https://example.invalid/b.sha512
# sha256 locally calculated 2026-08-26
sha512  $(printf 'b%.0s' $(seq 1 128))  c.tar.gz
sha256  $_H64  c.tar.gz
size    3  c.tar.gz
EOF
  # http, not https, and deliberately so: with the size grep anchored on https
  # this fixture passed either way, so it could not tell a working check from a
  # scheme-locked one. Both schemes are asserted below.
  cat > "$_fx/size-claim-http.hash" <<EOF

# size from http://example.invalid/SUMS
sha256  $_H64  a.tar.gz
size    1  a.tar.gz
EOF
  cat > "$_fx/size-claim-https.hash" <<EOF

# size from https://example.invalid/SUMS
sha256  $_H64  a.tar.gz
size    1  a.tar.gz
EOF

  _e_https=$(_scan_claims "$_fx/over-https.hash" | grep -c 'records no sha512' || true)
  _e_http=$(_scan_claims "$_fx/over-http.hash"  | grep -c 'records no sha512' || true)
  _e_clean=$(_scan_claims "$_fx/clean.hash"     | grep -vc '^CLAIMS ' || true)
  _n_clean=$(_scan_claims "$_fx/clean.hash"     | awk '/^CLAIMS /{print $2}')

  if [ "$_e_https" = 1 ] && [ "$_e_http" = 1 ] && [ "$_e_clean" = 0 ]; then
    _pass checker-detects-overclaim
  else
    _bad checker-detects-overclaim \
      "https=$_e_https (want 1) http=$_e_http (want 1) clean-errors=$_e_clean (want 0)"
  fi

  # Three claims in clean.hash, one of them http and one written BELOW its
  # records: all three must count, or the floor could be satisfied by fewer
  # comments than are really there.
  if [ "$_n_clean" = 3 ]; then
    _pass checker-counts-every-scheme-and-order
  else
    _bad checker-counts-every-scheme-and-order "counted $_n_clean claim(s), want 3"
  fi

  if [ -n "$(_size_claims "$_fx/size-claim-http.hash")" ] \
     && [ -n "$(_size_claims "$_fx/size-claim-https.hash")" ] \
     && [ -z "$(_size_claims "$_fx/clean.hash")" ]; then
    _pass checker-detects-size-claim
  else
    _bad checker-detects-size-claim \
      "http=[$(_size_claims "$_fx/size-claim-http.hash")] https=[$(_size_claims "$_fx/size-claim-https.hash")] clean=[$(_size_claims "$_fx/clean.hash")]"
  fi
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
