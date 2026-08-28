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
# Hermetic: reads the tree and runs gpg against a scratch GNUPGHOME this file
# creates and removes. No keyserver, no network, and the invoker's own ~/.gnupg
# is neither read nor created -- gpg creates a homedir on first use, so a bare
# `gpg` call here would have side effects on a fresh machine or CI runner.
#
# Usage: tests/signing-keys.sh
# Exit 0 = pass, 1 = regression.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT" || exit 1
# The `# with key <fpr>` recogniser, shared with tests/upstream-provenance.sh.
# That file asks whether a stanza is well formed and this one asks which keys
# must be committed -- two questions, one grammar, and it is defined once
# because the two hand-written copies drifted the day they were written.
. "$ROOT/tests/lib-provenance.sh"
_fail=0

# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

KEYDIR=keys

# Floors, not exact counts, mirroring tests/upstream-provenance.sh and for the
# same reason: #39 pinned 14 distinct fingerprints across 15 blocks, and a
# sidecar legitimately loses a block when a profile drops a pinned version. Ten
# is far enough below 14 to survive that, and far enough above zero that no
# stray file can satisfy it -- which is what keeps every check below non-vacuous.
_MIN_KEYS=10

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
  { provenance_pinned_fprs "$@" | sed 's/^/PIN /'; _committed_fprs "$_kp_dir" | sed 's/^/KEY /'; } \
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
# same key the pin names, even where a subkey made the signature -- bzip2 is
# the case in this tree. (libressl is signed by a subkey too, but it records no
# pin and commits no key, for the reason recipes/crypto/libressl.hash states.)
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

# _epoch_to_iso SECONDS
# Emit YYYY-MM-DD for a Unix timestamp.
#
# Two spellings because there is no portable one: `-d @N` is GNU, `-r N` is BSD
# and macOS. Trying both is the whole compatibility story -- neither shell nor
# awk offers a civil-date conversion this file could use instead.
_epoch_to_iso() {
  date -u -d "@$1" +%Y-%m-%d 2>/dev/null || date -u -r "$1" +%Y-%m-%d 2>/dev/null
}

# _key_expiry FILE
# Emit the primary key's expiry as YYYY-MM-DD, `-` when it carries none, or
# `unreadable` when gpg cannot parse the file at all.
#
# Field 7 of the pub record is the expiration timestamp and is empty for a key
# that never expires -- a different fact from a key whose expiry lies ahead, and
# INDEX records them differently for that reason. An absent pub record is a
# THIRD fact, and folding it into `-` would have reported an unparseable key as
# one that never expires. _key_state already distinguishes it; this now matches.
_key_expiry() {
  _kp=$(gpg --show-keys --with-colons "$1" 2>/dev/null | awk -F: '$1 == "pub" { print "pub:" $7; exit }')
  case "$_kp" in
    '')     printf '%s\n' 'unreadable' ;;
    'pub:') printf '%s\n' '-' ;;
    *)      _epoch_to_iso "${_kp#pub:}" ;;
  esac
}

# gpg CREATES its homedir on first use and reads the invoker's gpg.conf from it.
# A bare `gpg` call here would therefore have a side effect on a fresh machine
# or CI runner, and would let a local configuration change what the assertions
# below see -- so every call runs against a scratch homedir this file owns.
# Both scratch directories are removed by one trap: the fixture dir is created
# later, and two traps would mean the second silently replaced the first.
# ${x:+"$x"} rather than "$x": an unset scratch dir must contribute NO argument
# at all, and `rm -rf ""` is an error rather than a no-op.
#
# INT and TERM exit rather than sharing the EXIT handler, because a POSIX shell
# RESUMES the script after a non-EXIT trap returns: catching Ctrl-C to clean up
# and then running the remaining assertions is not what an interrupt means. The
# exit re-enters the EXIT trap, so the cleanup still happens exactly once, and
# 128+signal is the status a killed process conventionally reports.
_gpghome=''
_fx=''
trap 'rm -rf ${_gpghome:+"$_gpghome"} ${_fx:+"$_fx"}' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Probes the CAPABILITY, not just the binary. --show-keys arrived in GnuPG
# 2.1.23; against an older gpg the helpers return empty and the assertions fail
# with "contains no key", which reads as a corrupt key file rather than as a
# tool too old to answer. The probe discriminates: a bogus option exits 2.
_gpg_ok=no
_gpg_why='gpg not installed'
if command -v gpg >/dev/null 2>&1; then
  if _gpghome=$(mktemp -d); then
    chmod 700 "$_gpghome"
    GNUPGHOME=$_gpghome
    export GNUPGHOME
    if gpg --show-keys --version >/dev/null 2>&1; then
      _gpg_ok=yes
    else
      _gpg_why='gpg predates --show-keys (needs GnuPG >= 2.1.23)'
    fi
  else
    _gpghome=''
    _gpg_why='could not create a scratch GNUPGHOME'
  fi
fi

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
elif [ "$_gpg_ok" != yes ]; then
  printf 'SKIP [key-file-matches-its-name] %s\n' "$_gpg_why"
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
#   <40 uppercase hex>  <valid|expired|revoked>  <YYYY-MM-DD|->  <uid as exported>
#
# The expiry column is `-` for a key that carries no expiry at all, which is a
# different fact from a key whose expiry has not yet arrived -- that one carries
# a date and reads `valid`.
INDEX=$KEYDIR/INDEX

_index_fprs() {
  awk -v CMT="$HASH_COMMENT_RE" '$0 ~ CMT || NF == 0 { next } { print $1 }' \
    "$INDEX" 2>/dev/null | sort -u
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
elif [ "$_gpg_ok" != yes ]; then
  printf 'SKIP [index-state-matches-material] %s\n' "$_gpg_why"
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

# The expiry DATE is committed evidence too, and evidence with no gate is the
# pattern this branch exists to remove: a hand-added row could carry a mistyped
# date, or a date that was right for a key the file no longer holds, and nothing
# would say so. Checking the state word alone left three of the four columns
# unguarded.
if [ "$_keys_seen" -lt "$_MIN_KEYS" ]; then
  _bad index-expiry-matches-material \
    "only $_keys_seen committed key(s) in $KEYDIR/, want >= $_MIN_KEYS"
elif [ "$_gpg_ok" != yes ]; then
  printf 'SKIP [index-expiry-matches-material] %s\n' "$_gpg_why"
elif [ "$(_epoch_to_iso 0)" != 1970-01-01 ]; then
  # Reported rather than skipped silently: neither date spelling worked, so the
  # column cannot be checked on this host and saying nothing would read as a pass.
  _bad index-expiry-matches-material "no usable date(1): neither -d @N nor -r N converts an epoch"
elif [ ! -f "$INDEX" ]; then
  _bad index-expiry-matches-material "$INDEX is missing"
else
  _xdrift=''
  while read -r _f _state _xp _rest; do
    case "$_f" in ''|'#'*) continue ;; esac
    [ -f "$KEYDIR/$_f.asc" ] || continue   # reported by index-covers-every-key
    _realx=$(_key_expiry "$KEYDIR/$_f.asc")
    [ "$_xp" = "$_realx" ] || _xdrift="$_xdrift$_f: INDEX says $_xp, material says ${_realx:-unreadable}; "
  done < "$INDEX"
  if [ -n "$_xdrift" ]; then
    _bad index-expiry-matches-material "$_xdrift"
  else
    _pass index-expiry-matches-material
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
if [ -n "$_fx" ]; then
  mkdir -p "$_fx/keys"
  # 40 uppercase hex: the shape gpg --fingerprint prints and the one Arch's
  # validpgpkeys requires. Case and length are both load-bearing -- a lowercase
  # or short token is not a pin, and provenance_pinned_fprs must not read it
  # as one.
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
