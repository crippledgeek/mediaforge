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
  _err=$(awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      if (NF != 3) { printf("line %d: expected 3 fields, got %d\n", NR, NF); next }
      k = $1; v = $2; f = $3
      if (k == "size") {
        if (v !~ /^[0-9]+$/) { printf("line %d: size %s is not a decimal count\n", NR, v); next }
      } else if (k == "sha256" || k == "sha512" || k == "sha1") {
        if (v !~ /^[0-9a-f]+$/) { printf("line %d: %s value %s is not lowercase hex\n", NR, k, v); next }
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
  awk -v want="$2" -v key="$3" '
    /^[[:space:]]*#/ { next }
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

  # Download if not cached
  if [ ! -f "$DISTDIR/$_file" ]; then
    download_file "$_url" "$DISTDIR/$_file"
  else
    log "$_file already cached"
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
