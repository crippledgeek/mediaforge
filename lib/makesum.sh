#!/bin/sh
# makesum: record digests for fetched files.
#
# Regenerating by hand is not supported. This mirrors `make makesum`,
# `updpkgsums`, `abuild checksum`, `pkgdev manifest` and `spack checksum`.
# Buildroot deliberately ships no equivalent -- see the design spec for that
# counter-argument and why it is answered differently here.

# makesum_needs_fetch HASHFILE FILENAME FILEPATH
# Return 0 (needs fetching) unless FILENAME already has a recorded sha256 in
# HASHFILE AND the bytes at FILEPATH still match it.
#
# Deliberately not a plain `[ -f FILEPATH ]` cache check. makesum's output
# BECOMES the pin -- an unconditional skip would mint a pin from a cache
# entry of unknown age (a months-old truncated tarball recorded as
# canonical), and every later build would then verify happily against the
# corrupt bytes. That is the exact failure #19 exists to close, arriving
# through the tool meant to prevent it. Only a cache entry that already
# matches an attested digest is safe to skip; a missing record, a missing
# file, or a mismatch all mean the bytes are unverified and must be
# re-fetched before they can be hashed. Composed entirely from the existing
# hash_lookup/digest_file primitives -- no new comparison logic.
makesum_needs_fetch() {
  _mnf_file="$1"
  _mnf_name="$2"
  _mnf_path="$3"

  [ -f "$_mnf_file" ] || return 0
  _mnf_recorded=$(hash_lookup "$_mnf_file" "$_mnf_name" sha256)
  [ -n "$_mnf_recorded" ] || return 0
  [ -f "$_mnf_path" ] || return 0
  # Captured before it is compared, because a die() inside `$(...)` ends only the
  # substitution: an unchecked comparison would read a broken hashing tool as
  # "the cached bytes do not match" and silently re-download instead of saying so.
  _mnf_got=$(digest_file sha256 "$_mnf_path") || die "makesum: cannot hash $_mnf_path to decide whether the cache is attested"
  [ "$_mnf_got" = "$_mnf_recorded" ] && return 1
  return 0
}

# hash_record_write HASHFILE FILENAME FILEPATH
# Compute FILEPATH's sha256 and size, and merge both records into HASHFILE.
#
# Three parameters, not five: provenance and update-mode arrive via the
# MAKESUM_PROVENANCE and MAKESUM_UPDATE globals rather than as positional
# arguments, because a fourth/fifth positional parameter would blow the ≤3
# ceiling in ~/.claude/rules/limit-function-arguments.md and POSIX sh has no
# parameter object to group them into.
#
# Merges, never truncates: one hash file holds every version the recipe resolves
# to across all four profiles, so a run for one profile must leave the others
# intact. Existing records keep their position and their provenance comments, and
# new blocks are appended, so diffs stay small.
#
# An existing record whose value differs is reported and left alone unless
# MAKESUM_UPDATE is true.
hash_record_write() {
  _hw_file="$1"
  _hw_name="$2"
  _hw_path="$3"
  _hw_prov="${MAKESUM_PROVENANCE:-Locally calculated}"

  case "$_hw_name" in
    *[[:space:]]*) die "makesum: filename '$_hw_name' contains whitespace, which the 3-field record grammar cannot represent" ;;
  esac

  [ -f "$_hw_file" ] || : > "$_hw_file"

  # `|| die` on both, and this is the site that matters most in the tree: a
  # digest that came back empty because the hashing tool failed used to be
  # written straight into the sidecar, and an empty sha256 record makes
  # hash_lookup return nothing, which makes verify_file's
  # `[ -n "$_want" ] || continue` skip that algorithm on every later build. A
  # loud failure here costs a re-run; a quiet one costs the verification.
  _hw_sha=$(digest_file sha256 "$_hw_path") || die "makesum: cannot hash $_hw_path -- refusing to record $_hw_name"
  _hw_size=$(file_size "$_hw_path") || die "makesum: cannot size $_hw_path -- refusing to record $_hw_name"
  _hw_old=$(hash_lookup "$_hw_file" "$_hw_name" sha256)

  if [ -z "$_hw_old" ]; then
    {
      printf '\n# %s\n' "$_hw_prov"
      printf 'sha256  %s  %s\n' "$_hw_sha" "$_hw_name"
      printf 'size    %s  %s\n' "$_hw_size" "$_hw_name"
    } >> "$_hw_file"
    log "makesum: recorded $_hw_name"
    return 0
  fi

  if [ "$_hw_old" = "$_hw_sha" ]; then
    return 0
  fi

  if [ "${MAKESUM_UPDATE:-false}" != true ]; then
    warn "makesum: $_hw_name digest differs from the recorded one and was NOT changed."
    warn "  recorded: $_hw_old"
    warn "  computed: $_hw_sha"
    warn "  Re-run with --update if this change is expected."
    return 0
  fi

  # A hand-edited or externally-authored sidecar could carry a sha256 record
  # with no matching size record (hash_record_write itself never produces
  # that shape, but nothing stops one arriving as input). size is mandatory
  # per hash_file_validate, so track whether we actually rewrote one and
  # synthesize it at EOF if not -- otherwise the digest gets updated and the
  # file is left invalid with no warning.
  _hw_had_size=$(hash_lookup "$_hw_file" "$_hw_name" size)

  # Rewrite in place, preserving position and the provenance comment above it.
  # Through mf_awk_rewrite (lib/utils.sh) because the unguarded form here dropped
  # both statuses: a failed awk left the sidecar untouched and the warnings below
  # still announced an update that had not happened (GH-85).
  #
  # $1 and $3 are awk's FIELD variables, so the single quotes are the point and
  # expanding them would be the bug. The linter could see that this was an awk
  # program while awk was called inline here and cannot once the program is an
  # argument to a shell function -- the one thing the extraction costs, and the
  # same false positive lib/framework.sh's mf_pc_add_stdcxx already carries for
  # `$0` at the twin call site.
  # shellcheck disable=SC2016
  mf_awk_rewrite "$_hw_file" '
    NF == 3 && $1 == "sha256" && $3 == want { printf("sha256  %s  %s\n", sha, want); next }
    NF == 3 && $1 == "size"   && $3 == want { printf("size    %s  %s\n", sz,  want); saw_size=1; next }
    { print }
    END { if (!saw_size) printf("size    %s  %s\n", sz, want) }
  ' -v want="$_hw_name" -v sha="$_hw_sha" -v sz="$_hw_size"

  makesum_note_updated "$_hw_name"
  warn "makesum: UPDATED $_hw_name ($_hw_old -> $_hw_sha)"
  warn "  If that block's provenance comment names an upstream digest URL, confirm upstream really republished."
  if [ -z "$_hw_had_size" ]; then
    warn "makesum: $_hw_name had no size record -- synthesized one ($_hw_size) so the sidecar stays valid (size is mandatory)."
  fi
}

# makesum_note_updated FILENAME / makesum_update_summary
# Accumulate the names --update actually re-pinned, and print them as one
# block at the end of the run.
#
# `makesum --update` with no package filter walks ~107 recipes and can re-pin
# any number of them; the per-record warnings are then scattered through a long
# log and exit 0, so the set of digests that moved is something the reader has
# to reconstruct by scrolling. Re-pinning a digest is the one makesum action
# that can turn tampered bytes into a committed pin, so that set is exactly
# what must be reviewable before the diff is committed.
#
# Noted where the rewrite happens (hash_record_write) rather than by each
# caller, so the summary cannot report a different set from the one written.
makesum_note_updated() {
  MAKESUM_UPDATED="${MAKESUM_UPDATED:-} $1"
}

makesum_update_summary() {
  [ -n "${MAKESUM_UPDATED:-}" ] || return 0
  _mus_n=0
  for _mus in $MAKESUM_UPDATED; do
    _mus_n=$((_mus_n + 1))
  done
  warn "================================================================"
  warn "$_mus_n digest(s) UPDATED by --update:"
  for _mus in $MAKESUM_UPDATED; do
    warn "  $_mus"
  done
  warn "  Confirm upstream really republished each of these before committing."
  warn "================================================================"
}

# makesum_fetch_and_record HASHFILE FILENAME URL
# Fetch FILENAME into DISTDIR only if makesum_needs_fetch says the cached
# bytes aren't already attested, then record its digest into HASHFILE.
#
# Extracted from cmd_makesum's per-recipe loop (mediaforge.sh) so FFmpeg's own
# tarball -- sourced directly by cmd_build rather than listed in
# recipes/_order.conf, so the loop never reaches it -- can be recorded through
# the exact same fetch-or-skip-then-record mechanism instead of a second copy
# that could drift from it.
makesum_fetch_and_record() {
  _mfr_hash="$1"
  _mfr_name="$2"
  _mfr_url="$3"
  _mfr_dest="$DISTDIR/$_mfr_name"

  if makesum_needs_fetch "$_mfr_hash" "$_mfr_name" "$_mfr_dest"; then
    download_file "$_mfr_url" "$_mfr_dest"
  else
    log "makesum: $_mfr_name already matches its recorded digest, skipping download"
  fi

  MAKESUM_PROVENANCE="Locally calculated $(date +%Y-%m-%d)"
  hash_record_write "$_mfr_hash" "$_mfr_name" "$_mfr_dest"
}
