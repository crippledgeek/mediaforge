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
# The `# with key <fpr>` grammar is shared with tests/signing-keys.sh, which
# needs the same recogniser to decide which keys must be committed. It lived
# here first and was reimplemented there; the two drifted immediately, so it
# now has one definition that both files use.
. "$ROOT/tests/lib-provenance.sh"
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
# could really grow. The match is case-folded for the same reason: RFC 3986
# section 3.1 makes scheme names case-insensitive, so "HTTPS://" is a plausible
# copy-paste and would otherwise be invisible in exactly the same way.
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
      # Matched case-folded: RFC 3986 section 3.1 makes scheme names
      # case-insensitive, so "HTTPS://" copy-pasted out of a vendor page is a
      # human transcription rather than a contrived input -- and an
      # unrecognised claim is INVISIBLE here, neither flagged nor counted,
      # which is the same failure the scheme-genericisation above exists to
      # close. Folding covers the algorithm name in one move: `rec` is keyed by
      # the record keywords, which the grammar already fixes as lowercase.
      lc = tolower(l)
      if (lc ~ /^(sha256|sha512|sha1)[[:space:]]+from[[:space:]]+[a-z][a-z0-9+.-]*:\/\//) {
        split(lc, wl, /[[:space:]]+/)   # algo, for the `in rec` lookup
        split(l,  w,  /[[:space:]]+/)   # URL, reported as written
        nc++; calgo[nc] = wl[1]; curl[nc] = w[3]; claims++
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
  grep -hiE '^#([^:]*[[:space:]])?size[[:space:]]+from[[:space:]]+[a-z][a-z0-9+.-]*://' "$@" 2>/dev/null || true
}

# _scan_sigs FILE
# Emit one line per malformed signature-provenance block, then "SIGS <n>".
#
# The grammar is two lines, added to whatever digest-origin comment the block
# already carries:
#   # pgp signature verified <signature URL>
#   # with key <40 uppercase hex fingerprint>
#
# Deliberately NOT Buildroot's single "Locally calculated after checking pgp
# signature" phrase, which bundles two separate claims -- where the digest came
# from, and that a signature was checked. That does not compose with the
# "<algo> from <URL>" origin this tree already records: a digest taken from
# upstream's SHA256SUMS was not locally calculated, so the bundled phrase would
# have to overwrite the origin in order to state the signature. Splitting them
# lets a block say both, and say them truthfully.
#
# Both lines are required together. A block asserting a check without naming
# the key, or naming a key without saying what was verified, reads as a
# stronger attestation than anything that was established -- the security
# theatre issue #37 exists to avoid.
#
# The fingerprint is checked as uppercase because that is what `gpg
# --fingerprint` prints and what Arch's validpgpkeys requires. It is the
# PRIMARY key's fingerprint even when a signing subkey made the signature
# (bzip2 and libressl are both signed by a subkey), because the primary is what
# an independent packager pins and therefore what can be corroborated.
_scan_sigs() {
  awk -v F="$1" -v PIN="$PROVENANCE_PIN_INTENT_RE" -v FPR="$PROVENANCE_FPR_RE" '''
    function check(  ) {
      if (!url && !key) return
      if (url && !key) printf("%s: block verifies %s but names no key\n", F, url)
      if (key && !url) printf("%s: block names key %s without naming a signature\n", F, key)
      if (url && key) sigs++
    }
    function reset() { check(); url = ""; key = "" }
    /^[[:space:]]*$/ { reset(); next }
    # A RECORD line ends the comment run above it, not just a blank line.
    # Resetting only on blanks let two signature blocks written back to back
    # with no separator merge: the second one, naming a signature but no key,
    # would inherit the key from the first and be counted well formed instead
    # of flagged. Every stanza in the tree is blank-separated today, so this
    # closes the gap before a hand-edit opens it.
    # (No apostrophes in this comment: the awk program is inside a
    # single-quoted shell string, and one would end it.)
    NF == 3 && $1 ~ /^(sha256|sha512|sha1|size)$/ { reset(); next }
    /^[[:space:]]*#/ {
      l = $0; sub(/^[[:space:]]*#[[:space:]]*/, "", l); lc = tolower(l)
      if (lc ~ /^pgp[[:space:]]+signature[[:space:]]+verified[[:space:]]+[a-z][a-z0-9+.-]*:\/\//) {
        split(l, w, /[[:space:]]+/)
        if (url) printf("%s: names a second signature %s before naming a key for %s\n", F, w[4], url)
        url = w[4]; next
      }
      # PIN and FPR come from tests/lib-provenance.sh, which explains why
      # recognition is two steps: only a hex-ish token is read as a pin, so
      # prose is not one, while a hex token of the wrong length or case stays
      # loud because it is a malformed pin rather than prose. Sharing them is
      # what keeps this file and tests/signing-keys.sh answering their two
      # different questions about the SAME grammar.
      if (lc ~ PIN) {
        split(l, w, /[[:space:]]+/)
        if (key) printf("%s: names a second key %s before naming a signature for %s\n", F, w[3], key)
        key = w[3]
        if (key !~ FPR) {
          printf("%s: %s is not a 40-character uppercase OpenPGP fingerprint\n", F, key)
          key = ""   # not a usable pin, so it must not pair off or count
        }
        next
      }
      next
    }
    { next }
    END { check(); printf("SIGS %d\n", sigs + 0) }
  ''' "$1"
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

# ------------------------------------------------ signature provenance (#37)
# A signature says WHO published the bytes; a digest only says the bytes match
# what was recorded. The comment is the only record that the first check ever
# happened, so a malformed one is the same class of false attestation the
# claim checks above exist to catch.
# Floor, mirroring _MIN_UPSTREAM_CLAIMS above and for the same reason: this
# branch recorded 15 signature blocks, and a sidecar legitimately loses one
# when a profile drops a pinned version or upstream stops signing. Ten is far
# enough below 15 to survive that, and far enough above zero that no stray
# comment can satisfy it -- which is what keeps the checks non-vacuous.
_MIN_SIG_BLOCKS=10
_sig_ok=true
_sig_seen=0
for _h in recipes/*/*.hash recipes/*.hash; do
  [ -f "$_h" ] || continue
  _sout=$(_scan_sigs "$_h")
  _sig_seen=$((_sig_seen + $(printf '%s\n' "$_sout" | awk '/^SIGS /{print $2}')))
  _serrs=$(printf '%s\n' "$_sout" | grep -v '^SIGS ' || true)
  if [ -n "$_serrs" ]; then _sig_ok=false; _bad signature-provenance-well-formed "$_serrs"; fi
done

if [ "$_sig_seen" -lt "$_MIN_SIG_BLOCKS" ]; then
  _bad signature-provenance-well-formed \
    "only $_sig_seen signature-provenance block(s) found, want >= $_MIN_SIG_BLOCKS"
elif [ "$_sig_ok" = true ]; then
  _pass signature-provenance-well-formed
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
# Gated on _MIN_UPSTREAM_CLAIMS (the signature fixtures below gate on
# _MIN_SIG_BLOCKS instead), and for the same reason rather than for symmetry: these pin the checker that guards the tree's provenance
# comments, so on a tree with none there is nothing for it to guard and a PASS
# here would be an assertion about nothing. It also keeps the file honest under
# tests/oracle-baseline.sh, whose contract is that every assertion in an added
# test file fails against the merge base.
_fx=''
_skip_claim_fixtures=no
if [ "$_claims_seen" -lt "$_MIN_UPSTREAM_CLAIMS" ]; then
  for _cf in checker-detects-overclaim checker-counts-every-scheme-and-order checker-detects-size-claim; do
    _bad "$_cf" "vacuous: only $_claims_seen upstream-provenance comment(s) for the checker to guard"
  done
  _skip_claim_fixtures=yes
fi
# The scratch dir is created when EITHER floor is met, not just the claims one.
# Gating it on claims alone meant a tree with signature blocks but few claims
# ran neither signature assertion -- no PASS and no FAIL, a silent skip, which
# is the one outcome a gate must never produce.
if [ "$_claims_seen" -ge "$_MIN_UPSTREAM_CLAIMS" ] || [ "$_sig_seen" -ge "$_MIN_SIG_BLOCKS" ]; then
  # Reported against the file, not against one assertion group: either floor
  # may be the reason the scratch dir was wanted, so blaming a claims assertion
  # would attribute it to a group that is not necessarily running.
  _fx=$(mktemp -d) || { _bad fixture-scratch-dir "mktemp failed"; _fx=''; }
fi
if [ -n "$_fx" ]; then
  trap 'rm -rf "$_fx"' EXIT INT TERM

  # Sentinel digests. The VALUE is irrelevant but the LENGTH is not:
  # hash_file_validate enforces 64/128 hex characters per keyword, so a short
  # stand-in would make these fixtures test the length check instead of the
  # behaviour they are written for. Written out rather than generated -- `seq`
  # is not in the POSIX utilities, and this file is POSIX sh.
  _H64=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  # 40 uppercase hex: the shape `gpg --fingerprint` prints and the one Arch's
  # validpgpkeys requires. Length and case are both load-bearing here.
  _FPR=AAAABBBBCCCCDDDDEEEEFFFF00001111222233AA
  _H128=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

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
  # Uppercase scheme AND uppercase algorithm name. Before the tolower() fold
  # each of these was invisible -- CLAIMS 0, no error -- reopening the exact
  # hole the http fixture above closes.
  cat > "$_fx/over-upper-scheme.hash" <<EOF

# sha512 from HTTPS://example.invalid/SUMS
sha256  $_H64  a.tar.gz
size    1  a.tar.gz
EOF
  cat > "$_fx/over-upper-algo.hash" <<EOF

# SHA512 from https://example.invalid/SUMS
sha256  $_H64  a.tar.gz
size    1  a.tar.gz
EOF
  cat > "$_fx/size-claim-upper.hash" <<EOF

# size from HTTPS://example.invalid/SUMS
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
sha512  $_H128  c.tar.gz
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
  _e_uscheme=$(_scan_claims "$_fx/over-upper-scheme.hash" | grep -c 'records no sha512' || true)
  _e_ualgo=$(_scan_claims "$_fx/over-upper-algo.hash"     | grep -c 'records no sha512' || true)
  _e_clean=$(_scan_claims "$_fx/clean.hash"     | grep -vc '^CLAIMS ' || true)
  _n_clean=$(_scan_claims "$_fx/clean.hash"     | awk '/^CLAIMS /{print $2}')

  if [ "$_skip_claim_fixtures" = yes ]; then
    :
  elif [ "$_e_https" = 1 ] && [ "$_e_http" = 1 ] \
     && [ "$_e_uscheme" = 1 ] && [ "$_e_ualgo" = 1 ] && [ "$_e_clean" = 0 ]; then
    _pass checker-detects-overclaim
  else
    _bad checker-detects-overclaim \
      "https=$_e_https http=$_e_http HTTPS=$_e_uscheme SHA512=$_e_ualgo (each want 1) clean-errors=$_e_clean (want 0)"
  fi

  # Three claims in clean.hash, one of them http and one written BELOW its
  # records: all three must count, or the floor could be satisfied by fewer
  # comments than are really there.
  if [ "$_skip_claim_fixtures" = yes ]; then
    :
  elif [ "$_n_clean" = 3 ]; then
    _pass checker-counts-every-scheme-and-order
  else
    _bad checker-counts-every-scheme-and-order "counted $_n_clean claim(s), want 3"
  fi

  # Signature-provenance fixtures. Each names a way the two required lines can
  # come apart, and each would read to a human as a stronger attestation than
  # was actually established -- the failure #37 exists to avoid.
  cat > "$_fx/sig-good.hash" <<EOF

# Locally calculated
# pgp signature verified https://example.invalid/a.tar.gz.sig
# with key $_FPR
sha256  $_H64  a.tar.gz
size    1  a.tar.gz
EOF
  cat > "$_fx/sig-no-key.hash" <<EOF

# pgp signature verified https://example.invalid/a.tar.gz.sig
sha256  $_H64  a.tar.gz
size    1  a.tar.gz
EOF
  cat > "$_fx/sig-no-url.hash" <<EOF

# with key $_FPR
sha256  $_H64  a.tar.gz
size    1  a.tar.gz
EOF
  cat > "$_fx/sig-bad-fpr.hash" <<EOF

# pgp signature verified https://example.invalid/a.tar.gz.sig
# with key deadbeef
sha256  $_H64  a.tar.gz
size    1  a.tar.gz
EOF
  # Composes with an upstream-digest origin AND survives http, which the
  # bundled Buildroot phrasing could not express without overwriting the origin.
  cat > "$_fx/sig-with-origin.hash" <<EOF

# sha256 from http://example.invalid/SUMS
# pgp signature verified http://example.invalid/a.tar.gz.sig
# with key $_FPR
sha256  $_H64  a.tar.gz
size    1  a.tar.gz
EOF

  # Gated on the SIGNATURE floor, not the claims floor: these pin the checker
  # that guards the tree's signature blocks, so on a tree with none there is
  # nothing to guard and a PASS would assert about nothing. tests/oracle-baseline.sh
  # cannot enforce that here -- it selects only ADDED test files, and this one is
  # modified, which is the known gap its own header documents.
  if [ "$_sig_seen" -lt "$_MIN_SIG_BLOCKS" ]; then
    for _cf in checker-detects-malformed-signature-block signature-composes-with-digest-origin; do
      _bad "$_cf" "vacuous: only $_sig_seen signature block(s) for the checker to guard"
    done
    _skip_sig_fixtures=yes
  fi
  # Two signature blocks back to back with NO blank line between them. The
  # second names a signature and no key; if the scanner only reset on blanks it
  # would inherit the first key and score the second block as well formed --
  # the reviewer finding this pins.
  cat > "$_fx/sig-adjacent.hash" <<EOF

# pgp signature verified https://example.invalid/a.tar.gz.sig
# with key $_FPR
sha256  $_H64  a.tar.gz
size    1  a.tar.gz
# pgp signature verified https://example.invalid/b.tar.gz.sig
sha256  $_H64  b.tar.gz
size    2  b.tar.gz
EOF
  # Two signatures in ONE comment run. Silently overwriting the first paired
  # the second URL with the first key -- a recorded key that does not
  # correspond to the recorded signature, which is the false attestation this
  # checker exists to catch.
  cat > "$_fx/sig-double-url.hash" <<EOF

# pgp signature verified https://example.invalid/a.tar.gz.sig
# with key $_FPR
# pgp signature verified https://example.invalid/b.tar.gz.sig
sha256  $_H64  a.tar.gz
size    1  a.tar.gz
EOF
  # Extra whitespace between the literal words. Hard-coded single spaces made
  # the whole block INVISIBLE -- neither counted nor flagged -- which is the
  # failure mode _scan_claims argues against at length in its own header.
  cat > "$_fx/sig-spaced.hash" <<EOF

#  pgp   signature   verified   https://example.invalid/a.tar.gz.sig
#  with   key   $_FPR
sha256  $_H64  a.tar.gz
size    1  a.tar.gz
EOF
  # The mirror case: two keys in one run. Silently overwriting pairs the first
  # signature with the SECOND key -- the same false attestation as double-url,
  # and it had no fixture until a mutation test found the gap.
  cat > "$_fx/sig-double-key.hash" <<EOF

# pgp signature verified https://example.invalid/a.tar.gz.sig
# with key $_FPR
# with key AAAABBBBCCCCDDDDEEEEFFFF00001111222233BB
sha256  $_H64  a.tar.gz
size    1  a.tar.gz
EOF
  # Prose a maintainer might write. Reading its third word as a fingerprint
  # failed the entire gate on a comment; a lowercase hex token of the wrong
  # length must still be loud, because that is a malformed pin, not prose.
  cat > "$_fx/sig-prose.hash" <<EOF

# pgp signature verified https://example.invalid/a.tar.gz.sig
# with key $_FPR
# with key rotation pending upstream
sha256  $_H64  a.tar.gz
size    1  a.tar.gz
EOF
  cat > "$_fx/sig-shortfpr.hash" <<EOF

# pgp signature verified https://example.invalid/a.tar.gz.sig
# with key abc123
sha256  $_H64  a.tar.gz
size    1  a.tar.gz
EOF
  _s_prose=$(_scan_sigs "$_fx/sig-prose.hash" | grep -vc '^SIGS ' || true)
  _s_prosen=$(_scan_sigs "$_fx/sig-prose.hash" | awk '/^SIGS /{print $2}')
  _s_short=$(_scan_sigs "$_fx/sig-shortfpr.hash" | grep -c 'not a 40-character' || true)
  # The COUNT, not just the message. The shape error fires either way, so
  # asserting only the message left "a malformed pin must not pair off or
  # count" unpinned -- deleting that half kept the suite green while a block
  # with a garbage fingerprint counted toward the floor as well formed.
  _s_shortn=$(_scan_sigs "$_fx/sig-shortfpr.hash" | awk '/^SIGS /{print $2}')
  _s_fprn=$(_scan_sigs "$_fx/sig-bad-fpr.hash" | awk '/^SIGS /{print $2}')
  _s_dblk=$(_scan_sigs "$_fx/sig-double-key.hash" | grep -c 'second key' || true)
  _s_dbl=$(_scan_sigs "$_fx/sig-double-url.hash" | grep -c 'second signature' || true)
  _s_sp=$(_scan_sigs "$_fx/sig-spaced.hash" | awk '/^SIGS /{print $2}')
  _s_spe=$(_scan_sigs "$_fx/sig-spaced.hash" | grep -vc '^SIGS ' || true)
  _s_adj=$(_scan_sigs "$_fx/sig-adjacent.hash" | grep -c 'names no key' || true)
  _s_adjn=$(_scan_sigs "$_fx/sig-adjacent.hash" | awk '/^SIGS /{print $2}')

  _s_good=$(_scan_sigs "$_fx/sig-good.hash" | grep -vc '^SIGS ' || true)
  _s_n=$(_scan_sigs "$_fx/sig-good.hash" | awk '/^SIGS /{print $2}')
  _s_nokey=$(_scan_sigs "$_fx/sig-no-key.hash"  | grep -c 'names no key' || true)
  _s_nourl=$(_scan_sigs "$_fx/sig-no-url.hash"  | grep -c 'without naming a signature' || true)
  _s_fpr=$(_scan_sigs "$_fx/sig-bad-fpr.hash"   | grep -c 'not a 40-character' || true)
  _s_orig=$(_scan_sigs "$_fx/sig-with-origin.hash" | awk '/^SIGS /{print $2}')
  _s_origc=$(_scan_claims "$_fx/sig-with-origin.hash" | awk '/^CLAIMS /{print $2}')

  if [ "${_skip_sig_fixtures:-no}" = yes ]; then
    :
  elif [ "$_s_good" = 0 ] && [ "$_s_n" = 1 ] && [ "$_s_nokey" = 1 ] \
     && [ "$_s_nourl" = 1 ] && [ "$_s_fpr" = 1 ] \
     && [ "$_s_adj" = 1 ] && [ "$_s_adjn" = 1 ] \
     && [ "$_s_dbl" = 1 ] && [ "$_s_dblk" = 1 ] \
     && [ "$_s_sp" = 1 ] && [ "$_s_spe" = 0 ] \
     && [ "$_s_prose" = 0 ] && [ "$_s_prosen" = 1 ] && [ "$_s_short" = 1 ] \
     && [ "$_s_shortn" = 0 ] && [ "$_s_fprn" = 0 ]; then
    _pass checker-detects-malformed-signature-block
  else
    _bad checker-detects-malformed-signature-block \
      "good-errs=$_s_good (want 0) good-count=$_s_n nokey=$_s_nokey nourl=$_s_nourl badfpr=$_s_fpr adjacent=$_s_adj adjacent-sigs=$_s_adjn double-url=$_s_dbl double-key=$_s_dblk spaced-sigs=$_s_sp spaced-errs=$_s_spe prose-errs=$_s_prose prose-sigs=$_s_prosen shortfpr=$_s_short shortfpr-sigs=$_s_shortn (want 0) badfpr-sigs=$_s_fprn (want 0)"
  fi

  # The whole reason for splitting the grammar: one block states both a digest
  # origin and a signature check, and each checker sees its own.
  if [ "${_skip_sig_fixtures:-no}" = yes ]; then
    :
  elif [ "$_s_orig" = 1 ] && [ "$_s_origc" = 1 ]; then
    _pass signature-composes-with-digest-origin
  else
    _bad signature-composes-with-digest-origin "sigs=$_s_orig claims=$_s_origc (both want 1)"
  fi

  if [ "$_skip_claim_fixtures" = yes ]; then
    :
  elif [ -n "$(_size_claims "$_fx/size-claim-http.hash")" ] \
     && [ -n "$(_size_claims "$_fx/size-claim-https.hash")" ] \
     && [ -n "$(_size_claims "$_fx/size-claim-upper.hash")" ] \
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
