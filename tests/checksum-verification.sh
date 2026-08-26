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

# Sentinel digests for fixtures whose VALUE is irrelevant but whose LENGTH is
# not: hash_file_validate enforces 64/128/40 hex characters per keyword, so a
# short stand-in like `1111` would be rejected for its length and every
# fixture below would then be testing the length check rather than the
# behaviour it was written for.
_H64_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
_H64_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
_H64_1=1111111111111111111111111111111111111111111111111111111111111111
_H64_Z=zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz

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
sha256  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  other.tar.gz
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
      non-hex)           printf 'sha256  %s  f.tar.gz\n' "$_H64_Z" > "$_fx/bad.hash" ;;
      non-numeric-size)  printf 'size  many  f.tar.gz\n' > "$_fx/bad.hash" ;;
      duplicate)         printf 'sha256  %s  f.tar.gz\nsha256  %s  f.tar.gz\n' "$_H64_A" "$_H64_B" > "$_fx/bad.hash" ;;
      md5-keyword)       printf 'md5  aa  f.tar.gz\n' > "$_fx/bad.hash" ;;
    esac
    if ( hash_file_validate "$_fx/bad.hash" ) >/dev/null 2>&1; then
      _bad "validate-rejects-$_case" "malformed file was accepted"
    else
      _pass "validate-rejects-$_case"
    fi
  done
fi

# A digest of the wrong LENGTH is a malformed sidecar, and must be reported as
# one. Without a length check `sha256  ab  foo.tar.gz` parses as well-formed
# and only surfaces at verify_file as a digest MISMATCH -- which reads as
# tampering and sends the reader hunting a compromised mirror, when the actual
# defect is two characters in a text file. One negative per keyword, because a
# single shared length would accept a sha1 in a sha256 record.
if _require_fn hash_file_validate validate-rejects-length-guard; then
  for _lc in sha256:ab sha512:ab sha1:ab sha256:$_H64_A$_H64_A sha1:$_H64_A; do
    _lk=${_lc%%:*}
    _lv=${_lc#*:}
    printf '%s  %s  f.tar.gz\nsize  4  f.tar.gz\n' "$_lk" "$_lv" > "$_fx/len.hash"
    if ( hash_file_validate "$_fx/len.hash" ) >/dev/null 2>&1; then
      _bad "validate-rejects-length-$_lk-${#_lv}" "a $_lk digest of ${#_lv} hex characters was accepted"
    else
      _pass "validate-rejects-length-$_lk-${#_lv}"
    fi
  done

  # Positive companion: the exact lengths must still be accepted, or the check
  # above would pass by rejecting everything.
  printf 'sha256  %s  f.tar.gz\nsha512  %s%s  f.tar.gz\nsha1  %s  f.tar.gz\nsize  4  f.tar.gz\n' \
    "$_H64_A" "$_H64_A" "$_H64_B" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" > "$_fx/len-ok.hash"
  if ( hash_file_validate "$_fx/len-ok.hash" ) >/dev/null 2>&1; then
    _pass validate-accepts-exact-lengths
  else
    _bad validate-accepts-exact-lengths "64/128/40-character digests were rejected"
  fi
fi

# A bad-value record must not still increment the duplicate counter for its
# (keyword, filename) pair, or a later legitimate record for that pair is
# reported as a duplicate that does not exist alongside the real format error.
printf 'sha256  %s  f.tar.gz\nsha256  %s  f.tar.gz\n' "$_H64_Z" "$_H64_A" > "$_fx/bad-then-good.hash"
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
# registry.sh before framework.sh, the order mediaforge.sh itself uses:
# check_guards resolves the recipe's CLI name through recipe_key, which lives
# in the registry. Sourcing framework alone left that call unresolved, and the
# `|| _guard_key="$PKG_NAME"` fallback swallowed it into a `command not found`
# on stderr and a silently pre-fix comparison.
# shellcheck disable=SC1091
. "$ROOT/lib/registry.sh"
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

cat > "$_fx/merge.hash" <<EOF
# From https://example.invalid/old.sha256
sha256  $_H64_1  old.tar.gz
size    11  old.tar.gz
EOF

if _require_fn hash_record_write makesum-merge-preserves; then
  hash_record_write "$_fx/merge.hash" new.tar.gz "$_fx/new.tar.gz"

  if [ "$(hash_lookup "$_fx/merge.hash" old.tar.gz sha256)" = "$_H64_1" ]; then
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
  if [ "$(hash_lookup "$_fx/merge.hash" old.tar.gz sha256)" = "$_H64_1" ]; then
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
  cat > "$_fx/nosize.hash" <<EOF
sha256  $_H64_1  nosize.tar.gz
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
# `makesum --build` (mediaforge.sh) is the only way to reach the fetch() calls
# nested inside a recipe phase function -- see
# nested-fetch-recipes-are-the-documented-set below for the recipes that have
# them -- so the property to pin here is not "fetch records a file" but "a
# fetch called from inside a pkg_install()-like context records into the
# ENCLOSING recipe's PKG_HASH_FILE", since that is exactly what those calls
# depend on.
# (recipes/ffmpeg.sh's own fetch is at that file's top level, not inside a
# phase function; `makesum` reaches it without --build, via
# makesum_fetch_and_record.) No `hash_record_write`/`fetch` _require_fn guard
# is needed below: fetch() already exists on the baseline tree (Task 5 and
# earlier), so an unguarded comparison against $_KAT already fails naturally
# there -- no record is written pre-patch, hash_lookup returns empty, and ""
# != $_KAT reports FAIL, exactly as it must.
_mk_dist="$_fx/makesum-distdir"
mkdir -p "$_mk_dist"
_mk_origin="$_fx/makesum-origin"
mkdir -p "$_mk_origin"

# Positive: fetch() with MAKESUM_MODE=true records what it fetched into
# PKG_HASH_FILE. Served over file:// so no network is touched; the *.patch
# filename makes fetch() return before extraction, matching the recording
# hook's placement (after the file is on disk, before extraction).
printf 'test' > "$_mk_origin/fetch-fixture.patch"
DISTDIR="$_mk_dist"
PKG_HASH_FILE="$_fx/fetch-record.hash"
MAKESUM_MODE=true
( fetch "file://$_mk_origin/fetch-fixture.patch" "fetch-fixture.patch" ) >/dev/null 2>&1
if [ "$(hash_lookup "$_fx/fetch-record.hash" fetch-fixture.patch sha256)" = "$_KAT" ]; then
  _pass fetch-records-when-makesum-mode
else
  _bad fetch-records-when-makesum-mode "no matching sha256 record written"
fi

# -- makesum must not mint a pin from unattested cached bytes (S-F1) ---------
# THE BUG THIS PINS. Under MAKESUM_MODE the cached branch skipped both the
# verify arm and the download arm, so `makesum --build` recorded whatever
# already sat in packages/ -- for the unrecorded sub-build downloads that are
# --build's entire reason to exist. Someone who built before this branch and
# then ran `makesum --build` pinned their months-old DISTDIR, and every later
# build verified happily against those bytes. makesum_needs_fetch was written
# for exactly this decision and was never consulted here.
#
# Fixture: a cache entry with NO recorded digest whose bytes differ from the
# origin's. Only a re-download produces $_KAT.
printf 'test' > "$_mk_origin/unattested.patch"
printf 'stale bytes from a months-old cache' > "$_mk_dist/unattested.patch"
DISTDIR="$_mk_dist"
PKG_HASH_FILE="$_fx/unattested.hash"
MAKESUM_MODE=true
( fetch "file://$_mk_origin/unattested.patch" "unattested.patch" ) >/dev/null 2>&1
if [ "$(hash_lookup "$_fx/unattested.hash" unattested.patch sha256)" = "$_KAT" ]; then
  _pass makesum-refetches-unattested-cache
else
  _bad makesum-refetches-unattested-cache "recorded the stale cached bytes instead of re-downloading"
fi

# Companion: a cache entry that DOES match its recorded digest is attested, so
# it must be reused rather than re-downloaded. Without this the fix above
# could be "always re-download", which would make Task 7's five makesum runs
# over ~107 recipes re-fetch everything every time. Proven by pointing the URL
# at a path that does not exist: any download attempt fails and no record can
# be written, so a passing assertion means no download was attempted.
printf 'test' > "$_mk_dist/attested.patch"
PKG_HASH_FILE="$_fx/attested.hash"
cat > "$_fx/attested.hash" <<EOF
sha256  $_KAT  attested.patch
size    4  attested.patch
EOF
MAKESUM_MODE=true
( fetch "file://$_mk_origin/no-such-origin.patch" "attested.patch" ) >/dev/null 2>&1
if [ "$(hash_lookup "$_fx/attested.hash" attested.patch sha256)" = "$_KAT" ] \
   && [ "$(file_size "$_mk_dist/attested.patch")" = 4 ]; then
  _pass makesum-reuses-attested-cache
else
  _bad makesum-reuses-attested-cache "an attested cache entry was re-downloaded (or destroyed)"
fi
unset MAKESUM_MODE

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
  fetch "file://$_mk_origin/nested-fixture.patch" "nested-fixture.patch"
}
DISTDIR="$_mk_dist"
PKG_HASH_FILE="$_fx/enclosing-recipe.hash"
printf 'nested' > "$_mk_origin/nested-fixture.patch"
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

# Deleted so the stub cannot leak into any later assertion in this file. There
# is no restoring it: `unset -f` removes the definition, and the real
# cmd_build is not redefined afterwards -- nothing below calls it, and the
# sections that exercise the CLI shell out to ./mediaforge.sh instead.
unset -f cmd_build

# The --dry-run side-effect assertions that lived here moved to
# tests/dry-run-matrix.sh, which owns dry-run behaviour and asserts the same
# two properties through its own _run/_run_no helpers.

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

# A WRONG sha512 of the RIGHT length: a short one is now caught earlier, by
# hash_file_validate, and would test the length check rather than the digest
# comparison this assertion is about.
printf 'sha256  %s  opt.txt\nsize    4  opt.txt\nsha512  %s%s  opt.txt\n' "$_KAT" "$_H64_A" "$_H64_B" > "$_fx/opt2.hash"
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

# -- --skip-checksum: checksum_skipped keys by recipe basename (S-F2/F5/F6) --
# On the baseline (and on the Task 8 stub) the function either doesn't exist
# (rc 127) or always returns 1, so every one of these is guarded by
# _require_fn: without it, an undefined checksum_skipped would make the
# "expected it to skip" assertions below read as a correctly-failing negative
# and PASS for the wrong reason -- exactly what tests/oracle-baseline.sh
# rejects.
#
# THE BUG THIS PINS. The skip list used to key on $PKG_NAME, which is neither
# the identifier the CLI validates against nor one that is reliably set:
#   * recipes/ffmpeg.sh is sourced directly by cmd_build, never through
#     run_recipe()/reset_recipe(), so it inherited the LAST _order.conf
#     recipe's PKG_NAME -- `--skip-checksum=opencl` silently disabled
#     verification of the FFmpeg tarball while the banner named only opencl;
#   * three recipes set a PKG_NAME that is not their filename (FreeType2,
#     FreeType2-hb, VapourSynth), so `--skip-checksum=vapoursynth` passed
#     registry validation, printed in the banner, and never matched anything.
# PKG_HASH_FILE is framework-derived for every recipe and set explicitly by
# recipes/ffmpeg.sh, so its basename is always present and always the name the
# CLI accepts.
#
# skip-off-by-default is NOT load-bearing on its own: the Task 8 stub also
# always returns 1, so it cannot distinguish the stub from the real
# implementation. It documents the safe default; the rest are what pin the
# keying, because the stub can never return 0.
if _require_fn checksum_skipped skip-off-by-default; then
  PKG_HASH_FILE="$ROOT/recipes/other/zlib.hash"
  PKG_NAME=zlib
  SKIP_CHECKSUM=false
  SKIP_CHECKSUM_PKGS=""
  if checksum_skipped; then _bad skip-off-by-default "skipped with no flag"; else _pass skip-off-by-default; fi
fi

if _require_fn checksum_skipped skip-global; then
  PKG_HASH_FILE="$ROOT/recipes/other/zlib.hash"
  SKIP_CHECKSUM=true
  SKIP_CHECKSUM_PKGS=""
  if checksum_skipped; then _pass skip-global; else _bad skip-global "global flag did not skip"; fi
fi

if _require_fn checksum_skipped skip-named; then
  PKG_HASH_FILE="$ROOT/recipes/other/zlib.hash"
  SKIP_CHECKSUM=false
  SKIP_CHECKSUM_PKGS="zlib"
  if checksum_skipped; then _pass skip-named; else _bad skip-named "named recipe was not skipped"; fi
fi

if _require_fn checksum_skipped skip-other-recipe; then
  PKG_HASH_FILE="$ROOT/recipes/other/zlib.hash"
  SKIP_CHECKSUM=false
  SKIP_CHECKSUM_PKGS="other"
  if checksum_skipped; then _bad skip-other-recipe "a different recipe's name skipped this one"; else _pass skip-other-recipe; fi
fi

# S-F6: the three recipes whose PKG_NAME differs from their filename. The CLI
# validates against the filename, so keying on PKG_NAME reported a bypass that
# never happened -- fail-closed, but a security control that lies about what it
# did is its own defect. Asserted per recipe, not as a loop over a derived
# list, so a future fourth divergent recipe does not quietly shrink the test.
if _require_fn checksum_skipped skip-key-vapoursynth; then
  SKIP_CHECKSUM=false
  PKG_NAME="VapourSynth"
  PKG_HASH_FILE="$ROOT/recipes/other/vapoursynth.hash"
  SKIP_CHECKSUM_PKGS="vapoursynth"
  if checksum_skipped; then _pass skip-key-vapoursynth; else _bad skip-key-vapoursynth "--skip-checksum=vapoursynth did not match recipes/other/vapoursynth.sh"; fi

  PKG_NAME="FreeType2"
  PKG_HASH_FILE="$ROOT/recipes/other/freetype2.hash"
  SKIP_CHECKSUM_PKGS="freetype2"
  if checksum_skipped; then _pass skip-key-freetype2; else _bad skip-key-freetype2 "--skip-checksum=freetype2 did not match recipes/other/freetype2.sh"; fi

  PKG_NAME="FreeType2-hb"
  PKG_HASH_FILE="$ROOT/recipes/other/freetype2-harfbuzz.hash"
  SKIP_CHECKSUM_PKGS="freetype2-harfbuzz"
  if checksum_skipped; then _pass skip-key-freetype2-harfbuzz; else _bad skip-key-freetype2-harfbuzz "--skip-checksum=freetype2-harfbuzz did not match recipes/other/freetype2-harfbuzz.sh"; fi

  # ...and the sibling must not be caught by the other's name, or the keys are
  # not distinct at all.
  PKG_HASH_FILE="$ROOT/recipes/other/freetype2.hash"
  SKIP_CHECKSUM_PKGS="freetype2-harfbuzz"
  if checksum_skipped; then _bad skip-key-freetype2-not-hb "freetype2-harfbuzz's name also skipped freetype2"; else _pass skip-key-freetype2-not-hb; fi
fi

# S-F2: opencl is the LAST recipe in _order.conf, so its PKG_NAME was the one
# still set when cmd_build sourced recipes/ffmpeg.sh. The FFmpeg tarball is the
# single most important artifact in the build; it must be skippable only by
# name.
if _require_fn checksum_skipped skip-key-opencl-does-not-cover-ffmpeg; then
  SKIP_CHECKSUM=false
  PKG_NAME=opencl
  PKG_HASH_FILE="$ROOT/recipes/ffmpeg.hash"
  SKIP_CHECKSUM_PKGS="opencl"
  if checksum_skipped; then
    _bad skip-key-opencl-does-not-cover-ffmpeg "--skip-checksum=opencl disabled verification of the FFmpeg tarball"
  else
    _pass skip-key-opencl-does-not-cover-ffmpeg
  fi

  SKIP_CHECKSUM_PKGS="ffmpeg"
  if checksum_skipped; then _pass skip-key-ffmpeg-by-name; else _bad skip-key-ffmpeg-by-name "--skip-checksum=ffmpeg did not match the FFmpeg tarball"; fi
fi

# S-F5: SKIP_CHECKSUM_PKGS accumulated with a leading space and the matcher
# wrapped it in spaces again, so the match window opened with a double space
# and an EMPTY key matched it -- every fetch under any --skip-checksum=NAME was
# skipped whenever the key was empty. Both halves are asserted: an empty key
# must not match, and the list must not carry the stray leading space that made
# it possible.
if _require_fn checksum_skipped skip-key-empty-never-matches; then
  SKIP_CHECKSUM=false
  PKG_NAME=""
  PKG_HASH_FILE=""
  # The leading space is not incidental: it is exactly what the accumulating
  # parser produced ("$SKIP_CHECKSUM_PKGS $names" starting from ""), and the
  # matcher then wrapped the value in spaces again, so the window opened with
  # "  " and an empty key was a substring of it. A list written without the
  # leading space does not reproduce the defect at all.
  SKIP_CHECKSUM_PKGS=" zlib giflib"
  if checksum_skipped; then
    _bad skip-key-empty-never-matches "an empty key matched a populated skip list"
  else
    _pass skip-key-empty-never-matches
  fi
fi

# The parser's own half of S-F5, asserted where the list is built rather than
# where it is read: two accumulating flags must produce a single-space-joined
# list with no leading space.
_normout=$(cd "$ROOT" && ./mediaforge.sh build --dry-run --yes \
  --skip-checksum=zlib,giflib --skip-checksum=opus 2>&1 \
  | grep 'Named recipes:' | head -1)
if [ "${_normout##*Named recipes: }" = "zlib giflib opus" ]; then
  _pass skip-checksum-list-is-normalized
else
  _bad skip-checksum-list-is-normalized "banner line was: [$_normout]"
fi

# Same class as the empty-key match, and it reaches the same place: a separator
# the parser does not normalize but the SHELL does. The parser collapsed commas
# and spaces only, while validate_pkg_names word-splits on $IFS -- which
# includes tab and newline -- so a tab-separated pair validated cleanly, both
# names were reported skipped in the banner, and neither ever matched: the
# lookup wraps the list in spaces and searches for " name ", a window a tab
# never opens. Validates-but-never-matches is the worst shape for a
# verification bypass, because the user is told the bypass happened.
#
# Asserted through the CLI on exact equality, not on the names being present:
# the pre-fix banner CONTAINS both names, so a substring check passes on the
# defect. The tab is built with printf rather than written literally, since an
# editor or a stray reformat would turn a literal one back into spaces and the
# test would silently stop being about anything.
_tab=$(printf '\t')
_wsout=$(cd "$ROOT" && ./mediaforge.sh build --dry-run --yes \
  "--skip-checksum=zlib,${_tab}giflib" 2>&1 \
  | grep 'Named recipes:' | head -1)
if [ "${_wsout##*Named recipes: }" = "zlib giflib" ]; then
  _pass skip-checksum-normalizes-non-space-whitespace
else
  _bad skip-checksum-normalizes-non-space-whitespace "a tab survived into the skip list; banner line was: [$_wsout]"
fi

# S-F7: an empty value arms the banner with nothing after "Named recipes:" and
# is the shortest route to the empty-key match above.
_emptyout=$(cd "$ROOT" && ./mediaforge.sh build --dry-run --yes --skip-checksum= 2>&1)
_emptyrc=$?
# Matched on the specific rejection wording, not on the flag text: the baseline
# also dies here, with "Unknown option: --skip-checksum=", which contains the
# flag as a substring and would false-PASS.
if [ "$_emptyrc" -ne 0 ] && printf '%s' "$_emptyout" | grep -qF 'requires at least one recipe name'; then
  _pass skip-checksum-empty-value-dies
else
  _bad skip-checksum-empty-value-dies "rc=$_emptyrc, output: $_emptyout"
fi

# That every recipe's key is a name the CLI accepts is asserted in
# tests/recipe-identity.sh, which owns recipe_key. It arrived here because
# --skip-checksum was the first caller; it is a property of the identity
# function, not of checksum skipping, and a reader looking for it should find
# it beside the rest of the identity contract.

PKG_NAME=""
PKG_HASH_FILE=""
SKIP_CHECKSUM=false
SKIP_CHECKSUM_PKGS=""

# recipes/ffmpeg.sh inherits every unreset global from the last recipe the
# build ran, which is how it ended up reporting opencl's PKG_NAME. Setting its
# own is wrong to omit independently of what the skip list keys on.
if grep -q '^PKG_NAME="ffmpeg"' "$ROOT/recipes/ffmpeg.sh"; then
  _pass ffmpeg-recipe-sets-its-own-pkg-name
else
  _bad ffmpeg-recipe-sets-its-own-pkg-name "recipes/ffmpeg.sh does not set PKG_NAME"
fi

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
# the ALL-recipes banner line. This shells out to the real script under
# --dry-run, the same idiom tests/dry-run-matrix.sh uses, because cmd_build
# isn't a function this file can call in-process without running a build.
#
# The comma-and-repeat half is asserted by skip-checksum-list-is-normalized
# above, which runs the identical command and compares the banner's name list
# for EXACT equality. A per-name grep here would be a strict subset of that
# comparison -- a second full dry-run subprocess measuring one property already
# measured more strictly -- so only the bare-flag banner, which that assertion
# does not reach, is exercised below.
#
# What both match on is the "Named recipes:" banner LINE, not the names
# appearing anywhere in the output: --dry-run emits "Would build zlib-1.3.1"
# for every recipe regardless of the banner, so a whole-output grep for `zlib`
# passed on any tree that parses the flag at all and was measuring nothing.
_cliout2=$(cd "$ROOT" && ./mediaforge.sh build --dry-run --yes --skip-checksum 2>&1)
if printf '%s' "$_cliout2" | grep -qi 'ALL recipes'; then
  _pass skip-checksum-cli-global-banner
else
  _bad skip-checksum-cli-global-banner "no ALL-recipes banner line: $_cliout2"
fi

# -- --skip-checksum=PKG validates against the recipe registry (review) ------
# cmd_build folds SKIP_CHECKSUM_PKGS into validate_pkg_names (lib/registry.sh),
# the same check DISABLE_PKGS/ENABLE_PKGS go through -- a typo must die loudly
# rather than silently never skip (silently never-skip would still be safe,
# but a fail-fast, clearly-worded typo report is the better failure mode, and
# it's the one --disable=/--enable= already give).
#
# Matched on the specific "Unknown package:" wording the registry-validation
# loop uses, NOT merely on "doesnotexist" appearing in the output: a
# pre-Task-9 tree also dies here, with "Unknown option: --skip-checksum=
# doesnotexist" -- which contains the literal substring "doesnotexist" too,
# so a filename-only match would false-PASS on the base exactly like
# skip-checksum-warns-filename's die-message trap above. "Unknown package:"
# only appears once this task's registry-validation loop exists.
_cliout3=$(cd "$ROOT" && ./mediaforge.sh build --dry-run --yes --skip-checksum=doesnotexist 2>&1)
_clirc3=$?
if [ "$_clirc3" -ne 0 ] && printf '%s' "$_cliout3" | grep -qF 'Unknown package: doesnotexist'; then
  _pass skip-checksum-unknown-pkg-dies
else
  _bad skip-checksum-unknown-pkg-dies "rc=$_clirc3, output: $_cliout3"
fi

# -- --skip-checksum's keying survives a nested fetch() (review) -------------
# lv2's pkg_install() calls fetch() seven times for its sub-tarballs without
# ever reassigning PKG_HASH_FILE -- checksum_skipped() rereads it fresh on
# every call, so the same shell-state mechanism fetch()'s own comment already
# relies on for the sidecar path also keys the skip decision. Nothing enforces
# "a recipe never reassigns PKG_HASH_FILE inside pkg_install()" -- the
# framework derives it and no recipe sets it, but that is a convention this
# suite checks elsewhere, not a type -- so this pins it as a regression guard.
# Hermetic: two local tar.gz fixtures fetched via file://, no network, and the
# sidecar path does not exist (so a call that reaches verify_file at all is
# unambiguous: it dies on the missing hash file).
_nestedsrc="$_fx/nestedsrc"; mkdir -p "$_nestedsrc"
printf 'nested-a' > "$_nestedsrc/a.txt"
printf 'nested-b' > "$_nestedsrc/b.txt"
_nesteddist="$_fx/nesteddist"; mkdir -p "$_nesteddist"
( cd "$_nestedsrc" && tar -czf "$_nesteddist/nested-a.tar.gz" a.txt )
( cd "$_nestedsrc" && tar -czf "$_nesteddist/nested-b.tar.gz" b.txt )
DISTDIR="$_nesteddist"
SKIP_CHECKSUM=false
SKIP_CHECKSUM_PKGS="nestedpkg"

if _require_fn checksum_skipped skip-checksum-nested-fetch-inherits-key; then
  PKG_HASH_FILE="$_fx/nested/nestedpkg.hash"
  if ( fetch "file://$_nesteddist/nested-a.tar.gz" nested-a.tar.gz nested-a-dir \
       && fetch "file://$_nesteddist/nested-b.tar.gz" nested-b.tar.gz nested-b-dir \
     ) >/dev/null 2>&1; then
    _pass skip-checksum-nested-fetch-inherits-key
  else
    _bad skip-checksum-nested-fetch-inherits-key "a second fetch() under the same unchanged PKG_HASH_FILE was not skipped"
  fi
fi

# Regression-guard companion, proving the assertion above is actually
# sensitive to the invariant it claims to protect (per review: a test that
# would pass either way tests nothing). Same fixture, but PKG_HASH_FILE is
# reassigned between the two fetch() calls, so the second file is keyed to a
# name absent from SKIP_CHECKSUM_PKGS: it must NOT be skipped, and must die on
# its missing hash file. If this could not fail, the assertion above would
# just be testing that two fetches under --skip-checksum=nestedpkg succeed,
# true for reasons unrelated to the keying.
if _require_fn checksum_skipped skip-checksum-nested-fetch-would-catch-key-reassignment; then
  PKG_HASH_FILE="$_fx/nested/nestedpkg.hash"
  if ( fetch "file://$_nesteddist/nested-a.tar.gz" nested-a2.tar.gz nested-a2-dir \
       && PKG_HASH_FILE="$_fx/nested/someotherpkg.hash" \
       && fetch "file://$_nesteddist/nested-b.tar.gz" nested-b2.tar.gz nested-b2-dir \
     ) >/dev/null 2>&1; then
    _bad skip-checksum-nested-fetch-would-catch-key-reassignment "reassigning PKG_HASH_FILE mid-pkg_install did not break the skip -- the guard above proves nothing"
  else
    _pass skip-checksum-nested-fetch-would-catch-key-reassignment
  fi
fi
SKIP_CHECKSUM_PKGS=""

# -- --skip-checksum is never persisted (Task 9, #19) -------------------------
# A security bypass that silently survives into a later build is worse than no
# bypass: the next build would skip verification with nothing on the command
# line to say so. Exercises save_stored_choices() directly with DRY_RUN unset
# (the brief's own --dry-run recipe never reaches the writer at all --
# save_stored_choices returns early under DRY_RUN -- so that shape asserts
# nothing and is not used here).
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

# -- MAKESUM_MODE is not settable from outside cmd_makesum (S-F3) ------------
# THE BUG THIS PINS. SKIP_CHECKSUM and SKIP_CHECKSUM_PKGS are initialized in
# mediaforge.sh's globals block, which neutralizes anything inherited from the
# environment. MAKESUM_MODE was not, and every consumer reads
# ${MAKESUM_MODE:-false} -- so `MAKESUM_MODE=true ./mediaforge.sh build`
# disabled verification for every fetch AND rewrote the sidecars, with no
# banner. Two assertions: the initialization exists, and a build that inherits
# the variable does not enter recording mode.
if grep -q '^MAKESUM_MODE=false' "$ROOT/mediaforge.sh"; then
  _pass makesum-mode-initialized-in-globals
else
  _bad makesum-mode-initialized-in-globals "mediaforge.sh has no MAKESUM_MODE=false in its globals block"
fi

# ANDed with a grep for the banner text in mediaforge.sh: "no recording banner
# was printed" is trivially true on a tree that has no such banner, so on its
# own this would pass on the baseline for a reason unrelated to the fix.
_envout=$(cd "$ROOT" && MAKESUM_MODE=true ./mediaforge.sh build --dry-run --yes 2>&1)
if grep -q 'recording is ACTIVE' "$ROOT/mediaforge.sh" \
   && ! printf '%s' "$_envout" | grep -q 'recording is ACTIVE'; then
  _pass makesum-mode-env-not-inherited
else
  _bad makesum-mode-env-not-inherited "an inherited MAKESUM_MODE=true put the build into recording mode, or no banner exists to tell"
fi

# The positive half: recording mode reached the legitimate way MUST announce
# itself, or the assertion above passes on any tree that simply has no banner.
_mkbanner=$(cd "$ROOT" && ./mediaforge.sh makesum --build --dry-run --yes 2>&1)
if printf '%s' "$_mkbanner" | grep -q 'recording is ACTIVE'; then
  _pass makesum-mode-announces-itself
else
  _bad makesum-mode-announces-itself "makesum --build printed no recording banner: $_mkbanner"
fi

# The second route into MAKESUM_MODE, and the worse one: load_stored_choices
# sourced $PREFIX/.mediaforge-choices wholesale, and $PREFIX is the workspace
# every dependency's `make install` writes into. A compromised build could drop
# any shell there -- including MAKESUM_MODE=true, disabling verification for
# every LATER build. Parsed by name now, so a setting nobody asked for cannot
# arrive at all; asserted with two payloads so the oracle is the allowlist and
# not one variable's name.
if _require_fn load_stored_choices stored-choices-not-sourced; then
  _evildir="$_fx/evil-prefix"; mkdir -p "$_evildir"
  cat > "$_evildir/.mediaforge-choices" <<'EOF'
STORED_TLS_BACKEND=openssl
MAKESUM_MODE=true
SKIP_CHECKSUM=true
EOF
  PREFIX="$_evildir"
  USE_MENU=false
  DRY_RUN=false
  MAKESUM_MODE=false
  SKIP_CHECKSUM=false
  TLS_BACKEND=""
  AAC_IMPL=""; H264_IMPL=""; H265_IMPL=""; AV1_ENC_IMPL=""; SPIRV_IMPL=""; OPENSSLDIR=""
  load_stored_choices
  if [ "$MAKESUM_MODE" = false ] && [ "$SKIP_CHECKSUM" = false ]; then
    _pass stored-choices-not-sourced
  else
    _bad stored-choices-not-sourced "the choices file set MAKESUM_MODE=$MAKESUM_MODE SKIP_CHECKSUM=$SKIP_CHECKSUM"
  fi
  # ...while the settings it IS allowed to carry must still arrive, or the fix
  # would be "ignore the file".
  # ANDed with a marker for the parser: sourcing the file applies the value
  # too, so the equality alone passes on the baseline for the wrong reason.
  # Anchored on the definition line -- a bare `_stored_choice` is a substring
  # of load_stored_choices and save_stored_choices, both of which the baseline
  # already has, so the unanchored marker matched there and this assertion
  # passed on the base until tests/oracle-baseline.sh caught it.
  if [ "$TLS_BACKEND" = openssl ] && grep -q '^_stored_choice()' "$ROOT/lib/resolve.sh"; then
    _pass stored-choices-allowlisted-value-applied
  else
    _bad stored-choices-allowlisted-value-applied "STORED_TLS_BACKEND did not reach TLS_BACKEND (got '$TLS_BACKEND')"
  fi
fi

# -- every network fetch goes through fetch() (S-F4) --------------------------
# The branch's stated invariant is that every fetched file is verified.
# recipes/video/vid_stab.sh reached past it with a raw `curl -L -sS` -- no -f,
# so an HTTP error-page body is written and fed straight to `patch -p1`, and no
# digest either. Enforced as a tree-wide property rather than fixed in one
# recipe and asserted about that recipe, because the next one to be written
# this way would not be caught by a vid_stab-shaped test.
#
# THE ORACLE IS WORD-LEVEL, and deliberately so. It splits each non-comment
# line on the characters that can precede a command word and asks whether any
# resulting word IS curl or wget. Three shapes it now catches that a plain
# `grep -w curl` or the first version of this scan did not:
#
#   `curl ...`            backticks are separators here, not text
#   $(curl ...)           so are '$' and '('
#   /usr/bin/curl ...     a leading-'/' or './' word is reduced to its basename
#
# The basename reduction is applied ONLY to words that begin with '/' or './',
# which is what an executable path looks like and what a URL does not: a token
# like "https://github.com/curl/curl-8.tar.gz" keeps its whole spelling and
# cannot be mistaken for an invocation.
#
# STILL NOT CAUGHT, stated rather than implied: a here-doc body piped into a
# shell, and a command word assembled at runtime ($CMD, ${TOOL}url). Both are
# several steps removed from anything in this tree and neither can be settled
# without a real parser; the honest claim is that this covers every shape a
# recipe has ever been written in here, not every shape shell permits.
_rawnet=$(awk '
  /^[[:space:]]*#/ { next }
  {
    _l = $0
    gsub(/[;&|()`$<>]/, " ", _l)
    _n = split(_l, _w, /[[:space:]]+/)
    for (_i = 1; _i <= _n; _i++) {
      _t = _w[_i]
      if (_t ~ /^\.?\//) sub(/^.*\//, "", _t)
      if (_t == "curl" || _t == "wget") {
        if (!seen[FILENAME]++) print FILENAME
        break
      }
    }
  }
' "$ROOT"/recipes/*.sh "$ROOT"/recipes/*/*.sh)
if [ -z "$_rawnet" ]; then
  _pass no-recipe-fetches-outside-fetch
else
  _bad no-recipe-fetches-outside-fetch "recipes invoking curl/wget directly: $_rawnet"
fi

# -- the nested-fetch set is derived, not counted in prose --------------------
# Four comments (mediaforge.sh's --build case, lib/download.sh's MAKESUM_MODE
# block, README.md, and this file) tell the reader which recipes fetch from
# inside a phase function, because that set is the whole reason `makesum
# --build` exists. Each used to state a COUNT as well, and the count was wrong
# twice: corrected from ten to nine, then made ten again by routing vid_stab's
# patch through fetch() in this very branch. A number no gate reads drifts on
# the next edit, so the number is gone from all four and the SET is derived
# here instead -- adding or removing a nested fetch() fails this assertion and
# points at the prose that has to change with it.
#
# Comment lines are excluded before the scan: recipes/hwaccel/libplacebo.sh and
# recipes/other/librtmp.sh both describe fetching in prose without calling
# fetch(), and counting them would make the oracle agree with a set that is not
# the code's.
_nestedset=$(awk '
  /^[[:space:]]*#/ { next }
  /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ { _in = 1 }
  _in && /^}/ { _in = 0 }
  _in && /(^|[ \t;&|(])fetch[ \t]/ {
    if (!seen[FILENAME]++) {
      _n = split(FILENAME, _p, "/"); _b = _p[_n]; sub(/\.sh$/, "", _b); print _b
    }
  }
' "$ROOT"/recipes/*.sh "$ROOT"/recipes/*/*.sh | sort | tr '\n' ' ')
_nestedset=${_nestedset% }
if [ "$_nestedset" = "libcdio lv2 opencl vid_stab" ]; then
  _pass nested-fetch-recipes-are-the-documented-set
else
  _bad nested-fetch-recipes-are-the-documented-set "recipes with a fetch() inside a phase function are now [$_nestedset]; update the prose in mediaforge.sh, lib/download.sh, README.md and this file to match"
fi

# ...and the file that used to be fetched that way now has a recorded digest,
# so routing it through fetch() actually buys verification rather than moving
# an unverified download one function deeper.
_vsp=$(awk -F'"' '/patch -p1 </ { _n = split($2, _p, "/"); print _p[_n]; exit }' \
  "$ROOT/recipes/video/vid_stab.sh")
if [ -n "$_vsp" ] && [ -f "$ROOT/recipes/video/vid_stab.hash" ] \
   && [ -n "$(hash_lookup "$ROOT/recipes/video/vid_stab.hash" "$_vsp" sha256)" ]; then
  _pass vid-stab-patch-digest-recorded
else
  _bad vid-stab-patch-digest-recorded "no sha256 record for '${_vsp:-<no patch filename found>}' in recipes/video/vid_stab.hash"
fi

# -- makesum --update summarizes every digest it re-pinned (S-F8) -------------
# `makesum --update` with no package filter re-pins every changed digest in one
# pass. Per-record warnings interleaved into a long log are not a reviewable
# set: the reader has to reconstruct which pins moved by scrolling. The final
# block is what makes the re-pin set auditable before it is committed.
if _require_fn makesum_update_summary makesum-update-summary-lists-names; then
  MAKESUM_UPDATED=""
  makesum_note_updated alpha.tar.gz
  makesum_note_updated beta.tar.gz
  _sumout=$( makesum_update_summary 2>&1 )
  if printf '%s' "$_sumout" | grep -q '2 digest' \
     && printf '%s' "$_sumout" | grep -q 'alpha.tar.gz' \
     && printf '%s' "$_sumout" | grep -q 'beta.tar.gz'; then
    _pass makesum-update-summary-lists-names
  else
    _bad makesum-update-summary-lists-names "summary did not name both updated files: $_sumout"
  fi

  # Nothing updated must print nothing, or the block becomes noise every run
  # and stops being read.
  MAKESUM_UPDATED=""
  _sumout=$( makesum_update_summary 2>&1 )
  if [ -z "$_sumout" ]; then
    _pass makesum-update-summary-silent-when-nothing-changed
  else
    _bad makesum-update-summary-silent-when-nothing-changed "printed a summary with no updates: $_sumout"
  fi

  # The names must come from hash_record_write itself, not from a caller that
  # has to remember to report them -- otherwise the summary drifts from what
  # was actually re-pinned.
  printf 'test' > "$_fx/sum-src.tar.gz"
  cat > "$_fx/sum.hash" <<EOF
sha256  $_H64_1  sum.tar.gz
size    11  sum.tar.gz
EOF
  MAKESUM_UPDATED=""
  MAKESUM_UPDATE=true
  hash_record_write "$_fx/sum.hash" sum.tar.gz "$_fx/sum-src.tar.gz" >/dev/null 2>&1
  MAKESUM_UPDATE=false
  case " $MAKESUM_UPDATED " in
    *" sum.tar.gz "*) _pass makesum-update-records-name-at-the-rewrite ;;
    *) _bad makesum-update-records-name-at-the-rewrite "hash_record_write rewrote a digest without noting it (MAKESUM_UPDATED='$MAKESUM_UPDATED')" ;;
  esac
fi

# -- registry validation lives in one place (CR-Important-2) ------------------
# cmd_build and cmd_makesum each carried a verbatim copy of the same
# validate-or-suggest loop; this branch created the second. Asserted through
# both CLI entry points rather than by grepping for the helper's name, so the
# claim is that both actually validate, not that a function exists.
if _require_fn validate_pkg_names validate-pkg-names-shared; then
  _vpn_build=$(cd "$ROOT" && ./mediaforge.sh build --dry-run --yes --disable=doesnotexist 2>&1 || true)
  _vpn_ms=$(cd "$ROOT" && ./mediaforge.sh makesum doesnotexist 2>&1 || true)
  if printf '%s' "$_vpn_build" | grep -qF 'Unknown package: doesnotexist' \
     && printf '%s' "$_vpn_ms" | grep -qF 'Unknown package: doesnotexist'; then
    _pass validate-pkg-names-shared
  else
    _bad validate-pkg-names-shared "build: [$_vpn_build] makesum: [$_vpn_ms]"
  fi
fi

# -- every sidecar in the TREE parses, not just the fixtures ------------------
# hash_file_validate is exercised above against fixtures built here. Nothing
# checked the ~107 real sidecars, so a hand-edit to one -- adding a digest,
# rewriting a provenance comment -- could ship a malformed record and only
# surface at build time as a MISMATCH, which reads as tampering rather than as
# the two-character typo it is. Cheap enough to run over the whole tree.
#
# Floored, for the same reason tests/upstream-provenance.sh floors its claim
# count: if the globs match nothing -- a directory rename, a partial checkout --
# the loop body never runs and this would report PASS having validated zero
# files. The tree carries 107 sidecars; 90 leaves room for recipes to come and
# go without ever being satisfiable by an empty glob.
_MIN_SIDECARS=90
if _require_fn hash_file_validate sidecars-in-tree-validate; then
  _tv_ok=true
  _tv_n=0
  for _tv in "$ROOT"/recipes/*/*.hash "$ROOT"/recipes/*.hash; do
    [ -f "$_tv" ] || continue
    _tv_n=$((_tv_n + 1))
    # Subshell: hash_file_validate dies on a defect, and die exits the shell.
    if ! ( hash_file_validate "$_tv" ) >/dev/null 2>&1; then
      _tv_ok=false
      _bad sidecars-in-tree-validate "${_tv#"$ROOT"/} does not validate"
    fi
  done
  if [ "$_tv_n" -lt "$_MIN_SIDECARS" ]; then
    _bad sidecars-in-tree-validate "only $_tv_n sidecar(s) found, want >= $_MIN_SIDECARS"
  elif [ "$_tv_ok" = true ]; then
    _pass sidecars-in-tree-validate
  fi
fi

printf 'DONE:\n'
exit "$_fail"
