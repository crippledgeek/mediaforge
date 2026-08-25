#!/bin/sh
# makesum: record digests for fetched files.
#
# Regenerating by hand is not supported. This mirrors `make makesum`,
# `updpkgsums`, `abuild checksum`, `pkgdev manifest` and `spack checksum`.
# Buildroot deliberately ships no equivalent -- see the design spec for that
# counter-argument and why it is answered differently here.

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

  _hw_sha=$(digest_file sha256 "$_hw_path")
  _hw_size=$(file_size "$_hw_path")
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

  # Rewrite in place, preserving position and the provenance comment above it.
  awk -v want="$_hw_name" -v sha="$_hw_sha" -v sz="$_hw_size" '
    NF == 3 && $1 == "sha256" && $3 == want { printf("sha256  %s  %s\n", sha, want); next }
    NF == 3 && $1 == "size"   && $3 == want { printf("size    %s  %s\n", sz,  want); next }
    { print }
  ' "$_hw_file" > "$_hw_file.tmp" && mv "$_hw_file.tmp" "$_hw_file"

  warn "makesum: UPDATED $_hw_name ($_hw_old -> $_hw_sha)"
  warn "  If that block's provenance comment names an upstream digest URL, confirm upstream really republished."
}
