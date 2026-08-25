#!/bin/sh
# Checksum verification tests for lib/download.sh (issue #19).
#
# THE BUG THIS PINS. fetch() verified nothing. Its cache-reuse branch reuses
# any file that already exists in DISTDIR forever, so a tarball corrupted,
# truncated, or swapped after landing is never re-examined, and its `curl -fL`
# download accepts whatever bytes a redirect chain returns. 18 recipes fetch
# through mirror redirectors that hand off to third-party hosts.
#
# Hermetic: fixtures are built here, no network.
#
# Usage: tests/checksum-verification.sh
# Exit 0 = pass, 1 = regression.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT" || exit 1
_fail=0

_pass() { printf 'PASS [%s]\n' "$1"; }
_bad()  { printf 'FAIL [%s] %s\n' "$1" "${2-}" >&2; _fail=1; }

# Guard for negative assertions. On a tree without the feature an undefined
# function exits 127, which a bare "expected it to fail" check reads as success
# and reports PASS -- exactly what tests/oracle-baseline.sh rejects.
_require_fn() {
  if command -v "$1" >/dev/null 2>&1; then
    return 0
  fi
  _bad "$2" "$1 is not defined"
  return 1
}

. "$ROOT/lib/utils.sh"
. "$ROOT/lib/download.sh"
. "$ROOT/lib/resolve.sh"

_fx=$(mktemp -d)
SRV_PID=''
trap 'kill "$SRV_PID" 2>/dev/null; rm -rf "$_fx"' EXIT INT TERM

# Known-answer vector: sha256("test") is a published constant.
printf 'test' > "$_fx/kat.txt"
_KAT=9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08

_got=$(digest_file sha256 "$_fx/kat.txt")
if [ "$_got" = "$_KAT" ]; then _pass digest-sha256; else _bad digest-sha256 "got $_got"; fi

_got=$(file_size "$_fx/kat.txt")
if [ "$_got" = 4 ]; then _pass file-size; else _bad file-size "got $_got"; fi

# digest_file picks whichever backend is present, so its answer must agree with
# every raw backend on this host -- otherwise the result would be host-dependent.
if _require_fn digest_file digest-backends-agree; then
  _helper=$(digest_file sha256 "$_fx/kat.txt")
  _agree=true
  if command_exists sha256sum; then
    _raw=$(sha256sum < "$_fx/kat.txt" | awk '{print $1}')
    [ "$_raw" = "$_helper" ] || _agree=false
  fi
  if command_exists openssl; then
    _raw=$(openssl dgst -sha256 < "$_fx/kat.txt" | awk '{print $NF}')
    [ "$_raw" = "$_helper" ] || _agree=false
  fi
  if [ "$_agree" = true ] && [ "$_helper" = "$_KAT" ]; then
    _pass digest-backends-agree
  else
    _bad digest-backends-agree "helper=$_helper"
  fi
fi

# An unsupported algorithm must die rather than silently produce nothing.
if _require_fn digest_file digest-rejects-md5; then
  if ( digest_file md5 "$_fx/kat.txt" ) >/dev/null 2>&1; then
    _bad digest-rejects-md5 "md5 was accepted"
  else
    _pass digest-rejects-md5
  fi
fi

# -- Hash-file parser ---------------------------------------------------------
cat > "$_fx/good.hash" <<'EOF'
# From https://example.invalid/openssl-3.5.4.tar.gz.sha256
sha256  9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08  openssl-3.5.4.tar.gz
size    4  openssl-3.5.4.tar.gz

# Locally calculated 2026-08-25
sha256  aaaa  other.tar.gz
size    7  other.tar.gz
EOF

_got=$(hash_lookup "$_fx/good.hash" openssl-3.5.4.tar.gz sha256)
if [ "$_got" = "$_KAT" ]; then _pass lookup-sha256; else _bad lookup-sha256 "got '$_got'"; fi

_got=$(hash_lookup "$_fx/good.hash" openssl-3.5.4.tar.gz size)
if [ "$_got" = 4 ]; then _pass lookup-size; else _bad lookup-size "got '$_got'"; fi

# On the baseline tree hash_lookup is undefined, so $_got is empty and this
# assertion would pass on a tree that has no such function -- exactly what
# tests/oracle-baseline.sh rejects. Guarded per the Task 2 brief correction.
if _require_fn hash_lookup lookup-absent-empty; then
  _got=$(hash_lookup "$_fx/good.hash" absent.tar.gz sha256)
  if [ -z "$_got" ]; then _pass lookup-absent-empty; else _bad lookup-absent-empty "got '$_got'"; fi
fi

if ( hash_file_validate "$_fx/good.hash" ) >/dev/null 2>&1; then
  _pass validate-accepts-good
else
  _bad validate-accepts-good "well-formed file was rejected"
fi

# Each malformed shape must be rejected. A parser that silently skips a line it
# cannot read would silently skip a digest.
#
# On the baseline tree hash_file_validate is undefined, the subshell exits 127,
# and every case below would read as "rejected" -- a passing assertion on a
# tree with no such function, which tests/oracle-baseline.sh rejects. Guarded
# per the Task 2 brief correction.
if _require_fn hash_file_validate validate-rejects-guard; then
  for _case in wrong-fields unknown-keyword non-hex non-numeric-size duplicate md5-keyword; do
    case "$_case" in
      wrong-fields)      printf 'sha256 abc\n' > "$_fx/bad.hash" ;;
      unknown-keyword)   printf 'sha999  abc  f.tar.gz\n' > "$_fx/bad.hash" ;;
      non-hex)           printf 'sha256  zzzz  f.tar.gz\n' > "$_fx/bad.hash" ;;
      non-numeric-size)  printf 'size  many  f.tar.gz\n' > "$_fx/bad.hash" ;;
      duplicate)         printf 'sha256  aa  f.tar.gz\nsha256  bb  f.tar.gz\n' > "$_fx/bad.hash" ;;
      md5-keyword)       printf 'md5  aa  f.tar.gz\n' > "$_fx/bad.hash" ;;
    esac
    if ( hash_file_validate "$_fx/bad.hash" ) >/dev/null 2>&1; then
      _bad "validate-rejects-$_case" "malformed file was accepted"
    else
      _pass "validate-rejects-$_case"
    fi
  done
fi

# A bad-value record must not still increment the duplicate counter for its
# (keyword, filename) pair, or a later legitimate record for that pair is
# reported as a duplicate that does not exist alongside the real format error.
printf 'sha256  zzzz  f.tar.gz\nsha256  aabb  f.tar.gz\n' > "$_fx/bad-then-good.hash"
_msg=$( ( hash_file_validate "$_fx/bad-then-good.hash" ) 2>&1 )
case "$_msg" in
  *hex*)
    case "$_msg" in
      *duplicate*) _bad validate-bad-value-not-duplicate "spurious duplicate: $_msg" ;;
      *)           _pass validate-bad-value-not-duplicate ;;
    esac
    ;;
  *) _bad validate-bad-value-not-duplicate "missing hex/format error: $_msg" ;;
esac

# -- PKG_HASH_FILE plumbing (Task 4, #19) -------------------------------------
# shellcheck disable=SC1091
. "$ROOT/lib/framework.sh"

# reset_recipe() runs between every recipe; a stale value from the previous
# recipe must not leak into the next one's fetch/makesum lookups.
PKG_HASH_FILE="/sentinel/should-be-cleared.hash"
reset_recipe
if [ -z "$PKG_HASH_FILE" ]; then
  _pass reset-clears-hash-file
else
  _bad reset-clears-hash-file "got '$PKG_HASH_FILE'"
fi

# run_recipe() must derive PKG_HASH_FILE from the recipe path it was actually
# given -- exercised through run_recipe itself (not a re-implementation of the
# %.sh strip) so the assertion fails if the framework never assigns it, not
# just if the formula is wrong. DRY_RUN short-circuits after the derivation
# but before fetch/build, so this needs no network and no host build tools.
_hf_dir="$_fx/hf-fixture"
mkdir -p "$_hf_dir/recipes/audio" "$_hf_dir/prefix/.stamps"
cat > "$_hf_dir/recipes/audio/lv2.sh" <<'EOF'
PKG_NAME="lv2fixture"
PKG_VERSION="1.0"
PKG_URL="https://example.invalid/lv2fixture-1.0.tar.gz"
EOF
PREFIX="$_hf_dir/prefix"
DISABLE_PKGS=""
ENABLE_PKGS=""
DRY_RUN=true
PKG_HASH_FILE=""
run_recipe "$_hf_dir/recipes/audio/lv2.sh" >/dev/null
_expected="$_hf_dir/recipes/audio/lv2.hash"
if [ "$PKG_HASH_FILE" = "$_expected" ]; then
  _pass run-recipe-derives-hash-file
else
  _bad run-recipe-derives-hash-file "got '$PKG_HASH_FILE', want '$_expected'"
fi
unset DRY_RUN

# PKG_HASH_FILE is framework-derived and must never be assigned inside a
# recipe -- a recipe that set it would silently point fetch/makesum at the
# wrong sidecar. recipes/ffmpeg.sh is the sanctioned exception: it is sourced
# directly by mediaforge.sh rather than through run_recipe(), so it derives
# its own PKG_HASH_FILE. Framed as one comparison (framework derives it AND
# no ordinary recipe does) so the assertion fails on a tree where the
# framework doesn't derive it yet, rather than passing vacuously there.
_hf_recipe_offenders=$(grep -rl 'PKG_HASH_FILE=' "$ROOT/recipes" --include='*.sh' 2>/dev/null \
  | grep -v '^'"$ROOT"'/recipes/ffmpeg\.sh$' || true)
if grep -q 'PKG_HASH_FILE=' "$ROOT/lib/framework.sh" 2>/dev/null && [ -z "$_hf_recipe_offenders" ]; then
  _pass hash-file-not-recipe-set
else
  _bad hash-file-not-recipe-set "framework derives it: $(grep -q 'PKG_HASH_FILE=' "$ROOT/lib/framework.sh" && echo yes || echo no); offenders: ${_hf_recipe_offenders:-none}"
fi

# -- makesum merge semantics --------------------------------------------------
# `.` is a POSIX special builtin: its failure exits a non-interactive shell
# outright, so on a tree without lib/makesum.sh this must be skipped rather
# than attempted, or the script dies here without reaching DONE.
[ -f "$ROOT/lib/makesum.sh" ] && . "$ROOT/lib/makesum.sh"

# Merging must preserve records this run did not touch. One hash file holds all
# four profiles' versions, so a run without --profile= that truncated would
# silently drop the other three.
printf 'test'  > "$_fx/new.tar.gz"    # sha256 == $_KAT, size 4
printf 'other' > "$_fx/old.tar.gz"    # a different digest, size 5
_OTHER=$(digest_file sha256 "$_fx/old.tar.gz")

MAKESUM_PROVENANCE="Locally calculated 2026-08-25"
MAKESUM_UPDATE=false

cat > "$_fx/merge.hash" <<'EOF'
# From https://example.invalid/old.sha256
sha256  1111  old.tar.gz
size    11  old.tar.gz
EOF

if _require_fn hash_record_write makesum-merge-preserves; then
  hash_record_write "$_fx/merge.hash" new.tar.gz "$_fx/new.tar.gz"

  if [ "$(hash_lookup "$_fx/merge.hash" old.tar.gz sha256)" = 1111 ]; then
    _pass makesum-merge-preserves
  else
    _bad makesum-merge-preserves "pre-existing record was lost"
  fi
  if [ "$(hash_lookup "$_fx/merge.hash" new.tar.gz sha256)" = "$_KAT" ]; then
    _pass makesum-merge-adds
  else
    _bad makesum-merge-adds "new record was not written"
  fi
  if grep -q 'example.invalid/old.sha256' "$_fx/merge.hash"; then
    _pass makesum-preserves-provenance
  else
    _bad makesum-preserves-provenance "existing provenance comment was dropped"
  fi

  # A mismatching existing record is left alone unless MAKESUM_UPDATE=true.
  # Silently refreshing a digest is how a tampered download becomes a
  # committed pin.
  MAKESUM_UPDATE=false
  hash_record_write "$_fx/merge.hash" old.tar.gz "$_fx/old.tar.gz"
  if [ "$(hash_lookup "$_fx/merge.hash" old.tar.gz sha256)" = 1111 ]; then
    _pass makesum-no-clobber
  else
    _bad makesum-no-clobber "existing digest was overwritten without --update"
  fi

  MAKESUM_UPDATE=true
  hash_record_write "$_fx/merge.hash" old.tar.gz "$_fx/old.tar.gz"
  if [ "$(hash_lookup "$_fx/merge.hash" old.tar.gz sha256)" = "$_OTHER" ]; then
    _pass makesum-update-rewrites
  else
    _bad makesum-update-rewrites "--update did not rewrite"
  fi
  MAKESUM_UPDATE=false
fi

# A filename with whitespace cannot round-trip through the 3-field grammar.
# Guarded: on a tree without hash_record_write, the subshell exits 127, which
# a bare "expected it to fail" check reads as PASS -- the undefined-function
# footgun tests/oracle-baseline.sh rejects.
if _require_fn hash_record_write makesum-rejects-space; then
  if ( hash_record_write "$_fx/merge.hash" "two words.tar.gz" "$_fx/new.tar.gz" ) >/dev/null 2>&1; then
    _bad makesum-rejects-space "whitespace filename was accepted"
  else
    _pass makesum-rejects-space
  fi
fi

# -- makesum cache-reuse decision ---------------------------------------------
# Task 7 runs makesum five times (defaults + four profiles) over ~107 recipes;
# most of those re-invocations should be cache hits, not re-downloads. But the
# skip must be earned: makesum's output becomes the pin, so only a cache entry
# that already matches an attested digest is safe to trust.
if _require_fn makesum_needs_fetch makesum-cache-hit-skips; then
  printf 'test' > "$_fx/cache-match.tar.gz"   # sha256 == $_KAT
  cat > "$_fx/cache.hash" <<EOF
sha256  $_KAT  cache-match.tar.gz
size    4  cache-match.tar.gz
EOF

  if makesum_needs_fetch "$_fx/cache.hash" cache-match.tar.gz "$_fx/cache-match.tar.gz"; then
    _bad makesum-cache-hit-skips "a cache entry matching its recorded digest still asked to be re-fetched"
  else
    _pass makesum-cache-hit-skips
  fi

  # No recorded digest yet for this filename -- must fetch, regardless of
  # what bytes happen to already be on disk.
  if makesum_needs_fetch "$_fx/cache.hash" unrecorded.tar.gz "$_fx/cache-match.tar.gz"; then
    _pass makesum-cache-miss-no-record
  else
    _bad makesum-cache-miss-no-record "a file with no recorded digest was treated as cached"
  fi

  # The cached bytes were corrupted/replaced after being recorded -- must
  # re-fetch rather than trust stale bytes that no longer match their pin.
  printf 'corrupted' > "$_fx/cache-match.tar.gz"
  if makesum_needs_fetch "$_fx/cache.hash" cache-match.tar.gz "$_fx/cache-match.tar.gz"; then
    _pass makesum-cache-miss-mismatch
  else
    _bad makesum-cache-miss-mismatch "a cache entry that no longer matches its recorded digest was skipped"
  fi
fi

# -- makesum update-path never leaves an orphaned sha256-without-size --------
# A hand-edited or externally-authored sidecar can carry a sha256 record with
# no matching size record. size is mandatory (hash_file_validate), so
# --update rewriting the digest must not leave that shape still broken.
if _require_fn hash_record_write makesum-update-adds-missing-size; then
  printf 'test' > "$_fx/nosize-src.tar.gz"   # sha256 == $_KAT, size 4
  cat > "$_fx/nosize.hash" <<'EOF'
sha256  1111  nosize.tar.gz
EOF
  MAKESUM_UPDATE=true
  hash_record_write "$_fx/nosize.hash" nosize.tar.gz "$_fx/nosize-src.tar.gz"
  MAKESUM_UPDATE=false
  if [ "$(hash_lookup "$_fx/nosize.hash" nosize.tar.gz size)" = 4 ]; then
    _pass makesum-update-adds-missing-size
  else
    _bad makesum-update-adds-missing-size "size record still missing/wrong after --update rewrote the digest"
  fi
fi

# -- fetch() records under MAKESUM_MODE=true (Task 6, #19) -------------------
# `makesum --build` (mediaforge.sh) is the only way to reach the ten fetch()
# calls nested inside pkg_install() -- lv2's seven sub-tarballs plus
# ffmpeg.sh/opencl.sh/libcdio.sh -- so the property to pin here is not "fetch
# records a file" but "a fetch called from inside a pkg_install()-like
# context records into the ENCLOSING recipe's PKG_HASH_FILE", since that is
# exactly what those ten calls depend on. No `hash_record_write`/`fetch`
# _require_fn guard is needed below: fetch() already exists on the baseline
# tree (Task 5 and earlier), so an unguarded comparison against $_KAT already
# fails naturally there -- no record is written pre-patch, hash_lookup
# returns empty, and "" != $_KAT reports FAIL, exactly as it must.
_mk_dist="$_fx/makesum-distdir"
mkdir -p "$_mk_dist"

# Positive: fetch() with MAKESUM_MODE=true records a cached file's digest
# into PKG_HASH_FILE. Pre-seeding DISTDIR takes fetch()'s "already cached"
# branch, so no network call is exercised; the *.patch filename makes
# fetch() return before extraction, matching the recording hook's placement
# (after the file is on disk, before extraction).
DISTDIR="$_mk_dist"
PKG_HASH_FILE="$_fx/fetch-record.hash"
printf 'test' > "$_mk_dist/fetch-fixture.patch"
MAKESUM_MODE=true
( fetch "https://example.invalid/fetch-fixture.patch" "fetch-fixture.patch" ) >/dev/null 2>&1
if [ "$(hash_lookup "$_fx/fetch-record.hash" fetch-fixture.patch sha256)" = "$_KAT" ]; then
  _pass fetch-records-when-makesum-mode
else
  _bad fetch-records-when-makesum-mode "no matching sha256 record written"
fi

# Negative: an ordinary build's fetch() calls run with MAKESUM_MODE unset,
# and must behave exactly as before -- no record written. Also exercises the
# `${MAKESUM_MODE:-false}` default under this file's `set -u`: a bare
# `[ "$MAKESUM_MODE" = true ]` would abort the whole script here instead of
# reporting one failure.
#
# "No record was written" is trivially true on ANY tree lacking the recording
# feature at all, baseline included -- so on its own this assertion would pass
# there for the wrong reason (tests/oracle-baseline.sh rejects exactly that).
# ANDed with a grep for the MAKESUM_MODE literal in lib/download.sh, the same
# shape as the hash-file-not-recipe-set check above: the grep fails on the
# baseline (the literal isn't there yet), so the whole assertion fails there,
# and only a tree that both HAS the feature and does not fire it when unset
# passes.
DISTDIR="$_mk_dist"
PKG_HASH_FILE="$_fx/fetch-no-record.hash"
printf 'test' > "$_mk_dist/fetch-fixture-2.patch"
unset MAKESUM_MODE
( fetch "https://example.invalid/fetch-fixture-2.patch" "fetch-fixture-2.patch" ) >/dev/null 2>&1
if grep -q 'MAKESUM_MODE' "$ROOT/lib/download.sh" \
   && { [ ! -f "$_fx/fetch-no-record.hash" ] || [ -z "$(hash_lookup "$_fx/fetch-no-record.hash" fetch-fixture-2.patch sha256)" ]; }; then
  _pass fetch-no-record-without-makesum-mode
else
  _bad fetch-no-record-without-makesum-mode "record was written though MAKESUM_MODE was unset, or lib/download.sh doesn't reference MAKESUM_MODE at all"
fi

# Nested: a function that itself calls fetch() -- mirroring how
# recipes/audio/lv2.sh, recipes/hwaccel/opencl.sh and
# recipes/other/libcdio.sh call fetch() from inside their pkg_install()/
# pkg_post_install() -- must still record into the PKG_HASH_FILE the
# ENCLOSING recipe set, since PKG_HASH_FILE reaches fetch() as ordinary
# shell state (lib/framework.sh's load_recipe), not as one of fetch()'s own
# arguments.
#
# The expected digest is a known-answer constant (sha256("nested")), not
# computed via digest_file: on the pre-Task-2 baseline digest_file is
# undefined, so a computed expectation and the equally-undefined hash_lookup
# both silently return empty, and empty equals empty -- a false PASS on a
# tree with none of this feature, same trap $_KAT above already avoids.
_fetch_nested_fixture() {
  fetch "https://example.invalid/nested-fixture.patch" "nested-fixture.patch"
}
DISTDIR="$_mk_dist"
PKG_HASH_FILE="$_fx/enclosing-recipe.hash"
printf 'nested' > "$_mk_dist/nested-fixture.patch"
_NESTED_KAT=233562de1a0288b139c4fa40b7d189f806e906eeb048517aeb67f34ac0e2faf1
MAKESUM_MODE=true
( _fetch_nested_fixture ) >/dev/null 2>&1
if [ "$(hash_lookup "$_fx/enclosing-recipe.hash" nested-fixture.patch sha256)" = "$_NESTED_KAT" ]; then
  _pass fetch-nested-records-into-enclosing-hash-file
else
  _bad fetch-nested-records-into-enclosing-hash-file "record missing/mismatched in enclosing PKG_HASH_FILE"
fi
unset MAKESUM_MODE

# -- makesum --build forwards two-token flags verbatim (review fix, #19) -----
# `-*)` used to catch only a flag's own token; its separate-token VALUE (the
# "4" in `-j 4`, the "openssl" in `--tls openssl`) does not start with "-",
# so it fell through to the `*)` arm and landed in _mk_pkgs -- which then
# made --build die with "does not support filtering to specific packages",
# silently dropping the value. Fixed by forwarding every non-makesum token to
# cmd_build verbatim, whether or not it starts with "-", rather than teaching
# cmd_makesum which of cmd_build's flags take a value (that would duplicate
# cmd_build's own grammar and drift the next time a flag is added).
#
# Verified against the argument vector cmd_build actually receives, not an
# error string, per the fix's own ruling. cmd_build is shadowed with a stub
# that records argc and each argument to a fixture file rather than running
# a build -- the real cmd_build runs the full recipe loop even under
# --dry-run, so invoking it here would make this test dependent on the
# workspace (stamp_check reads $PREFIX/.stamps) and slow.
#
# mediaforge.sh cannot be `.`-sourced directly: its own tail runs a
# subcommand dispatch (case "$_cmd" in ... esac; exit 0) against THIS
# script's argv, which would terminate the whole test file. Extracting
# everything above the "Subcommand Dispatch" marker sources just the
# function definitions. SCRIPT_DIR is set before sourcing (with its own
# reassignment line filtered out) because the extracted preamble's `.
# "$SCRIPT_DIR/lib/..."` lines run immediately and need the repo root, not
# this test file's own directory.
_mf_defs="$_fx/mediaforge-defs.sh"
awk '/^# ─── Subcommand Dispatch ───/{exit} !/^SCRIPT_DIR=/{print}' "$ROOT/mediaforge.sh" > "$_mf_defs"
# Read by the `. "$SCRIPT_DIR/lib/..."` lines inside $_mf_defs, sourced from
# a dynamic path shellcheck does not follow.
# shellcheck disable=SC2034
SCRIPT_DIR="$ROOT"
NUMJOBS="${NUMJOBS:-1}"
. "$_mf_defs"

_mkbuild_capture="$_fx/mkbuild-capture.txt"
# Invoked from cmd_makesum(), defined in the dynamically-sourced $_mf_defs
# above; shellcheck's static call graph does not reach into it.
# shellcheck disable=SC2329
cmd_build() {
  {
    printf 'argc=%s\n' "$#"
    for _cb_a in "$@"; do
      printf 'arg=%s\n' "$_cb_a"
    done
  } > "$_mkbuild_capture"
}

# Calling cmd_makesum() inside a subshell means a `die` (which calls `exit`)
# only ends the subshell, not this whole test file -- load-bearing on the
# baseline, where cmd_makesum doesn't exist yet at all and the call would
# otherwise be "command not found" rather than a clean, contained failure.
_assert_build_forward() {
  _desc="$1"; shift
  _want="$1"; shift
  rm -f "$_mkbuild_capture"
  ( cmd_makesum "$@" ) >/dev/null 2>&1
  _got=$(cat "$_mkbuild_capture" 2>/dev/null || printf '')
  if [ "$_got" = "$_want" ]; then
    _pass "$_desc"
  else
    _bad "$_desc" "want: [$_want] got: [$_got]"
  fi
}

_assert_build_forward makesum-build-forwards-short-flag-value \
  "$(printf 'argc=2\narg=-j\narg=4')" \
  --build -j 4

_assert_build_forward makesum-build-forwards-long-flag-value \
  "$(printf 'argc=2\narg=--tls\narg=openssl')" \
  --build --tls openssl

# Positive: the already-working single-token "=" form must still forward
# unchanged after the fix.
_assert_build_forward makesum-build-forwards-equals-form \
  "$(printf 'argc=1\narg=--tls=openssl')" \
  --build --tls=openssl

# Regression (review fix, #19): a string accumulator's unquoted expansion
# word-splits a forwarded value containing whitespace, so this reached
# cmd_build as TWO arguments before the "$@" rotate fix. Pinning it at
# argc=2, both boundaries intact, is the assertion the previous round's
# accumulator-based fix could not have passed.
_assert_build_forward makesum-build-forwards-value-with-space \
  "$(printf 'argc=2\narg=--openssldir\narg=/path with space')" \
  --build --openssldir "/path with space"

# --profile is one of makesum's OWN options (consumed to set PROFILE_NAME,
# same as before --build existed) and must never reach cmd_build's argument
# vector at all -- the case the loop's counter arithmetic can silently break
# by mis-tracking how many tokens a value-taking option actually consumed.
_assert_build_forward makesum-build-consumes-profile-not-forwarded \
  "$(printf 'argc=2\narg=--tls\narg=openssl')" \
  --build --profile 7.1 --tls openssl

# Restored so the stub cannot leak into any later assertion in this file --
# this is currently the last section, but the discipline holds regardless of
# ordering.
unset -f cmd_build

# -- --dry-run must not fetch/extract/build/install FFmpeg (#19) -------------
# recipes/ffmpeg.sh is sourced directly by cmd_build rather than through
# run_recipe(), so lib/framework.sh's DRY_RUN short-circuit never reached it:
# a dry run downloaded and re-extracted the FFmpeg tarball regardless of
# --dry-run. Asserted on process output, not the filesystem -- pointing
# DISTDIR at a temp dir and asserting it stays empty would be stronger, but
# tests/oracle-baseline.sh runs every added test against the unpatched merge
# base, where that assertion would download a real tarball on every
# tests/run.sh.
_out=$(./mediaforge.sh build --dry-run --yes 2>&1) || true

if printf '%s' "$_out" | grep -qF -- 'Would build FFmpeg'; then
  _pass dry-run-logs-would-build-ffmpeg
else
  _bad dry-run-logs-would-build-ffmpeg "no 'Would build FFmpeg' line in dry-run output"
fi

# fetch() (lib/download.sh) logs "Extracted $_file" only after a real
# tar-extract succeeds -- its presence here means recipes/ffmpeg.sh actually
# ran despite --dry-run.
if printf '%s' "$_out" | grep -qF -- 'Extracted '; then
  _bad dry-run-does-not-extract-ffmpeg "dry-run output shows a real extraction"
else
  _pass dry-run-does-not-extract-ffmpeg
fi

# -- amf pkg_install probes for whichever known header layout landed --------
# THE BUG THIS PINS (#7b). pkg_install() hardcoded `cp -r AMF/components
# AMF/core`, which is only 1.5.0's post-strip-components-1 shape. 1.4.33 and
# 1.4.34 land at the tarball root (components/, core/); 1.4.32 has no
# published headers asset at all and falls back to the source archive, whose
# post-strip root is amf/public/include/{components,core}. Three real
# layouts, one hardcoded copy -- so 1.4.33 downloaded fine (it already had a
# recorded digest) and still failed at install, which is exactly what
# `makesum` recording alone could never catch: it never runs pkg_install().
#
# Hermetic: each fixture reproduces one upstream layout under $_fx, verified
# against the real tarballs during this task (see task-7b-report.md) rather
# than invented. recipes/hwaccel/amf.sh is sourced directly for its
# pkg_install function -- sourcing it only assigns PKG_* variables and defines
# functions, the same precondition tests/git-commit-pinning.sh already relies
# on for its three recipes.
#
# Outer guard: a grep marker naming the fixed probe's own source-archive
# branch, not digest_file. digest_file is a Task 1 addition and is undefined
# on the merge base too, but it says nothing about amf.sh -- guarding on it
# would let amf-install-shape-nested silently PASS on the base, since the
# base's hardcoded `cp -r AMF/components AMF/core` already matches the 1.5.0
# fixture, for a reason unrelated to the code under test. The grep marker
# fails on the base for the real reason: the base's amf.sh has no
# source-archive fallback branch at all.
if grep -q 'amf/public/include/components' "$ROOT/recipes/hwaccel/amf.sh" 2>/dev/null; then
  # shellcheck disable=SC1091
  . "$ROOT/recipes/hwaccel/amf.sh"

  _amf_run_probe() {
    # $1: fixture dir holding one upstream layout at its root (post-strip).
    _amf_src="$1"
    _amf_prefix="$_amf_src-prefix"
    mkdir -p "$_amf_prefix"
    ( PREFIX="$_amf_prefix"; cd "$_amf_src" && pkg_install >/dev/null 2>&1 )
    _amf_rc=$?
    printf '%s %s\n' "$_amf_rc" "$_amf_prefix"
  }

  # Inner guard, per assertion: the outer grep proves the FIXED amf.sh is on
  # disk, but not that sourcing it actually defined pkg_install -- a sourcing
  # failure must be caught here rather than misread by amf-install-shape-
  # unknown-dies as the expected die() (an undefined pkg_install exits 127,
  # which is also non-zero).
  if _require_fn pkg_install amf-install-shape-nested; then
    # 1.5.0 shape: AMF/components, AMF/core.
    _amf_150="$_fx/amf-1.5.0"
    mkdir -p "$_amf_150/AMF/components" "$_amf_150/AMF/core"
    printf 'h' > "$_amf_150/AMF/components/Component.h"
    printf 'h' > "$_amf_150/AMF/core/Interface.h"
    read -r _rc _prefix <<EOF
$(_amf_run_probe "$_amf_150")
EOF
    if [ "$_rc" = 0 ] && [ -f "$_prefix/include/AMF/components/Component.h" ] \
       && [ -f "$_prefix/include/AMF/core/Interface.h" ]; then
      _pass amf-install-shape-nested
    else
      _bad amf-install-shape-nested "rc=$_rc, expected headers not found under $_prefix/include/AMF"
    fi
  fi

  if _require_fn pkg_install amf-install-shape-bare; then
    # 1.4.33/1.4.34 shape: components, core at the tarball root.
    _amf_bare="$_fx/amf-1.4.33"
    mkdir -p "$_amf_bare/components" "$_amf_bare/core"
    printf 'h' > "$_amf_bare/components/Component.h"
    printf 'h' > "$_amf_bare/core/Interface.h"
    read -r _rc _prefix <<EOF
$(_amf_run_probe "$_amf_bare")
EOF
    if [ "$_rc" = 0 ] && [ -f "$_prefix/include/AMF/components/Component.h" ] \
       && [ -f "$_prefix/include/AMF/core/Interface.h" ]; then
      _pass amf-install-shape-bare
    else
      _bad amf-install-shape-bare "rc=$_rc, expected headers not found under $_prefix/include/AMF"
    fi
  fi

  if _require_fn pkg_install amf-install-shape-source-archive; then
    # 1.4.32 shape: amf/public/include/{components,core} (no headers asset
    # was ever published for this version; falls back to the GitHub source
    # archive).
    _amf_src_archive="$_fx/amf-1.4.32"
    mkdir -p "$_amf_src_archive/amf/public/include/components" \
             "$_amf_src_archive/amf/public/include/core"
    printf 'h' > "$_amf_src_archive/amf/public/include/components/Component.h"
    printf 'h' > "$_amf_src_archive/amf/public/include/core/Interface.h"
    read -r _rc _prefix <<EOF
$(_amf_run_probe "$_amf_src_archive")
EOF
    if [ "$_rc" = 0 ] && [ -f "$_prefix/include/AMF/components/Component.h" ] \
       && [ -f "$_prefix/include/AMF/core/Interface.h" ]; then
      _pass amf-install-shape-source-archive
    else
      _bad amf-install-shape-source-archive "rc=$_rc, expected headers not found under $_prefix/include/AMF"
    fi
  fi

  if _require_fn pkg_install amf-install-shape-unknown-dies; then
    # None of the three known layouts -- pkg_install must die() rather than
    # silently install nothing, so the failure surfaces here instead of at
    # FFmpeg's unrelated configure error.
    _amf_unknown="$_fx/amf-unknown"
    mkdir -p "$_amf_unknown/some/other/layout"
    read -r _rc _prefix <<EOF
$(_amf_run_probe "$_amf_unknown")
EOF
    if [ "$_rc" != 0 ]; then
      _pass amf-install-shape-unknown-dies
    else
      _bad amf-install-shape-unknown-dies "pkg_install exited 0 for an unrecognized layout"
    fi
  fi
else
  _bad amf-install-shape-nested "recipes/hwaccel/amf.sh has no source-archive fallback branch -- fix not present"
  _bad amf-install-shape-bare "recipes/hwaccel/amf.sh has no source-archive fallback branch -- fix not present"
  _bad amf-install-shape-source-archive "recipes/hwaccel/amf.sh has no source-archive fallback branch -- fix not present"
  _bad amf-install-shape-unknown-dies "recipes/hwaccel/amf.sh has no source-archive fallback branch -- fix not present"
fi
# -- verify_file --------------------------------------------------------------
printf 'test' > "$_fx/good.tar.gz"
cat > "$_fx/v.hash" <<EOF
sha256  $_KAT  good.tar.gz
size    4  good.tar.gz
sha256  $_KAT  nosize.tar.gz
EOF
PKG_HASH_FILE="$_fx/v.hash"

verify_file "$_fx/good.tar.gz" good.tar.gz; _rc=$?
if [ "$_rc" -eq 0 ]; then _pass verify-accepts-good; else _bad verify-accepts-good "rc=$_rc"; fi

printf 'tampered' > "$_fx/bad.tar.gz"
cp "$_fx/v.hash" "$_fx/v2.hash"
printf 'sha256  %s  bad.tar.gz\nsize    4  bad.tar.gz\n' "$_KAT" >> "$_fx/v2.hash"
PKG_HASH_FILE="$_fx/v2.hash"
verify_file "$_fx/bad.tar.gz" bad.tar.gz; _rc=$?
if [ "$_rc" -eq 2 ]; then _pass verify-detects-mismatch; else _bad verify-detects-mismatch "rc=$_rc"; fi

PKG_HASH_FILE="$_fx/v.hash"
verify_file "$_fx/good.tar.gz" absent.tar.gz; _rc=$?
if [ "$_rc" -eq 3 ]; then _pass verify-no-record; else _bad verify-no-record "rc=$_rc"; fi

# size is mandatory: a sha256 with no size is an incomplete record, not a pass.
verify_file "$_fx/good.tar.gz" nosize.tar.gz; _rc=$?
if [ "$_rc" -eq 3 ]; then _pass verify-size-mandatory; else _bad verify-size-mandatory "rc=$_rc"; fi

# Boundary: size N passes, N-1 and N+1 both fail. A far-from-boundary value
# would pass against an off-by-one comparison and guard nothing.
for _sz in 3 5; do
  printf 'sha256  %s  good.tar.gz\nsize    %s  good.tar.gz\n' "$_KAT" "$_sz" > "$_fx/sz.hash"
  PKG_HASH_FILE="$_fx/sz.hash"
  verify_file "$_fx/good.tar.gz" good.tar.gz; _rc=$?
  if [ "$_rc" -eq 2 ]; then _pass "verify-size-boundary-$_sz"; else _bad "verify-size-boundary-$_sz" "rc=$_rc"; fi
done

# The actual swap/MITM shape: a file the RIGHT size but the WRONG content.
# verify-detects-mismatch above differs in size too, so it short-circuits at
# the size check (line ~208) and never reaches the sha256 loop at all -- this
# is the only assertion that proves the digest loop itself rejects a mismatch.
printf 'XXXX' > "$_fx/swap.tar.gz"
printf 'sha256  %s  swap.tar.gz\nsize    4  swap.tar.gz\n' "$_KAT" > "$_fx/swap.hash"
PKG_HASH_FILE="$_fx/swap.hash"
verify_file "$_fx/swap.tar.gz" swap.tar.gz; _rc=$?
if [ "$_rc" -eq 2 ]; then _pass verify-detects-mismatch-same-size; else _bad verify-detects-mismatch-same-size "rc=$_rc"; fi

# A recipe with no hash file at all must die. Buildroot warns and returns 0
# here; TALOS-2023-1844 is the report of that being exploitable.
#
# Negative assertion (success == "it died"): on a tree without verify_file the
# subshell exits 127, which this shape would misread as "died as required" and
# report PASS -- exactly what tests/oracle-baseline.sh rejects. Guarded like
# the file's other negative assertions (e.g. digest-rejects-md5 above).
if _require_fn verify_file verify-missing-hashfile-dies; then
  PKG_HASH_FILE="$_fx/does-not-exist.hash"
  if ( verify_file "$_fx/good.tar.gz" good.tar.gz ) >/dev/null 2>&1; then
    _bad verify-missing-hashfile-dies "a missing hash file was tolerated"
  else
    _pass verify-missing-hashfile-dies
  fi
fi

# -- fetch() actions on each verify_file outcome ------------------------------
# The actions fetch() takes on verify_file's return codes are not exercised by
# the unit tests above. Reuses tests/fetch-fail-no-cache.sh's local-HTTP-server
# pattern (bind 127.0.0.1 on an ephemeral port, publish it via PORT_FILE,
# trap-kill on exit) rather than exiting mid-file on a missing python3, which
# would suppress the DONE: sentinel tests/oracle-baseline.sh requires.
if command -v python3 >/dev/null 2>&1; then
  # The server's document root is separate from DISTDIR and is never mutated
  # after this point, so corrupting the cached copy in DISTDIR (below) cannot
  # also corrupt what the server hands back on re-download.
  _srvroot="$_fx/srvroot"; mkdir -p "$_srvroot"

  # fetch() reaches extraction once a file verifies, so the fixture must be a
  # real archive: a plain-text stand-in dies at "Failed to extract" before
  # fetch() ever returns, and the assertions below can't observe the return
  # value they're checking.
  _archsrc="$_fx/archsrc"; mkdir -p "$_archsrc"
  printf 'test' > "$_archsrc/payload.txt"
  ( cd "$_archsrc" && tar -czf "$_srvroot/good.tar.gz" payload.txt )
  _ARCHSUM=$(digest_file sha256 "$_srvroot/good.tar.gz")
  _ARCHSIZE=$(file_size "$_srvroot/good.tar.gz")

  PORT_FILE=$(mktemp)
  python3 -c '
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            with open(sys.argv[2] + self.path, "rb") as f:
                body = f.read()
        except OSError:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

srv = HTTPServer(("127.0.0.1", 0), H)
with open(sys.argv[1], "w") as f:
    f.write(str(srv.server_address[1]))
    f.flush()
srv.serve_forever()
' "$PORT_FILE" "$_srvroot" &
  SRV_PID=$!

  _i=0
  PORT=''
  while [ "$_i" -lt 50 ]; do
    PORT=$(cat "$PORT_FILE" 2>/dev/null)
    [ -n "$PORT" ] && break
    sleep 0.1
    _i=$((_i + 1))
  done
  rm -f "$PORT_FILE"

  if [ -z "$PORT" ]; then
    _bad fetch-cached-mismatch-redownloads "server did not start"
    _bad fetch-no-record-keeps-file "server did not start"
    _bad fetch-fresh-mismatch-deletes "server did not start"
    _bad fetch-cached-mismatch-fails-twice-deletes "server did not start"
    _bad fetch-cached-no-record-keeps-file "server did not start"
  else
    _serve="$_fx/dist"; mkdir -p "$_serve"
    export DISTDIR="$_serve"
    PKG_URL=''; PKG_FILENAME=''; PKG_DIRNAME=''
    export PKG_URL PKG_FILENAME PKG_DIRNAME

    printf 'sha256  %s  good.tar.gz\nsize    %s  good.tar.gz\n' "$_ARCHSUM" "$_ARCHSIZE" > "$_fx/fetch.hash"
    PKG_HASH_FILE="$_fx/fetch.hash"

    # A corrupt CACHED file is re-downloaded once and the replacement
    # verified. This is the core #19 case: fetch() used to reuse a cached
    # file unconditionally, forever, with no re-examination at all.
    printf 'corrupted' > "$_serve/good.tar.gz"
    if ( fetch "http://127.0.0.1:$PORT/good.tar.gz" good.tar.gz gooddir ) >/dev/null 2>&1; then
      if [ "$(digest_file sha256 "$_serve/good.tar.gz")" = "$_ARCHSUM" ]; then
        _pass fetch-cached-mismatch-redownloads
      else
        _bad fetch-cached-mismatch-redownloads "file was not replaced"
      fi
    else
      _bad fetch-cached-mismatch-redownloads "fetch died instead of re-downloading"
    fi

    # A missing record aborts and LEAVES the file: the hash file is the
    # likely defect, and deleting would force a re-download from a possibly
    # worse source.
    #
    # On the baseline tree fetch() has no verification at all, so a fresh
    # download always leaves the file behind regardless of any hash record --
    # this assertion would PASS on the baseline for a reason unrelated to
    # verify_file. ANDed with a grep for the marker, the same shape as the
    # MAKESUM_MODE check above, so only a tree that both has the feature and
    # keeps the file on a missing record passes.
    rm -f "$_serve/good.tar.gz"
    printf 'sha256  %s  other.tar.gz\nsize    %s  other.tar.gz\n' "$_ARCHSUM" "$_ARCHSIZE" > "$_fx/norec.hash"
    PKG_HASH_FILE="$_fx/norec.hash"
    ( fetch "http://127.0.0.1:$PORT/good.tar.gz" good.tar.gz gooddir ) >/dev/null 2>&1
    if grep -q 'verify_file' "$ROOT/lib/download.sh" && [ -f "$_serve/good.tar.gz" ]; then
      _pass fetch-no-record-keeps-file
    else
      _bad fetch-no-record-keeps-file "file was deleted on a missing-record abort, or lib/download.sh doesn't reference verify_file at all"
    fi

    # A mismatched FRESH download deletes and dies: no retry, since there is
    # no earlier good copy to fall back to. $_KAT ("test") is guaranteed
    # wrong for an archive's own bytes -- reused here as a deliberately-bad
    # digest rather than hand-typed hex.
    printf 'sha256  %s  good2.tar.gz\nsize    %s  good2.tar.gz\n' "$_KAT" "$_ARCHSIZE" > "$_fx/freshmismatch.hash"
    PKG_HASH_FILE="$_fx/freshmismatch.hash"
    ( fetch "http://127.0.0.1:$PORT/good.tar.gz" good2.tar.gz gooddir2 ) >/dev/null 2>&1
    _frc=$?
    if [ "$_frc" -ne 0 ] && [ ! -f "$_serve/good2.tar.gz" ]; then
      _pass fetch-fresh-mismatch-deletes
    else
      _bad fetch-fresh-mismatch-deletes "rc=$_frc, file present=$([ -f "$_serve/good2.tar.gz" ] && echo yes || echo no)"
    fi

    # A cached mismatch that fails TWICE (the corrupt cache and the
    # replacement both fail against a record that matches neither) deletes
    # and dies -- the retry does not loop, and does not keep a file it could
    # never verify. On the baseline this can't pass for the wrong reason:
    # baseline fetch() never verifies, so it treats the corrupt cached bytes
    # as the archive and dies at extraction WITHOUT deleting them -- rc != 0
    # but the file is still there, which the combined check below rejects.
    printf 'sha256  %s  good3.tar.gz\nsize    %s  good3.tar.gz\n' "$_KAT" "$_ARCHSIZE" > "$_fx/twicewrong.hash"
    PKG_HASH_FILE="$_fx/twicewrong.hash"
    printf 'corrupted' > "$_serve/good3.tar.gz"
    ( fetch "http://127.0.0.1:$PORT/good.tar.gz" good3.tar.gz gooddir3 ) >/dev/null 2>&1
    _trc=$?
    if [ "$_trc" -ne 0 ] && [ ! -f "$_serve/good3.tar.gz" ]; then
      _pass fetch-cached-mismatch-fails-twice-deletes
    else
      _bad fetch-cached-mismatch-fails-twice-deletes "rc=$_trc, file present=$([ -f "$_serve/good3.tar.gz" ] && echo yes || echo no)"
    fi

    # A missing record on a CACHED file keeps it too, not only on the fresh
    # path tested above -- the disposition is "no usable record", not
    # "no usable record AND it just arrived".
    printf 'sha256  %s  other4.tar.gz\nsize    %s  other4.tar.gz\n' "$_ARCHSUM" "$_ARCHSIZE" > "$_fx/norec-cached.hash"
    PKG_HASH_FILE="$_fx/norec-cached.hash"
    printf 'whatever-cached-bytes' > "$_serve/good4.tar.gz"
    ( fetch "http://127.0.0.1:$PORT/good.tar.gz" good4.tar.gz gooddir4 ) >/dev/null 2>&1
    if grep -q 'verify_file' "$ROOT/lib/download.sh" && [ -f "$_serve/good4.tar.gz" ]; then
      _pass fetch-cached-no-record-keeps-file
    else
      _bad fetch-cached-no-record-keeps-file "file was deleted on a missing-record abort (cached path), or lib/download.sh doesn't reference verify_file"
    fi
  fi

  kill "$SRV_PID" 2>/dev/null
  SRV_PID=''
else
  printf 'SKIP (no python3): fetch-cached-mismatch-redownloads, fetch-no-record-keeps-file, fetch-fresh-mismatch-deletes, fetch-cached-mismatch-fails-twice-deletes, fetch-cached-no-record-keeps-file\n'
fi

# Optional sha512/sha1 records are verified too, not merely tolerated.
printf 'test' > "$_fx/opt.txt"
_S512=$(digest_file sha512 "$_fx/opt.txt")
printf 'sha256  %s  opt.txt\nsize    4  opt.txt\nsha512  %s  opt.txt\n' "$_KAT" "$_S512" > "$_fx/opt.hash"
PKG_HASH_FILE="$_fx/opt.hash"
verify_file "$_fx/opt.txt" opt.txt; _rc=$?
if [ "$_rc" -eq 0 ]; then _pass verify-optional-sha512-ok; else _bad verify-optional-sha512-ok "rc=$_rc"; fi

printf 'sha256  %s  opt.txt\nsize    4  opt.txt\nsha512  deadbeef  opt.txt\n' "$_KAT" > "$_fx/opt2.hash"
PKG_HASH_FILE="$_fx/opt2.hash"
verify_file "$_fx/opt.txt" opt.txt; _rc=$?
if [ "$_rc" -eq 2 ]; then _pass verify-optional-sha512-mismatch; else _bad verify-optional-sha512-mismatch "rc=$_rc"; fi

# -- makesum_fetch_and_record (review fix, #19) -------------------------------
# The fetch-or-skip-then-record mechanism cmd_makesum's per-recipe loop used
# inline, extracted so FFmpeg's own tarball (below) can share it instead of
# duplicating it. file:// needs no server -- curl supports it directly.
#
# Expected digest is a known-answer constant (sha256("mfr-content")), not
# computed via digest_file: on a tree old enough to lack digest_file/hash_lookup
# entirely (this file's population spans the whole branch, back past where
# those primitives were introduced), a computed expectation and an
# equally-undefined hash_lookup both silently return empty, and empty equals
# empty -- the exact false-PASS trap _NESTED_KAT above this already avoids.
_mfr_src="$_fx/mfr-src.txt"
printf 'mfr-content' > "$_mfr_src"
_mfr_dist="$_fx/mfr-dist"; mkdir -p "$_mfr_dist"
_mfr_hash="$_fx/mfr.hash"
DISTDIR="$_mfr_dist"
( makesum_fetch_and_record "$_mfr_hash" mfr-src.txt "file://$_mfr_src" ) >/dev/null 2>&1
_MFR_KAT=b859bb8e00a50abfb59ceef6807f0752d72190c0c09baab3fa0797a438153074
if [ "$(hash_lookup "$_mfr_hash" mfr-src.txt sha256)" = "$_MFR_KAT" ]; then
  _pass makesum-fetch-and-record-writes
else
  _bad makesum-fetch-and-record-writes "no matching sha256 record written"
fi

# -- cmd_makesum reaches FFmpeg's own tarball (review fix, #19) --------------
# THE BUG THIS PINS. recipes/ffmpeg.sh is sourced directly by cmd_build, never
# listed in recipes/_order.conf, so cmd_makesum's per-recipe loop never
# reached it -- a plain `makesum --profile=X` recorded every other recipe and
# silently skipped FFmpeg, and the only path that COULD record it
# (`makesum --build`) needs the whole dependency chain built first, making
# verify_file's own "run makesum to record it" advice unfollowable for the
# one file three of four profiles actually needed it for.
#
# Sandboxed under a fixture SCRIPT_DIR/DISTDIR/profile so this never touches
# the real repo's recipes/ffmpeg.hash or the network: _order.conf is empty (so
# the per-recipe loop has nothing to do) and download_file is shadowed to
# copy a local fixture instead of curling GitHub -- the same
# shadow-the-side-effect idiom the cmd_build stub above uses. Restored via a
# re-source immediately after, so it cannot leak into anything after this test
# (matching that same block's own restoration discipline).
_mfroot="$_fx/mf-root"
mkdir -p "$_mfroot/recipes" "$_mfroot/profiles"
: > "$_mfroot/recipes/_order.conf"
printf 'FFMPEG_VERSION="9.9.9"\n' > "$_mfroot/profiles/ffmpeg-9.9.9.conf"

_ffdist="$_fx/mf-dist"; mkdir -p "$_ffdist"
_fffixture="$_fx/ffmpeg-fixture.tar.gz"
printf 'fixture ffmpeg tarball' > "$_fffixture"

# shellcheck disable=SC2329
download_file() {
  cp "$_fffixture" "$2"
}

( SCRIPT_DIR="$_mfroot" DISTDIR="$_ffdist" cmd_makesum --profile=9.9.9 ) >/dev/null 2>&1

. "$ROOT/lib/download.sh"

# Known-answer constant (sha256("fixture ffmpeg tarball")), not
# digest_file-computed -- same false-PASS trap as makesum-fetch-and-record-writes
# above: on a tree old enough to lack digest_file, a computed expectation and
# an undefined hash_lookup both silently return empty.
_FF_KAT=c0abbb33f3822d3f963ecb9abb4e6f6ca57ed64e8c9b5cb19f14eb505db2d6e1
if [ "$(hash_lookup "$_mfroot/recipes/ffmpeg.hash" FFmpeg-release-9.9.9.tar.gz sha256)" = "$_FF_KAT" ]; then
  _pass cmd-makesum-reaches-ffmpeg
else
  _bad cmd-makesum-reaches-ffmpeg "no matching record for FFmpeg-release-9.9.9.tar.gz"
fi

# A package filter scopes to exactly that package -- it must NOT also touch
# FFmpeg, which isn't itself a selectable name in the registry.
#
# "ffmpeg.hash was never created" is trivially true on ANY tree that doesn't
# reach FFmpeg from cmd_makesum at all, base included -- so on its own this
# assertion would PASS there for the wrong reason (tests/oracle-baseline.sh
# rejects exactly that). ANDed with a grep for the marker, the same shape as
# the MAKESUM_MODE and no-record fetch()-level checks above: only a tree that
# both reaches FFmpeg (cmd-makesum-reaches-ffmpeg, above, proves that half)
# AND scopes it correctly passes.
_mfroot2="$_fx/mf-root2"
mkdir -p "$_mfroot2/recipes" "$_mfroot2/profiles"
: > "$_mfroot2/recipes/_order.conf"
printf 'FFMPEG_VERSION="9.9.9"\n' > "$_mfroot2/profiles/ffmpeg-9.9.9.conf"
( SCRIPT_DIR="$_mfroot2" DISTDIR="$_fx/mf-dist2" cmd_makesum --profile=9.9.9 giflib ) >/dev/null 2>&1
if grep -q 'ffmpeg_tarball_filename' "$ROOT/mediaforge.sh" && [ ! -f "$_mfroot2/recipes/ffmpeg.hash" ]; then
  _pass cmd-makesum-scoped-skips-ffmpeg
else
  _bad cmd-makesum-scoped-skips-ffmpeg "ffmpeg.hash was created despite an explicit package filter, or mediaforge.sh doesn't reference ffmpeg_tarball_filename at all"
fi

# -- --skip-checksum: checksum_skipped keys by PKG_NAME (Task 9, #19) --------
# On the baseline (and on the Task 8 stub) the function either doesn't exist
# (rc 127) or always returns 1, so every one of these is guarded by
# _require_fn: without it, an undefined checksum_skipped would make the
# "expected it to skip" assertions below read as a correctly-failing negative
# and PASS for the wrong reason -- exactly what tests/oracle-baseline.sh
# rejects.
#
# skip-off-by-default is NOT load-bearing on its own: the Task 8 stub also
# always returns 1, so it cannot distinguish the stub from the real
# implementation. It documents the safe default; skip-global, skip-named and
# skip-other-recipe are what actually pin PKG_NAME-keyed behaviour, because
# the stub can never return 0.
if _require_fn checksum_skipped skip-off-by-default; then
  PKG_NAME=zlib
  SKIP_CHECKSUM=false
  SKIP_CHECKSUM_PKGS=""
  if checksum_skipped; then _bad skip-off-by-default "skipped with no flag"; else _pass skip-off-by-default; fi
fi

if _require_fn checksum_skipped skip-global; then
  PKG_NAME=zlib
  SKIP_CHECKSUM=true
  SKIP_CHECKSUM_PKGS=""
  if checksum_skipped; then _pass skip-global; else _bad skip-global "global flag did not skip"; fi
fi

if _require_fn checksum_skipped skip-named; then
  PKG_NAME=zlib
  SKIP_CHECKSUM=false
  SKIP_CHECKSUM_PKGS=" zlib "
  if checksum_skipped; then _pass skip-named; else _bad skip-named "named recipe was not skipped"; fi
fi

if _require_fn checksum_skipped skip-other-recipe; then
  PKG_NAME=zlib
  SKIP_CHECKSUM=false
  SKIP_CHECKSUM_PKGS=" other "
  if checksum_skipped; then _bad skip-other-recipe "a different recipe's name skipped this one"; else _pass skip-other-recipe; fi
fi
SKIP_CHECKSUM=false
SKIP_CHECKSUM_PKGS=""

# -- --skip-checksum is loud: warns naming the file it bypassed --------------
# The loudness requirement ("someone who bypasses the gate should not be able
# to forget they did") is a behaviour, not a doc line, so it needs its own
# assertion rather than trusting fetch()'s skip branch exists. Matched on the
# literal warning text, not just the filename: fetch()'s "No hash file" die
# message also names the file, so a filename-only match would false-PASS on
# the pre-Task-9 tree (where checksum_skipped exists as the Task 8 stub,
# always returns 1, and this fetch() dies with that message instead of
# skipping).
if _require_fn checksum_skipped skip-checksum-warns-filename; then
  _loudsrc="$_fx/loudsrc"; mkdir -p "$_loudsrc"
  printf 'test' > "$_loudsrc/payload.txt"
  _louddist="$_fx/louddist"; mkdir -p "$_louddist"
  ( cd "$_loudsrc" && tar -czf "$_louddist/loud.tar.gz" payload.txt )
  DISTDIR="$_louddist"
  PKG_URL="file://$_louddist/loud.tar.gz"
  PKG_FILENAME="loud.tar.gz"
  PKG_DIRNAME="louddir"
  PKG_HASH_FILE="$_fx/does-not-exist-loud.hash"
  PKG_NAME=loudpkg
  SKIP_CHECKSUM=true
  SKIP_CHECKSUM_PKGS=""
  _loudout=$( ( fetch ) 2>&1 >/dev/null )
  if printf '%s' "$_loudout" | grep -qF 'SKIPPED for loud.tar.gz'; then
    _pass skip-checksum-warns-filename
  else
    _bad skip-checksum-warns-filename "no loud warning naming loud.tar.gz: $_loudout"
  fi
  SKIP_CHECKSUM=false
fi

# -- --skip-checksum CLI parsing: comma-separated and repeated (Task 9) ------
# Mirrors --disable=/--enable=: both a single comma-joined value and repeated
# flags accumulate into SKIP_CHECKSUM_PKGS, and the bare boolean flag prints
# the ALL-recipes banner line. grep -q on mediaforge.sh's own source is the
# only oracle available here -- cmd_build isn't a function this file can call
# in-process without also running the full build, so this shells out to the
# real script under --dry-run, the same idiom tests/dry-run-matrix.sh uses.
_cliout=$(cd "$ROOT" && ./mediaforge.sh build --dry-run --yes \
  --skip-checksum=zlib,giflib --skip-checksum=opus 2>&1)
if printf '%s' "$_cliout" | grep -q 'zlib' \
   && printf '%s' "$_cliout" | grep -q 'giflib' \
   && printf '%s' "$_cliout" | grep -q 'opus'; then
  _pass skip-checksum-cli-comma-and-repeated
else
  _bad skip-checksum-cli-comma-and-repeated "banner missing one of zlib/giflib/opus: $_cliout"
fi

_cliout2=$(cd "$ROOT" && ./mediaforge.sh build --dry-run --yes --skip-checksum 2>&1)
if printf '%s' "$_cliout2" | grep -qi 'ALL recipes'; then
  _pass skip-checksum-cli-global-banner
else
  _bad skip-checksum-cli-global-banner "no ALL-recipes banner line: $_cliout2"
fi

# -- --skip-checksum is never persisted (Task 9, #19) -------------------------
# A security bypass that silently survives into a later build is worse than no
# bypass: the next build would skip verification with nothing on the command
# line to say so. Exercises save_stored_choices() directly with DRY_RUN unset
# (the brief's own --dry-run recipe never reaches the writer at all --
# save_stored_choices returns early under DRY_RUN, lib/resolve.sh:332 -- so
# that shape asserts nothing and is not used here).
#
# Guarded the same way as the checksum_skipped block above: on the baseline,
# neither SKIP_CHECKSUM nor checksum_skipped exists, so save_stored_choices
# trivially never writes them -- for a reason unrelated to this task. The
# guard keeps that non-finding from counting as a pass.
if _require_fn checksum_skipped skip-checksum-not-persisted; then
  _persistdir="$_fx/persist-prefix"; mkdir -p "$_persistdir"
  PREFIX="$_persistdir"
  DRY_RUN=false
  TLS_BACKEND=gnutls
  AAC_IMPL=native
  H264_IMPL=x264
  H265_IMPL=x265
  AV1_ENC_IMPL=svtav1
  SPIRV_IMPL=glslang
  OPENSSLDIR=""
  SKIP_CHECKSUM=true
  SKIP_CHECKSUM_PKGS="zlib giflib"
  save_stored_choices
  if [ -f "$_persistdir/.mediaforge-choices" ] \
     && ! grep -qi 'checksum' "$_persistdir/.mediaforge-choices"; then
    _pass skip-checksum-not-persisted
  else
    _bad skip-checksum-not-persisted "choices file missing, or it recorded a checksum-skip setting (wrote SKIP_CHECKSUM=$SKIP_CHECKSUM SKIP_CHECKSUM_PKGS=$SKIP_CHECKSUM_PKGS)"
  fi
fi

printf 'DONE:\n'
exit "$_fail"
