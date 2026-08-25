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

printf 'DONE:\n'
exit "$_fail"
