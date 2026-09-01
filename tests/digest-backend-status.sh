#!/bin/sh
# Pins that a hashing tool which FAILS is distinguishable from a file that
# hashes to nothing, and that no rewrite reports success it did not achieve.
#
# `digest_file` ran its backend as the head of a pipeline, so the status was
# awk's: a backend that died printed nothing and exited 0, and the caller got an
# empty string with a success status (GH-85). The two callers took that in
# opposite directions. Verification rejected the download -- right outcome --
# while telling the operator "Incomplete download, or a man-in-the-middle
# attack", sending them after an attack that never happened. Recording was the
# bad direction: hash_record_write wrote the empty digest into a `.hash`
# sidecar, where hash_lookup then returns nothing and verify_file's
# `[ -n "$_want" ] || continue` skips that algorithm for good -- a sidecar that
# silently verifies nothing.
#
# `file_size` had the same shape (`wc -c < f | tr -d ' '`), and
# hash_record_write's in-place rewrite had it a third time
# (`awk ... > tmp && mv`), where a failed awk left the sidecar untouched and the
# code below still WARNED that it had updated the digest.
#
# Tested through a sandbox PATH holding a broken backend rather than by reading
# the source: what is being asserted is that the status reaches the caller, and
# only running it can show that. The sandbox is the shape tests/ccache.sh
# established -- a bin directory of our own.
#
# _require_fn guards every assertion whose subject is new, because on a tree
# without it the call exits 127 with a "not found" message, and an assertion
# phrased as "this must fail" reads that as a pass. Most of the globs below fail
# safe by polarity anyway, but assertion 5's does not: "nothing was recorded" is
# equally true of a function that does not exist, which is why it also carries a
# floor of its own.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
SCRIPT_DIR="$ROOT"
# shellcheck source=lib/utils.sh
. lib/utils.sh
# shellcheck source=lib/download.sh
. lib/download.sh
# shellcheck source=lib/makesum.sh
. lib/makesum.sh
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"
_cleanup_on_signal

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

# A sandbox PATH: our stub first, then enough of the real system for `awk`,
# `mv`, `rm` and the shell's own helpers to still work. Prepending rather than
# replacing is deliberate -- replacing PATH entirely would test "no tools at
# all", which is a different claim and one command_exists already answers.
mkdir -p "$_tmp/bin"
_stub() { # name  body
  printf '#!/bin/sh\n%s\n' "$2" > "$_tmp/bin/$1"
  chmod +x "$_tmp/bin/$1"
}
_sandbox="$_tmp/bin:$PATH"

# Run something with the stubs in front of the real tools, and hand back
# everything it said. The subshell is what contains both the PATH and a die(),
# which is an `exit`; `|| true` keeps that exit from ending the test run.
_sandboxed() { # command...
  ( PATH="$_sandbox"; export PATH; "$@" ) 2>&1 || true
}

printf 'test' > "$_tmp/payload"
# sha256("test"), the value every real backend must produce for that payload.
_KAT=9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08

# A backend that FAILS is fatal, not an empty digest -- asserted together with
#   the KNOWN ANSWER from the host's real backend, in one verdict, for two
#   reasons. The known answer is the floor: without it these assertions could be
#   measuring the absence of digest_file rather than the presence of its guard,
#   since "not found" is also a non-zero status with output. And a floor
#   reported SEPARATELY would pass on the merge base, where the real backend
#   works fine -- tests/lib-assert.sh names that trap over _verdict, and
#   tests/oracle-baseline.sh caught this file falling into it.
#
#   The stub exits non-zero and prints nothing, which is what a missing shared
#   library or a killed process looks like.
_reasons=""
[ "$(digest_file sha256 "$_tmp/payload")" = "$_KAT" ] ||
  _reasons=" the host's own backend did not produce the known-answer digest for 'test', so the rest measures nothing"
_stub sha256sum 'exit 1'
_out=$(_sandboxed digest_file sha256 "$_tmp/payload")
case "$_out" in
  *"'sha256sum' failed"*) ;;
  *) _reasons="$_reasons a backend exiting 1 was not fatal: got=[$_out]" ;;
esac
_verdict failed-backend-is-fatal "$_reasons"

# A backend that SUCCEEDS but prints something unreadable is fatal too. This
#   is the half a status check alone does not cover, and it is not far-fetched:
#   a wrapper that prints a warning and forgets the digest, or a locale that
#   renders the hex differently, both land here.
_stub sha256sum 'printf "no digest here\n"; exit 0'
_out=$(_sandboxed digest_file sha256 "$_tmp/payload")
_glob unreadable-backend-output-is-fatal "$_out" '*produced no sha256 digest*' 'digest_file with a backend printing no hex'

# The extraction takes the digest wherever the backend puts it -- first field
#   for the coreutils tools and shasum, last for `openssl dgst`, whose label
#   also differs across implementations (`SHA2-256(stdin)=` on OpenSSL 3.x,
#   `SHA256(stdin)=` on LibreSSL). One content-based rule replaced three
#   position-based ones; these are the shapes it has to hold for.
#   ONE verdict over both shapes, again because the halves are not equally new:
#   the merge base's `awk '{print $1}'` reads the coreutils shape correctly too,
#   so a separately-reported leading-field assertion passes there and proves
#   nothing. What is new is that ONE rule reads BOTH.
_reasons=""
_stub sha256sum "printf '%s  -\n' $_KAT"
_got=$(_sandboxed digest_file sha256 "$_tmp/payload")
[ "$_got" = "$_KAT" ] || _reasons=" coreutils-shaped output (digest first) read as [$_got]"
_stub sha256sum "printf 'SHA2-256(stdin)= %s\n' $_KAT"
_got=$(_sandboxed digest_file sha256 "$_tmp/payload")
[ "$_got" = "$_KAT" ] || _reasons="$_reasons openssl-shaped output (digest last) read as [$_got]"
_verdict one-rule-reads-every-backend-shape "$_reasons"

# THE ONE THAT MATTERS: a failed backend must not reach the sidecar. An empty
#   digest recorded there is not a loud failure but a silent hole -- every later
#   verification of that file skips the algorithm entirely.
#   The FLOOR is in the same verdict: a WORKING backend must record a sha256
#   line into a second sidecar. Without it the assertion passes on any
#   hash_record_write that writes nothing for any reason at all -- a `return 0`
#   stub satisfies it perfectly, which is how it was measured to be vacuous.
_reasons=""
if _require_fn hash_record_write failed-backend-records-nothing; then
  : > "$_tmp/floor.hash"
  hash_record_write "$_tmp/floor.hash" payload "$_tmp/payload" >/dev/null 2>&1 || true
  grep -q "^sha256  $_KAT  payload$" "$_tmp/floor.hash" ||
    _reasons=" with a WORKING backend nothing was recorded either, so the negative case proves nothing:[$(cat "$_tmp/floor.hash")]"

  _stub sha256sum 'exit 1'
  : > "$_tmp/sink.hash"
  _sandboxed hash_record_write "$_tmp/sink.hash" payload "$_tmp/payload" >/dev/null
  [ -s "$_tmp/sink.hash" ] &&
    _reasons="$_reasons a record was written despite the backend failing:[$(cat "$_tmp/sink.hash")]"
  _verdict failed-backend-records-nothing "$_reasons"
fi

# file_size answers the same way. Its `wc` is stubbed rather than its input
#   made unreadable, because an unreadable file fails the REDIRECTION, which is
#   a different code path from the one this guard is on.
_stub wc 'exit 1'
_out=$(_sandboxed file_size "$_tmp/payload")
_glob failed-wc-is-fatal "$_out" '*wc failed*' 'file_size with a wc that exits 1'
rm -f "$_tmp/bin/wc"

# A TRUNCATED digest is fatal too. Output cut mid-write is still perfectly hex,
# so the emptiness guard above does not see it -- and what it costs is worse than
# a loud failure: hash_record_write would write the short value into a sidecar as
# canonical, where hash_file_validate then rejects the file mediaforge itself
# wrote.
_stub sha256sum "printf '%s  -\n' 9f86d081"
_out=$(_sandboxed digest_file sha256 "$_tmp/payload")
_glob truncated-digest-is-fatal "$_out" '*produced no sha256 digest*' 'digest_file with a backend printing 8 hex characters'

# The two callers that read a digest THROUGH a comparison, where an empty value
# does not fail -- it compares unequal, and the operator is told the wrong thing.
# Both were guarded in this commit and neither was pinned; both guards survived
# removal against the whole suite until these assertions existed.
#
# verify_file is the one that misdiagnoses: without the guard an empty digest
# reaches the mismatch arm, which says "Incomplete download, or a
# man-in-the-middle attack" about a local tool that is simply broken.
if _require_fn verify_file verify-file-hash-failure-is-fatal; then
  printf 'test' > "$_tmp/pkg.tar.gz"
  cat > "$_tmp/pkg.hash" <<EOF
sha256  $_KAT  pkg.tar.gz
size    4  pkg.tar.gz
EOF
  _stub sha256sum 'exit 1'
  _out=$(PKG_HASH_FILE="$_tmp/pkg.hash" _sandboxed verify_file "$_tmp/pkg.tar.gz" pkg.tar.gz)
  _reasons=""
  case "$_out" in
    *"cannot be hashed"*) ;;
    *) _reasons=" a broken hashing tool did not stop verification: got=[$_out]." ;;
  esac
  case "$_out" in
    *"man-in-the-middle"*) _reasons="$_reasons it blamed a man-in-the-middle for a broken local tool." ;;
  esac
  _verdict verify-file-hash-failure-is-fatal "$_reasons"

  # ...and the size half of the same function, which fails EARLIER and would
  # report "the wrong size" for the same broken host.
  _stub wc 'exit 1'
  _out=$(PKG_HASH_FILE="$_tmp/pkg.hash" _sandboxed verify_file "$_tmp/pkg.tar.gz" pkg.tar.gz)
  rm -f "$_tmp/bin/wc"
  _glob verify-file-size-failure-is-fatal "$_out" '*cannot be sized*' 'verify_file with a wc that exits 1'
fi

# makesum_needs_fetch compares a cached file's digest against the record. An
# empty digest compares unequal, so the cache silently looks unattested and
# ~107 recipes' tarballs are re-downloaded, saying nothing about why.
if _require_fn makesum_needs_fetch cache-attestation-failure-is-fatal; then
  cat > "$_tmp/cache.hash" <<EOF
sha256  $_KAT  payload
size    4  payload
EOF
  _stub sha256sum 'exit 1'
  _out=$(_sandboxed makesum_needs_fetch "$_tmp/cache.hash" payload "$_tmp/payload")
  _glob cache-attestation-failure-is-fatal "$_out" '*cannot hash*' 'makesum_needs_fetch with a backend that exits 1'
fi

# The SIZE guard in hash_record_write, which the digest guard hides: stub `wc`
# and leave the hashing alone, or the digest dies first and this proves nothing.
if _require_fn hash_record_write failed-sizing-records-nothing; then
  : > "$_tmp/nosize-sink.hash"
  _stub wc 'exit 1'
  _sandboxed hash_record_write "$_tmp/nosize-sink.hash" payload "$_tmp/payload" >/dev/null
  rm -f "$_tmp/bin/wc"
  _reasons=""
  [ -s "$_tmp/nosize-sink.hash" ] &&
    _reasons=" a record was written though the file could not be sized:[$(cat "$_tmp/nosize-sink.hash")]"
  _verdict failed-sizing-records-nothing "$_reasons"
fi

# The rewrite mechanism exists once, and both callers are on it. Written as a
#   grep because the two call sites are in different files and the copy that
#   drifted was the one nobody re-read: lib/framework.sh guarded its awk-then-mv
#   while lib/makesum.sh's identical shape did not.
# mf_awk_rewrite's OWN body is where the redirection legitimately lives, so it
# is cut before the grep -- otherwise the assertion reports the helper as the
# duplicate it exists to remove.
# Keyed on the SUBSTANCE -- a redirection into a `.tmp` sibling -- rather than on
# one variable spelling: `> "${_x}.tmp"` and `>>` are the same mechanism, and the
# first draft's `> "$_x.tmp"` pattern would have walked past both. This is the
# argument tests/pc-rewrite-single-entry.sh already makes about its own grep.
_own=$(_lib_code | sed '/^mf_awk_rewrite() {/,/^}/d' | grep -nE '>>? *"\$\{?[A-Za-z_]+\}?\.tmp"' || true)
_verdict no-unguarded-awk-rewrite-remains "$(printf '%s' "$_own" | head -3)"
_defs=$(_lib_code | grep -c 'mf_awk_rewrite() {' || true)
if [ "$_defs" = 1 ]; then
  _pass rewrite-defined-once
else
  _bad rewrite-defined-once "found $_defs definitions of mf_awk_rewrite in lib/"
fi

# A rewrite that fails is fatal AND leaves the original intact -- the two
#   halves that the `&&` form got wrong in opposite directions (it kept the
#   original, but reported success). The awk stub exits non-zero after printing
#   a partial line, which is what a program dying mid-stream looks like.
printf 'original\n' > "$_tmp/rewrite-me"
_stub awk 'printf "half a li"; exit 2'
#   One verdict over all three halves. The `&&`-form on the merge base already
#   left the original intact -- that half was never the defect -- so reporting
#   it on its own would pass there while the half that matters (it now DIES
#   instead of reporting success) is the only thing that changed.
_out=$(_sandboxed mf_awk_rewrite "$_tmp/rewrite-me" '{print}')
_reasons=""
case "$_out" in
  *"failed to rewrite"*) ;;
  *) _reasons=" an awk exiting 2 was not fatal: got=[$_out]" ;;
esac
[ "$(cat "$_tmp/rewrite-me")" = original ] || _reasons="$_reasons the original was replaced by the failed rewrite."
[ -e "$_tmp/rewrite-me.tmp" ] && _reasons="$_reasons a .tmp sibling was left behind."
_verdict failed-rewrite-dies-and-keeps-the-original "$_reasons"
rm -f "$_tmp/bin/awk"

# The `-v` pass-through, which is the part of mf_awk_rewrite's shape a reader
# cannot infer from a call site: hash_record_write writes its three bindings
# AFTER a multi-line program, and the helper splices them BEFORE it. Reordering
# them inside the helper leaves both of the files that exist to pin this
# mechanism green -- it surfaces only as an aborted run in a third file, with a
# diagnosis nowhere near the helper.
#
# The message prefix is asserted here too, under a set PKG_NAME: it is the whole
# difference between the extracted helper's failure line and the eight-copy one
# it replaced, and nothing else in the suite reads it.
if _require_fn mf_awk_rewrite rewrite-passes-awk-bindings-through; then
  printf 'keep\n' > "$_tmp/bindings"
  # $0 is awk's whole-record variable, so the single quotes are the point and
  # expanding it would be the bug -- the same false positive lib/makesum.sh and
  # lib/framework.sh's mf_pc_add_stdcxx already carry, and for the same reason:
  # the linter cannot tell an awk program from shell once it is an argument to a
  # shell function.
  # shellcheck disable=SC2016
  mf_awk_rewrite "$_tmp/bindings" '{ print $0 " " tag }' -v tag=BOUND
  _glob rewrite-passes-awk-bindings-through "$(cat "$_tmp/bindings")" '*keep BOUND*' 'mf_awk_rewrite with -v tag=BOUND'

  printf 'original\n' > "$_tmp/named"
  _stub awk 'exit 2'
  _out=$(PKG_NAME=probe _sandboxed mf_awk_rewrite "$_tmp/named" '{print}')
  rm -f "$_tmp/bin/awk"
  _glob rewrite-failure-names-the-package "$_out" '*probe: failed to rewrite*' 'mf_awk_rewrite under PKG_NAME=probe'
fi

printf 'DONE: digest-backend-status\n'
exit "$_fail"
