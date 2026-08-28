#!/bin/sh
# Committed signing-key tests for the recipe sidecars (issue #40).
#
# WHAT THIS PINS. A `# with key <fpr>` line records WHICH key made a signature.
# It does not record what that key SAID at pin time. Expiry, revocation, UIDs
# and subkey bindings are all self-signatures the holder can change afterwards,
# and every one of them is fetched fresh on each verification -- so a verdict
# recorded here can flip with no commit touching this repo. #37 hit that twice:
# six of sixteen signatures return EXPKEYSIG, and expiry is reversible, so a
# single upstream extension would silently change the answer a re-verifier gets
# for gmp and would make nettle recordable on exactly the evidence failing
# today.
#
# Committing the key material removes that drift: keys/<FINGERPRINT>.asc is the
# key as it stood when the digest was pinned. This file gates the pairing in
# both directions, because either half alone rots:
#   * a pin naming a key we did not commit is the drift the keys exist to close;
#   * a committed key no block references is dead weight nobody re-checks, and
#     it is how a stale key survives the recipe that justified it.
#
# It also gates keys/INDEX, which records whether each key is expired AS
# COMMITTED. That is the reviewable fact the issue asks for: `gpg` consulted
# today answers about today, and the whole point is to have an answer that a
# diff can be reviewed against.
#
# Deliberately NOT here: build-time signature verification. #37 settled that --
# the digests are committed and diff-reviewed, so gpg stays a maintainer tool
# rather than becoming a build dependency.
#
# Every assertion here must FAIL on the merge base -- see tests/oracle-baseline.sh.
# That is why each one is gated on a floor: on a tree with no committed keys the
# pairing checks are vacuous, and a vacuous check reporting PASS is exactly the
# defect that gate exists to catch.
#
# Hermetic: reads the tree and runs gpg offline against a scratch GNUPGHOME.
# No keyserver, no network.
#
# Usage: tests/signing-keys.sh
# Exit 0 = pass, 1 = regression.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT" || exit 1
_fail=0

_pass() { printf 'PASS [%s]\n' "$1"; }
_bad()  { printf 'FAIL [%s] %s\n' "$1" "$(printf '%s' "${2-}" | tr '\n' ' ')" >&2; _fail=1; }

KEYDIR=keys

# Floors, not exact counts, mirroring tests/upstream-provenance.sh and for the
# same reason: #39 pinned 14 distinct fingerprints across 15 blocks, and a
# sidecar legitimately loses a block when a profile drops a pinned version. Ten
# is far enough below 14 to survive that, and far enough above zero that no
# stray file can satisfy it -- which is what keeps every check below non-vacuous.
_MIN_KEYS=10

# _pinned_fprs FILE...
# Emit each fingerprint pinned by a `# with key` line, sorted, deduplicated.
#
# The leading `#` is stripped before the fields are read rather than matched as
# a field, because `#with key X` and `# with key X` differ in field NUMBER and
# only the second would be seen -- an unrecognised pin here is INVISIBLE, which
# is the same failure mode tests/upstream-provenance.sh documents for its
# scheme-genericisation. Only a 40-uppercase-hex token counts, matching the
# grammar _scan_sigs already enforces there: prose like "with key rotation
# pending upstream" is a comment a maintainer may write, not a pin.
_pinned_fprs() {
  sed -n 's/^[[:space:]]*#[[:space:]]*//p' "$@" 2>/dev/null \
    | awk '$1 == "with" && $2 == "key" && $3 ~ /^[0-9A-F]{40}$/ { print $3 }' \
    | sort -u
}

# _committed_fprs KEYDIR
# Emit the fingerprint each committed key file claims by its NAME, sorted.
#
# The name is the claim; that the bytes inside agree with it is a separate
# assertion below. Keeping them apart means a mismatched file is reported as a
# mismatch rather than silently disappearing from the pairing.
_committed_fprs() {
  find "$1" -maxdepth 1 -name '*.asc' -type f 2>/dev/null \
    | sed 's|.*/||; s|\.asc$||' \
    | sort -u
}

# _key_pairing KEYDIR FILE...
# Emit one line per pin with no committed key, and one per key no block cites.
#
# One helper for both directions so the fixtures below exercise the same code
# the tree is checked with -- a fixture running a separate copy would prove
# nothing about the tree. Output is sorted because awk's `for (k in a)` has no
# defined order, and an unstable failure message is one nobody trusts.
_key_pairing() {
  _kp_dir=$1; shift
  { _pinned_fprs "$@" | sed 's/^/PIN /'; _committed_fprs "$_kp_dir" | sed 's/^/KEY /'; } \
    | awk '
        $1 == "PIN" { pin[$2] = 1; next }
        $1 == "KEY" { key[$2] = 1; next }
        END {
          for (f in pin) if (!(f in key)) printf("pinned %s has no committed key\n", f)
          for (f in key) if (!(f in pin)) printf("committed key %s is cited by no block\n", f)
        }' \
    | sort
}

# _key_fpr FILE
# Emit the PRIMARY key fingerprint of a committed key file, from the bytes.
#
# --show-keys parses without importing, so this needs no keyring and touches no
# network. Colon output is the parseable interface gpg documents (doc/DETAILS);
# the human format is explicitly not one. The fpr line taken is the FIRST,
# which follows the pub record and therefore describes the primary key -- the
# same key the pin names, even where a subkey made the signature (bzip2 and
# libressl are both signed by a subkey).
_key_fpr() {
  gpg --show-keys --with-colons "$1" 2>/dev/null \
    | awk -F: '$1 == "fpr" { print $10; exit }'
}

# _key_state FILE
# Emit valid | expired | revoked for a committed key file, from the bytes.
#
# Field 2 of the pub record is gpg's validity letter. Only the primary record
# is read (exit on the first), because a lapsed SUBKEY on an otherwise live
# primary is a different fact from the one INDEX records, and folding them
# would make the column mean two things.
_key_state() {
  gpg --show-keys --with-colons "$1" 2>/dev/null \
    | awk -F: '$1 == "pub" { print ($2 == "e") ? "expired" : ($2 == "r") ? "revoked" : "valid"; exit }'
}

_have_gpg=no
command -v gpg >/dev/null 2>&1 && _have_gpg=yes

_keys_seen=$(_committed_fprs "$KEYDIR" | grep -c . || true)

# ------------------------------------------------------------ pairing (both ways)
# Split into two assertions rather than one, because they fail for opposite
# reasons and a single verdict would not say which: a missing key means the
# drift this issue exists to close is still open, an orphaned key means a
# recipe moved on and left its evidence behind.
_pairs=$(_key_pairing "$KEYDIR" recipes/*/*.hash recipes/*.hash)
_missing=$(printf '%s\n' "$_pairs" | grep 'has no committed key' || true)
_orphan=$(printf '%s\n' "$_pairs" | grep 'cited by no block' || true)

if [ "$_keys_seen" -lt "$_MIN_KEYS" ]; then
  _bad pinned-keys-committed \
    "only $_keys_seen committed key(s) in $KEYDIR/, want >= $_MIN_KEYS"
elif [ -n "$_missing" ]; then
  _bad pinned-keys-committed "$_missing"
else
  _pass pinned-keys-committed
fi

if [ "$_keys_seen" -lt "$_MIN_KEYS" ]; then
  _bad committed-keys-cited \
    "only $_keys_seen committed key(s) in $KEYDIR/, want >= $_MIN_KEYS"
elif [ -n "$_orphan" ]; then
  _bad committed-keys-cited "$_orphan"
else
  _pass committed-keys-cited
fi

# ------------------------------------------------------ the file is the key it claims
# The filename is what the pairing above matches on, so a file whose BYTES are a
# different key would pair off cleanly while committing the wrong material --
# the one failure that makes the whole record worse than no record, because it
# reads as corroboration.
if [ "$_keys_seen" -lt "$_MIN_KEYS" ]; then
  _bad key-file-matches-its-name \
    "only $_keys_seen committed key(s) in $KEYDIR/, want >= $_MIN_KEYS"
elif [ "$_have_gpg" != yes ]; then
  printf 'SKIP [key-file-matches-its-name] gpg not installed\n'
else
  _mism=''
  for _k in "$KEYDIR"/*.asc; do
    [ -f "$_k" ] || continue
    _want=$(basename "$_k" .asc)
    _got=$(_key_fpr "$_k")
    [ "$_want" = "$_got" ] || _mism="$_mism$_k contains ${_got:-no key}, not $_want; "
  done
  if [ -n "$_mism" ]; then _bad key-file-matches-its-name "$_mism"; else _pass key-file-matches-its-name; fi
fi

# ------------------------------------------------------------ INDEX (state as committed)
# keys/INDEX records what each committed key SAYS ABOUT ITSELF at pin time.
# Without it the expiry state is whatever gpg reports on the day someone asks,
# which is the drift the committed material exists to remove -- committing the
# bytes but reading their verdict live would close only half the gap.
#
# Grammar, one row per key, whitespace separated:
#   <40 uppercase hex>  <valid|expired|revoked>  <uid as exported>
INDEX=$KEYDIR/INDEX

_index_fprs() {
  awk '/^[[:space:]]*#/ || NF == 0 { next } { print $1 }' "$INDEX" 2>/dev/null | sort -u
}

if [ "$_keys_seen" -lt "$_MIN_KEYS" ]; then
  _bad index-covers-every-key \
    "only $_keys_seen committed key(s) in $KEYDIR/, want >= $_MIN_KEYS"
elif [ ! -f "$INDEX" ]; then
  _bad index-covers-every-key "$INDEX is missing"
else
  _ix=$({ _committed_fprs "$KEYDIR" | sed 's/^/KEY /'; _index_fprs | sed 's/^/IDX /'; } \
    | awk '
        $1 == "KEY" { key[$2] = 1; next }
        $1 == "IDX" { idx[$2] = 1; next }
        END {
          for (f in key) if (!(f in idx)) printf("%s has no INDEX row\n", f)
          for (f in idx) if (!(f in key)) printf("INDEX row %s has no key file\n", f)
        }' | sort)
  if [ -n "$_ix" ]; then _bad index-covers-every-key "$_ix"; else _pass index-covers-every-key; fi
fi

# The column is only worth having if it is the committed bytes' own answer. A
# hand-typed state that drifted from the material would be a false attestation
# of exactly the kind tests/upstream-provenance.sh exists to catch -- it reads
# as evidence and is not.
if [ "$_keys_seen" -lt "$_MIN_KEYS" ]; then
  _bad index-state-matches-material \
    "only $_keys_seen committed key(s) in $KEYDIR/, want >= $_MIN_KEYS"
elif [ "$_have_gpg" != yes ]; then
  printf 'SKIP [index-state-matches-material] gpg not installed\n'
elif [ ! -f "$INDEX" ]; then
  _bad index-state-matches-material "$INDEX is missing"
else
  _drift=''
  while read -r _f _state _rest; do
    case "$_f" in ''|'#'*) continue ;; esac
    [ -f "$KEYDIR/$_f.asc" ] || continue   # reported by index-covers-every-key
    _real=$(_key_state "$KEYDIR/$_f.asc")
    [ "$_state" = "$_real" ] || _drift="$_drift$_f: INDEX says $_state, material says ${_real:-unreadable}; "
  done < "$INDEX"
  if [ -n "$_drift" ]; then
    _bad index-state-matches-material "$_drift"
  else
    _pass index-state-matches-material
  fi
fi

# ------------------------------------------------------------- the checker actually fires
# The tree-level checks above are assert-absence: while the tree is clean, no
# mutation of them can be detected, because there is nothing there to find.
# What is testable is the helper, so these fixtures put a known-unpaired pin and
# a known-orphaned key in front of the SAME _key_pairing the tree is checked
# with. Gated on the same floor for the same reason the others are: on a tree
# with no committed keys there is nothing for the helper to guard, and a PASS
# here would be an assertion about nothing -- which is also what keeps this file
# honest under tests/oracle-baseline.sh.
if [ "$_keys_seen" -lt "$_MIN_KEYS" ]; then
  _bad checker-detects-unpaired-key \
    "vacuous: only $_keys_seen committed key(s) for the helper to guard"
else
  _fx=$(mktemp -d) || { _bad checker-detects-unpaired-key "mktemp failed"; _fx=''; }
fi
if [ -n "${_fx:-}" ]; then
  trap 'rm -rf "$_fx"' EXIT INT TERM
  mkdir -p "$_fx/keys"
  # 40 uppercase hex: the shape gpg --fingerprint prints and the one Arch's
  # validpgpkeys requires. Case and length are both load-bearing -- a lowercase
  # or short token is not a pin, and _pinned_fprs must not read it as one.
  _A=AAAABBBBCCCCDDDDEEEEFFFF00001111222233AA
  _B=AAAABBBBCCCCDDDDEEEEFFFF00001111222233BB
  _C=AAAABBBBCCCCDDDDEEEEFFFF00001111222233CC
  # Content is irrelevant to the pairing, which matches on names only; the
  # bytes are what key-file-matches-its-name checks, and that runs on the tree.
  : > "$_fx/keys/$_A.asc"        # paired
  : > "$_fx/keys/$_C.asc"        # orphan: no block cites it
  cat > "$_fx/paired.hash" <<EOF

# pgp signature verified https://example.invalid/a.tar.gz.sig
# with key $_A
sha256  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  a.tar.gz
size    1  a.tar.gz
EOF
  cat > "$_fx/unpaired.hash" <<EOF

# pgp signature verified https://example.invalid/b.tar.gz.sig
# with key $_B
sha256  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  b.tar.gz
size    1  b.tar.gz
EOF
  # Prose, and a hex token of the wrong case. Neither is a pin, and reading
  # either as one would make the gate fail on a comment -- the failure mode
  # tests/upstream-provenance.sh hit and documented at its sig-prose fixture.
  cat > "$_fx/prose.hash" <<EOF

# with key rotation pending upstream
# with key aaaabbbbccccddddeeeeffff00001111222233dd
sha256  cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc  c.tar.gz
size    1  c.tar.gz
EOF
  _p_all=$(_key_pairing "$_fx/keys" "$_fx/paired.hash" "$_fx/unpaired.hash" "$_fx/prose.hash")
  _p_miss=$(printf '%s\n' "$_p_all" | grep -c "pinned $_B has no committed key" || true)
  _p_orph=$(printf '%s\n' "$_p_all" | grep -c "committed key $_C is cited by no block" || true)
  _p_n=$(printf '%s\n' "$_p_all" | grep -c . || true)
  # Exactly two lines: the paired fingerprint must produce NEITHER message, and
  # neither prose line may enter the pin set. Asserting only the two greps left
  # both of those unpinned -- a helper that flagged everything would score the
  # same.
  _p_clean=$(_key_pairing "$_fx/keys" "$_fx/paired.hash" | grep -c "pinned $_A" || true)
  if [ "$_p_miss" = 1 ] && [ "$_p_orph" = 1 ] && [ "$_p_n" = 2 ] && [ "$_p_clean" = 0 ]; then
    _pass checker-detects-unpaired-key
  else
    _bad checker-detects-unpaired-key \
      "missing=$_p_miss (want 1) orphan=$_p_orph (want 1) total=$_p_n (want 2) paired-flagged=$_p_clean (want 0)"
  fi
fi

if [ "$_fail" = 0 ]; then printf 'DONE: signing-keys OK\n'; exit 0; fi
printf 'DONE: signing-keys FAILED\n' >&2; exit 1
