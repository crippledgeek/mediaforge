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

_fx=$(mktemp -d); trap 'rm -rf "$_fx"' EXIT INT TERM

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
# a build -- recipes/ffmpeg.sh's real network fetch bypasses --dry-run
# entirely (a separate, already-flagged bug; not this fix), so invoking the
# real cmd_build here would make this test dependent on the network.
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

printf 'DONE:\n'
exit "$_fail"
