#!/bin/sh
# Download and extract helpers

# digest_file ALGO FILE
# Print FILE's lowercase hex digest. ALGO is sha256, sha512 or sha1.
#
# Backends are fed the file on STDIN, not by path, for two reasons: a path makes
# the filename appear in the output, and `openssl dgst` labels the stream
# differently across versions -- `SHA2-256(stdin)=` on OpenSSL 3.x versus
# `SHA256(stdin)=` on LibreSSL and OpenSSL 1.1.x. Taking the last whitespace
# field is correct for all three.
#
# macOS does not ship sha256sum; it ships shasum (a Perl Digest::SHA front end).
# The fallback chain is what makes this work there, not a convenience.
digest_file() {
  _algo="$1"
  _dfile="$2"

  case "$_algo" in
    sha256|sha512|sha1) ;;
    *) die "digest_file: unsupported algorithm '$_algo' (sha256, sha512, sha1 only)" ;;
  esac

  if command_exists "${_algo}sum"; then
    "${_algo}sum" < "$_dfile" | awk '{print $1}'
  elif command_exists shasum; then
    shasum -a "${_algo#sha}" < "$_dfile" | awk '{print $1}'
  elif command_exists openssl; then
    openssl dgst "-$_algo" < "$_dfile" | awk '{print $NF}'
  else
    die "No digest backend found. Install coreutils (${_algo}sum), perl (shasum), or openssl."
  fi
}

# file_size FILE
# Print FILE's size in bytes. POSIX specifies `wc -c` as the byte count and
# specifies that no pathname is written when reading standard input, so this
# avoids the GNU `stat -c %s` versus BSD `stat -f %z` split entirely.
file_size() {
  wc -c < "$1" | tr -d ' '
}

# HASH_COMMENT_RE -- how much of a line is the comment marker, for the `.hash`
# sidecars this file parses and for `keys/INDEX`, which tests/signing-keys.sh
# reads with the same grammar.
#
# Defined ONCE, here, because the two consumers below and three test files --
# tests/lib-provenance.sh, tests/upstream-provenance.sh and
# tests/signing-keys.sh -- all ask the same question of the same KIND of line.
# It was written out three times before this constant existed, and #44 converged
# only the test side; the two copies that survived were the production ones, in
# the functions tests/checksum-verification.sh exercises.
#
# The pin grammar that reads the REST of such a comment -- `# with key <fpr>` --
# lives in tests/lib-provenance.sh, which sources this file for the marker. It
# stays there because nothing in a build asks which keys the tree pins; only the
# tests do. Splitting on that line keeps each half in the file that consumes it.
#
# The pattern contains NO BACKSLASH, and must not grow one. Consumers receive it
# through awk's `-v`, which performs escape processing on the assigned value,
# while `sed` does not: `^\t*#` would reach awk as a literal tab and sed as
# backslash-t. A widening using \t, \. or \\ would therefore reach the two kinds
# of consumer DIFFERENTLY -- the silent divergence this constant exists to
# prevent, arriving through the mechanism meant to prevent it. Character classes
# express everything needed here without one.
# No `${VAR:?}` guard at the consumers, deliberately. The constant is assigned
# unconditionally in the same file that reads it, so no reachable path leaves it
# empty -- colocation is the guarantee, which is why it was moved here rather
# than into a constants file nobody remembers to source. A per-call guard would
# also be worse than useless in hash_lookup: every call site is a command
# substitution, so `${VAR:?}` would exit only the subshell and hand the caller
# the empty digest it was meant to prevent.
HASH_COMMENT_RE='^[[:space:]]*#[[:space:]]*'

# hash_file_validate HASHFILE
# Die unless every record in HASHFILE is well formed. A parser that skipped a
# line it could not read would silently skip a digest, so every defect is
# fatal: wrong field count, unknown keyword, non-hex digest, non-numeric size,
# or a duplicated (keyword, filename) pair.
#
# Grammar: `<keyword>  <value>  <filename>`, blanks-separated. `#` comments and
# blank lines are ignored. md5/sha224/sha384 are deliberately absent -- a
# divergence from Buildroot's check-hash, which accepts md5 but undocuments
# it; keeping a weak-hash code path out of the tree entirely is the point.
hash_file_validate() {
  _hf="$1"
  _err=$(awk -v CMT="$HASH_COMMENT_RE" '
    $0 ~ CMT { next }
    /^[[:space:]]*$/ { next }
    {
      if (NF != 3) { printf("line %d: expected 3 fields, got %d\n", NR, NF); next }
      k = $1; v = $2; f = $3
      if (k == "size") {
        if (v !~ /^[0-9]+$/) { printf("line %d: size %s is not a decimal count\n", NR, v); next }
      } else if (k == "sha256" || k == "sha512" || k == "sha1") {
        if (v !~ /^[0-9a-f]+$/) { printf("line %d: %s value %s is not lowercase hex\n", NR, k, v); next }
        # A short or over-long digest is a malformed sidecar, and saying so
        # here is the point: without this it parses as well formed and only
        # surfaces at verify_file as a digest MISMATCH, which reads as
        # tampering and sends the reader hunting a compromised mirror for a
        # defect that is two characters in a text file.
        want = (k == "sha256" ? 64 : (k == "sha512" ? 128 : 40))
        if (length(v) != want) {
          printf("line %d: %s value is %d hex characters, expected %d\n", NR, k, length(v), want)
          next
        }
      } else {
        printf("line %d: unknown keyword %s\n", NR, k)
        next
      }
      if (seen[k SUBSEP f]++) { printf("line %d: duplicate %s record for %s\n", NR, k, f) }
    }
  ' "$_hf")

  if [ -n "$_err" ]; then
    die "Malformed hash file $_hf:
$_err"
  fi
}

# hash_lookup HASHFILE FILENAME KEYWORD
# Print the recorded value for that (filename, keyword) pair, or nothing.
hash_lookup() {
  awk -v want="$2" -v key="$3" -v CMT="$HASH_COMMENT_RE" '
    $0 ~ CMT { next }
    /^[[:space:]]*$/ { next }
    NF == 3 && $1 == key && $3 == want { print $2; exit }
  ' "$1"
}

# fetch_git URL DEST COMMIT
# Obtain a source tree at exactly COMMIT, for packages with no usable release
# tarball: recipes/other/librtmp.sh, recipes/hwaccel/libplacebo.sh, and
# recipes/video/av1.sh (whose gitiles archive is regenerated per request).
#
# Pinned by commit rather than by tag on purpose. A git tag is a MUTABLE
# server-side pointer: whoever controls the remote can retarget it, and every
# later build silently compiles different source. A commit name is the hash of
# the commit's content, so git itself rejects a substituted tree. That is the
# integrity guarantee no tarball digest can give these recipes.
#
# An existing DEST is reused only when it is already AT that commit. Merely
# existing is not evidence of its contents, which is the same reason fetch()'s
# unconditional cache reuse is worth distrusting (see #19).
fetch_git() {
  _url="$1"
  _dest="$2"
  _commit="$3"

  # Reject anything that is not a full object name before it reaches git, so a
  # tag or an abbreviated SHA fails here with an explanation rather than as a
  # confusing refspec error. `v2.6` reaching this function is the #28 bug.
  _notchex=$(printf '%s' "$_commit" | tr -d '0-9a-f')
  if [ "${#_commit}" -ne 40 ] || [ -n "$_notchex" ]; then
    die "fetch_git: '$_commit' is not a 40-character commit SHA. Pin a commit, not a tag or branch — a tag is mutable server-side and authenticates nothing."
  fi

  if [ -d "$_dest/.git" ]; then
    _have=$(git -C "$_dest" rev-parse HEAD 2>/dev/null || printf '')
    if [ "$_have" = "$_commit" ]; then
      log "$_dest already at $_commit"
      return 0
    fi
    warn "$_dest is at ${_have:-an unreadable HEAD}, wanted $_commit — re-fetching"
    rm -rf "${_dest:?}"
  elif [ -e "$_dest" ] || [ -L "$_dest" ]; then
    # Exists but is not a clone. This is the tarball-to-git conversion case: a recipe
    # that used to `fetch` an archive left its extracted tree here, and every
    # workspace that ever built it still has one. `git init` over that debris
    # succeeds, and the checkout below then aborts on every file the archive and
    # the commit share ("untracked working tree files would be overwritten").
    warn "$_dest exists but is not a git clone, replacing it"
    rm -rf "${_dest:?}"
  fi

  log "Fetching $_url at $_commit"
  mkdir -p "$_dest" || die "Failed to create $_dest"
  run git -C "$_dest" init -q
  run git -C "$_dest" remote add origin "$_url"
  # --depth 1 on the commit itself: no history is needed, and the SHA is the
  # thing being verified, so a shallow fetch loses nothing here.
  run git -C "$_dest" fetch -q --depth 1 origin "$_commit"
  run git -C "$_dest" checkout -q FETCH_HEAD

  # Belt-and-braces: confirm what actually landed. A remote that served a
  # different object would have failed git's own check, so this catches local
  # accidents (an interrupted checkout) rather than a hostile remote.
  _got=$(git -C "$_dest" rev-parse HEAD 2>/dev/null || printf '')
  if [ "$_got" != "$_commit" ]; then
    die "fetch_git: $_dest is at ${_got:-no commit} after checkout, expected $_commit"
  fi
}

# download_file URL DEST
# Fetch URL to DEST with bounded exponential backoff. Dies after 3 attempts,
# leaving no partial file behind -- `curl -f` exits non-zero on HTTP >= 400 so
# an error-page body is never mistaken for an archive (tests/fetch-fail-no-cache.sh).
download_file() {
  _dl_url="$1"
  _dl_dest="$2"

  log "Downloading $_dl_url"
  _retry_wait=1
  _attempts=0
  while [ "$_attempts" -lt 3 ]; do
    if curl -fL -sS -o "$_dl_dest" "$_dl_url"; then
      log "Download complete"
      return 0
    fi
    rm -f "$_dl_dest"
    _attempts=$((_attempts + 1))
    if [ "$_attempts" -lt 3 ]; then
      warn "Download failed. Retrying in ${_retry_wait}s..."
      sleep "$_retry_wait"
      _retry_wait=$((_retry_wait * 2))
    fi
  done
  die "Failed to download $_dl_url after 3 attempts"
}

# verify_file FILE BASENAME
# Check FILE against the current recipe's hash file.
#
# Returns 0 verified, 2 mismatch, 3 no usable record. Dies when the hash file is
# missing or malformed. The 0/2/3 split mirrors Buildroot's check-hash exit
# codes, because the caller must treat a mismatch (delete and retry) differently
# from a missing record (keep the file -- the metadata is the likely defect).
#
# Size is checked first: it is cheap and catches truncation and wrong-file
# before any hashing.
verify_file() {
  _vfile="$1"
  _vname="$2"

  [ -n "${PKG_HASH_FILE:-}" ] || die "verify_file: PKG_HASH_FILE is unset for $_vname"
  [ -f "$PKG_HASH_FILE" ] || die "No hash file $PKG_HASH_FILE for $_vname.
Run './mediaforge.sh makesum' to record it, or --skip-checksum to bypass (loudly)."

  hash_file_validate "$PKG_HASH_FILE"

  _vsize=$(hash_lookup "$PKG_HASH_FILE" "$_vname" size)
  _vsha=$(hash_lookup "$PKG_HASH_FILE" "$_vname" sha256)

  if [ -z "$_vsha" ] || [ -z "$_vsize" ]; then
    warn "No complete record for $_vname in $PKG_HASH_FILE (sha256 and size are both required)"
    return 3
  fi

  _got=$(file_size "$_vfile")
  if [ "$_got" != "$_vsize" ]; then
    warn "$_vname has the wrong size: expected $_vsize bytes, got $_got"
    return 2
  fi

  # Recorded, not assumed: sha512/sha1 are optional records, so a build that
  # never had one to check must not claim it did, and one that did check it
  # must say so -- otherwise a silently-absent sha512 and a checked-and-passed
  # sha512 log identically.
  _vchecked=size
  for _alg in sha256 sha512 sha1; do
    _want=$(hash_lookup "$PKG_HASH_FILE" "$_vname" "$_alg")
    [ -n "$_want" ] || continue
    _got=$(digest_file "$_alg" "$_vfile")
    if [ "$_got" != "$_want" ]; then
      warn "$_vname has the wrong $_alg digest:"
      warn "  expected: $_want"
      warn "  got     : $_got"
      warn "  Incomplete download, or a man-in-the-middle attack."
      return 2
    fi
    _vchecked="$_vchecked, $_alg"
  done

  log "$_vname: verified ($_vchecked)"
  return 0
}

# ffmpeg_tarball_filename / ffmpeg_tarball_url
# The canonical GitHub tag-archive name and URL for $FFMPEG_VERSION.
#
# Shared by recipes/ffmpeg.sh's fetch() call and mediaforge.sh's cmd_makesum,
# so the two can never end up naming a different file for the same version.
# FFmpeg is sourced directly by cmd_build rather than through _order.conf, so
# without this cmd_makesum had no way at all to reach it: `makesum --profile=X`
# recorded every other recipe and silently skipped FFmpeg, and the only path
# that could record it (`makesum --build`) needs the whole dependency chain
# built first -- making verify_file's own "run makesum to record it" message
# unfollowable for the one file every profile but 8.0.1 actually needed it for.
ffmpeg_tarball_filename() {
  printf 'FFmpeg-release-%s.tar.gz' "$FFMPEG_VERSION"
}

ffmpeg_tarball_url() {
  printf 'https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n%s.tar.gz' "$FFMPEG_VERSION"
}

# ffmpeg_hash_file
# The sidecar recipes/ffmpeg.sh verifies against and cmd_makesum records into.
# Third of the trio above, and here for the same reason: the path was written
# out at both call sites, so the two could name different files.
ffmpeg_hash_file() {
  printf '%s/recipes/ffmpeg.hash' "$SCRIPT_DIR"
}

# checksum_skipped
# True when verification is disabled for the current recipe.
#
# Buildroot's BR_NO_CHECK_HASH_FOR keys by file basename. We key by recipe
# name instead: it is what a user has on the command line, and it covers that
# recipe's sub-build downloads without them knowing the sub-tarball names
# (lv2's seven, for instance).
checksum_skipped() {
  [ "${SKIP_CHECKSUM:-false}" = true ] && return 0
  # recipe_key (lib/registry.sh) is the one identity function for every
  # CLI-facing recipe name; --skip-checksum= is validated against the same
  # registry as --disable=, so it has to resolve the current recipe the same
  # way. It returns non-zero rather than an empty string when there is no
  # recipe to name, which matters here: an empty key would otherwise bypass
  # verification for every fetch the moment any --skip-checksum=NAME was
  # given, because the list is searched as a substring of a space-padded
  # window and the empty string is a substring of every window.
  _cs_key=$(recipe_key) || return 1
  [ -n "$_cs_key" ] || return 1
  case " ${SKIP_CHECKSUM_PKGS:-} " in
    *" $_cs_key "*) return 0 ;;
  esac
  return 1
}

# checksum_skip_warn FILE
# The one warning fetch() prints wherever checksum_skipped() bypasses
# verification. Shared by both fetch() call sites (cached and freshly
# downloaded) so the wording can't drift between the two paths -- the whole
# point of --skip-checksum is that a bypass is never quiet.
checksum_skip_warn() {
  warn "Checksum verification SKIPPED for $1 (--skip-checksum) -- integrity is NOT verified"
}

# die_no_record FILE DISPOSITION
# fetch()'s verify_file rc-3 exit: a file on disk with no recorded digest.
#
# One helper for all three rc-3 sites (cached, re-downloaded, freshly
# downloaded), which differed only in DISPOSITION -- the sentence saying which
# copy was kept. Wording that says "run makesum to record it" is the entire
# value of rc 3, and three copies of it drift.
die_no_record() {
  die "No recorded digest for $1 in $PKG_HASH_FILE.
$2 -- run './mediaforge.sh makesum' to record it."
}

# fetch [URL [FILENAME [DIRNAME]]]
# Reads PKG_URL, PKG_FILENAME, PKG_DIRNAME by default.
# Positional args override for non-recipe downloads (ffmpeg.sh, sub-packages).
fetch() {
  _url="${1:-$PKG_URL}"
  _file="${2:-${PKG_FILENAME:-${_url##*/}}}"
  _dir="${3:-$PKG_DIRNAME}"

  # Auto-detect target dir from tarball name if not specified
  if [ -z "$_dir" ]; then
    case "$_file" in
      *.tar.gz)  _dir="${_file%.tar.gz}" ;;
      *.tar.xz)  _dir="${_file%.tar.xz}" ;;
      *.tar.bz2) _dir="${_file%.tar.bz2}" ;;
      *.zip)     _dir="${_file%.zip}" ;;
      *)         _dir="${_file%.*}" ;;
    esac
  fi

  # makesum (#19): a cache entry may only seed a NEW pin when it already
  # matches an attested digest. Everything else -- no record, no file, or bytes
  # that no longer match one -- is unverified input, and recording it would
  # mint a canonical digest from a months-old truncated tarball that every
  # later build then verifies happily against. That is the exact failure #19
  # exists to close, arriving through the tool meant to prevent it, and it bit
  # hardest on `--build`'s whole reason to exist: the sub-build downloads that
  # have no record yet. makesum_needs_fetch (lib/makesum.sh) is the one place
  # that decision is made; makesum_fetch_and_record asks it the same question.
  if [ -f "$DISTDIR/$_file" ] && [ "${MAKESUM_MODE:-false}" = true ]; then
    if makesum_needs_fetch "${PKG_HASH_FILE:-}" "$_file" "$DISTDIR/$_file"; then
      warn "makesum: cached $_file is not attested by a recorded digest, re-downloading before recording"
      rm -f "$DISTDIR/$_file"
    else
      log "makesum: $_file already matches its recorded digest, skipping download"
    fi
  fi

  # Download if not cached, then verify either way (#19): a cache hit used to
  # be trusted forever, so a tarball corrupted or swapped after landing was
  # never re-examined.
  if [ -f "$DISTDIR/$_file" ]; then
    log "$_file already cached"
    if [ "${MAKESUM_MODE:-false}" != true ]; then
      if checksum_skipped; then
        checksum_skip_warn "$_file"
      else
        verify_file "$DISTDIR/$_file" "$_file"
        case $? in
          0) ;;
          2)
            # A cached file that fails is almost always locally corrupt or
            # truncated. Re-download once and verify the replacement, following
            # support/download/dl-wrapper. The retry is verified too, so a
            # hostile origin simply fails twice.
            warn "Cached $_file failed verification, re-downloading"
            rm -f "$DISTDIR/$_file"
            download_file "$_url" "$DISTDIR/$_file"
            verify_file "$DISTDIR/$_file" "$_file"
            # A fresh download landing here is rc 3 (missing record) only if the
            # hash file lost its entry between the two verify_file calls a few
            # lines apart -- not reachable in practice, but a plain `||` would
            # delete on rc 3 same as rc 2, exactly the keep-on-missing-record
            # inversion this task exists to eliminate. Same case shape as every
            # other verify_file call in fetch(), so a genuine rc 3 here dies with
            # the file kept, not silently deleted.
            case $? in
              0) ;;
              3) die_no_record "$_file" "The re-downloaded file was left in place" ;;
              *)
                rm -f "$DISTDIR/$_file"
                die "$_file failed verification after re-download. Refusing to build." ;;
            esac
            ;;
          3)
            # Keep the file: the hash file is the likely defect, and removing it
            # would force a re-download from a possibly worse source.
            die_no_record "$_file" "The download was left in place" ;;
        esac
      fi
    fi
  else
    download_file "$_url" "$DISTDIR/$_file"
    if [ "${MAKESUM_MODE:-false}" != true ]; then
      if checksum_skipped; then
        checksum_skip_warn "$_file"
      else
        verify_file "$DISTDIR/$_file" "$_file"
        case $? in
          0) ;;
          2)
            # No retry here: there is no earlier-good copy to fall back to, so a
            # mismatched fresh download is a dead end, not a corrupt cache.
            rm -f "$DISTDIR/$_file"
            die "$_file failed verification. Refusing to build."
            ;;
          3)
            # Same reasoning as the cached branch above: the hash file is the
            # likely defect, not this download.
            die_no_record "$_file" "The download was left in place" ;;
        esac
      fi
    fi
  fi

  # makesum --build (#19): record what was just fetched instead of verifying
  # it. PKG_HASH_FILE is ordinary shell state (see lib/framework.sh's
  # load_recipe), so a fetch() called from inside pkg_install() -- lv2's
  # sub-tarballs, opencl's ICD-Loader, libcdio's paranoia sub-package,
  # vid_stab's cmake-quoting patch -- still lands in the enclosing recipe's
  # sidecar. The verification gate above
  # is guarded by the inverse condition, so recording and verifying never both
  # run for the same fetch().
  if [ "${MAKESUM_MODE:-false}" = true ]; then
    # Read by hash_record_write() in lib/makesum.sh, which this file does not
    # source; per-file shellcheck can't see the cross-file consumer (same
    # shape as lib/framework.sh's file-header SC2034 disable).
    # shellcheck disable=SC2034
    MAKESUM_PROVENANCE="Locally calculated $(date +%Y-%m-%d)"
    hash_record_write "$PKG_HASH_FILE" "$_file" "$DISTDIR/$_file"
  fi

  # Skip extraction for patch files
  case "$_file" in
    *patch*) return 0 ;;
  esac

  # Extract based on archive type
  rm -rf "${DISTDIR:?}/${_dir:?}"
  mkdir -p "$DISTDIR/$_dir" || die "Failed to create $DISTDIR/$_dir"

  if [ -n "$3" ]; then
    _strip=""
  else
    _strip="--strip-components 1"
  fi

  case "$_file" in
    *.tar.gz|*.tgz)
      # shellcheck disable=SC2086
      tar -xzf "$DISTDIR/$_file" -C "$DISTDIR/$_dir" $_strip 2>/dev/null \
        || die "Failed to extract $_file"
      ;;
    *.tar.xz)
      # shellcheck disable=SC2086
      tar -xJf "$DISTDIR/$_file" -C "$DISTDIR/$_dir" $_strip 2>/dev/null \
        || die "Failed to extract $_file"
      ;;
    *.tar.bz2)
      # shellcheck disable=SC2086
      tar -xjf "$DISTDIR/$_file" -C "$DISTDIR/$_dir" $_strip 2>/dev/null \
        || die "Failed to extract $_file"
      ;;
    *.zip)
      unzip -q -o "$DISTDIR/$_file" -d "$DISTDIR/$_dir" 2>/dev/null \
        || die "Failed to extract $_file"
      ;;
    *)
      # Fallback: let tar auto-detect
      # shellcheck disable=SC2086
      tar -xf "$DISTDIR/$_file" -C "$DISTDIR/$_dir" $_strip 2>/dev/null \
        || die "Failed to extract $_file"
      ;;
  esac

  log "Extracted $_file"
  cd "$DISTDIR/$_dir" || die "Failed to enter $DISTDIR/$_dir"
}
