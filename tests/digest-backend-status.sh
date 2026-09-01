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
# established -- a bin directory of our own, and `command -v` before the call so
# a tree without the function exits 127 instead of passing every "nothing
# happened" assertion by default.
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
_stub() { # name  body
  printf '#!/bin/sh\n%s\n' "$2" > "$_tmp/bin/$1"
  chmod +x "$_tmp/bin/$1"
}
mkdir -p "$_tmp/bin"
_sandbox="$_tmp/bin:$PATH"

: > "$_tmp/payload"
printf 'test' > "$_tmp/payload"
# sha256("test"), the value every real backend must produce for that payload.
_KAT=9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08

# 1. A backend that FAILS is fatal, not an empty digest -- asserted together with
#    the KNOWN ANSWER from the host's real backend, in one verdict, for two
#    reasons. The known answer is the floor: without it these assertions could be
#    measuring the absence of digest_file rather than the presence of its guard,
#    since "not found" is also a non-zero status with output. And a floor
#    reported SEPARATELY would pass on the merge base, where the real backend
#    works fine -- tests/lib-assert.sh names that trap over _verdict, and
#    tests/oracle-baseline.sh caught this file falling into it.
#
#    The stub exits non-zero and prints nothing, which is what a missing shared
#    library or a killed process looks like.
_reasons=""
[ "$(digest_file sha256 "$_tmp/payload")" = "$_KAT" ] ||
  _reasons=" the host's own backend did not produce the known-answer digest for 'test', so the rest measures nothing"
_stub sha256sum 'exit 1'
_out=$( (PATH="$_sandbox"; export PATH; digest_file sha256 "$_tmp/payload") 2>&1 || true)
case "$_out" in
  *"sha256sum failed"*) ;;
  *) _reasons="$_reasons a backend exiting 1 was not fatal: got=[$_out]" ;;
esac
_verdict failed-backend-is-fatal "$_reasons"

# 3. A backend that SUCCEEDS but prints something unreadable is fatal too. This
#    is the half a status check alone does not cover, and it is not far-fetched:
#    a wrapper that prints a warning and forgets the digest, or a locale that
#    renders the hex differently, both land here.
_stub sha256sum 'printf "no digest here\n"; exit 0'
_out=$( (PATH="$_sandbox"; export PATH; digest_file sha256 "$_tmp/payload") 2>&1 || true)
_glob unreadable-backend-output-is-fatal "$_out" '*produced no digest*' 'digest_file with a backend printing no hex'

# 4. The extraction takes the digest wherever the backend puts it -- first field
#    for the coreutils tools and shasum, last for `openssl dgst`, whose label
#    also differs across implementations (`SHA2-256(stdin)=` on OpenSSL 3.x,
#    `SHA256(stdin)=` on LibreSSL). One content-based rule replaced three
#    position-based ones; these are the shapes it has to hold for.
#    ONE verdict over both shapes, again because the halves are not equally new:
#    the merge base's `awk '{print $1}'` reads the coreutils shape correctly too,
#    so a separately-reported leading-field assertion passes there and proves
#    nothing. What is new is that ONE rule reads BOTH.
_reasons=""
_stub sha256sum "printf '%s  -\n' $_KAT"
_got=$( (PATH="$_sandbox"; export PATH; digest_file sha256 "$_tmp/payload") 2>&1 || true)
[ "$_got" = "$_KAT" ] || _reasons=" coreutils-shaped output (digest first) read as [$_got]"
_stub sha256sum "printf 'SHA2-256(stdin)= %s\n' $_KAT"
_got=$( (PATH="$_sandbox"; export PATH; digest_file sha256 "$_tmp/payload") 2>&1 || true)
[ "$_got" = "$_KAT" ] || _reasons="$_reasons openssl-shaped output (digest last) read as [$_got]"
_verdict one-rule-reads-every-backend-shape "$_reasons"

# 5. THE ONE THAT MATTERS: a failed backend must not reach the sidecar. An empty
#    digest recorded there is not a loud failure but a silent hole -- every later
#    verification of that file skips the algorithm entirely.
_stub sha256sum 'exit 1'
: > "$_tmp/sink.hash"
( PATH="$_sandbox"; export PATH
  hash_record_write "$_tmp/sink.hash" payload "$_tmp/payload" ) >/dev/null 2>&1 || true
_reasons=""
[ -s "$_tmp/sink.hash" ] && _reasons=" a record was written despite the backend failing:$(cat "$_tmp/sink.hash")"
_verdict failed-backend-records-nothing "$_reasons"

# 6. file_size answers the same way. Its `wc` is stubbed rather than its input
#    made unreadable, because an unreadable file fails the REDIRECTION, which is
#    a different code path from the one this guard is on.
_stub wc 'exit 1'
_out=$( (PATH="$_sandbox"; export PATH; file_size "$_tmp/payload") 2>&1 || true)
_glob failed-wc-is-fatal "$_out" '*wc failed*' 'file_size with a wc that exits 1'
rm -f "$_tmp/bin/wc"

# 7. The rewrite mechanism exists once, and both callers are on it. Written as a
#    grep because the two call sites are in different files and the copy that
#    drifted was the one nobody re-read: lib/framework.sh guarded its awk-then-mv
#    while lib/makesum.sh's identical shape did not.
# mf_awk_rewrite's OWN body is where the redirection legitimately lives, so it
# is cut before the grep -- otherwise the assertion reports the helper as the
# duplicate it exists to remove.
_own=$(_lib_code | sed '/^mf_awk_rewrite() {/,/^}/d' | grep -n '> *"\$[A-Za-z_]*\.tmp"' || true)
_verdict no-unguarded-awk-rewrite-remains "$(printf '%s' "$_own" | head -3)"
_defs=$(_lib_code | grep -c 'mf_awk_rewrite() {' || true)
if [ "$_defs" = 1 ]; then
  _pass rewrite-defined-once
else
  _bad rewrite-defined-once "found $_defs definitions of mf_awk_rewrite in lib/"
fi

# 8. A rewrite that fails is fatal AND leaves the original intact -- the two
#    halves that the `&&` form got wrong in opposite directions (it kept the
#    original, but reported success). The awk stub exits non-zero after printing
#    a partial line, which is what a program dying mid-stream looks like.
printf 'original\n' > "$_tmp/rewrite-me"
_stub awk 'printf "half a li"; exit 2'
#    One verdict over all three halves. The `&&`-form on the merge base already
#    left the original intact -- that half was never the defect -- so reporting
#    it on its own would pass there while the half that matters (it now DIES
#    instead of reporting success) is the only thing that changed.
_out=$( (PATH="$_sandbox"; export PATH; mf_awk_rewrite "$_tmp/rewrite-me" '{print}') 2>&1 || true)
_reasons=""
case "$_out" in
  *"failed to rewrite"*) ;;
  *) _reasons=" an awk exiting 2 was not fatal: got=[$_out]" ;;
esac
[ "$(cat "$_tmp/rewrite-me")" = original ] || _reasons="$_reasons the original was replaced by the failed rewrite."
[ -e "$_tmp/rewrite-me.tmp" ] && _reasons="$_reasons a .tmp sibling was left behind."
_verdict failed-rewrite-dies-and-keeps-the-original "$_reasons"
rm -f "$_tmp/bin/awk"

printf 'DONE: digest-backend-status\n'
exit "$_fail"
