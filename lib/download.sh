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
# Defined ONCE, here, because the two consumers below and the test files that
# parse the same KIND of line all ask the same question of it. The test-side
# list is deliberately not enumerated: it drifted twice in the three commits
# that introduced this constant. `grep -rl HASH_COMMENT_RE tests/` finds every
# file that mentions it, which is a SUPERSET of the parsers -- some files probe
# the constant or name it in prose instead. A superset that cannot rot beats an
# exact list that has.
#
# The marker was written out three times before this constant existed, and #44
# converged only the test side; the two copies that survived were the production
# ones, in the functions tests/checksum-verification.sh exercises.
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
#
# No `${VAR:?}` guard at the two consumers below, deliberately. They live in this
# file, and the assignment is unconditional top-level code above them, so no
# reachable path reaches them with it empty -- colocation is the guarantee, which
# is why the constant was moved here rather than into a constants file nobody
# remembers to source. (For the test consumers the guarantee is their `.` line,
# not colocation.) A per-call guard would also be worse than useless in
# hash_lookup: every call site is a command substitution, so `${VAR:?}` would
# exit only the subshell and hand the caller the empty digest it was meant to
# prevent. That last point holds because nothing in the call chain sets `-e`; a
# future `set -e` would invert it.
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

  # 40 hex digits names an OBJECT, not necessarily a commit. `git ls-remote`
  # prints an annotated tag twice -- the tag object under refs/tags/<v>, and the
  # commit it points to under refs/tags/<v>^{} -- so resolving a pin by reading
  # the first line yields the tag object. The shape check at the top of this
  # function cannot see the difference (both are 40 hex), and the fetch above
  # succeeds because the object genuinely exists; `checkout FETCH_HEAD` then
  # silently PEELS the tag and lands HEAD on a SHA nobody asked for.
  #
  # librist arrived that way: PKG_COMMIT held 27460636 (refs/tags/v0.2.11)
  # rather than c5268580 (the commit it peels to), and the build died 86
  # recipes in. The assertion below the checkout did catch it -- but only after
  # the working tree had been written from the wrong object, and it reported a
  # bare SHA mismatch, which reads as a corrupted checkout rather than as a
  # mis-resolved pin. Asking git what the object IS costs one cheap local call
  # and turns that into an instruction.
  _type=$(git -C "$_dest" cat-file -t "$_commit" 2>/dev/null || printf '')
  if [ "$_type" != commit ]; then
    _peel=$(git -C "$_dest" rev-parse "${_commit}^{commit}" 2>/dev/null || printf '')
    die "fetch_git: $_commit is a git ${_type:-unreadable} object, not a commit.${_peel:+
Pin the commit it points to instead: $_peel}
'git ls-remote <url> <tag>' prints the tag object first and the commit under <tag>^{} -- pin the second."
  fi

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

# videolan_release_url NAME VERSION [LEGACY_BZ2_GLOB]
# A tarball URL on VideoLAN's release server, which every recipe repointed by
# GH-69 fetches from:
#
#   https://download.videolan.org/pub/videolan/<name>/<version>/<name>-<version>.<ext>
#
# NAME appears twice and VERSION three times in that shape, which is why it is
# a function rather than three copies of the string: dav1d, libdvdread and
# libdvdnav all build it, and a correction to the layout belongs to all three.
#
# LEGACY_BZ2_GLOB is the version pattern published as .tar.bz2; everything else
# is .tar.xz. It is a PARAMETER and not a constant because the cutoff is a
# per-project fact, not a VideoLAN-wide one. VideoLAN did move from bzip2 to xz
# across its projects, but each crossed at its own version number -- x264's
# snapshots are still .tar.bz2 today -- so a shared "6.x means bz2" rule would
# be right for libdvdread and libdvdnav and quietly wrong for the next caller.
# Omit it when a project has only ever published .tar.xz, as dav1d has.
#
# THE BUG THIS EXISTS FOR. The generated GitLab archives these recipes used
# before GH-69 were extension-uniform across every tag -- always .tar.gz,
# because the forge built them per request from the tag name. The release server
# is not, and a hardcoded extension breaks only the profiles pinning the other
# format, which is why a full 8.0.1 build stayed green while three profiles
# could not fetch at all:
#
#   --profile=7.0 / 7.1 pin libdvdread 6.1.3 and libdvdnav 6.1.1
#   .../libdvdread/6.1.3/libdvdread-6.1.3.tar.xz  -> 404 (verified 2026-08-30)
#   .../libdvdread/6.1.3/libdvdread-6.1.3.tar.bz2 -> 200
#
# Called at recipe-source time, which is already how a recipe reaches
# ffmpeg_version_ge.
videolan_release_url() {
  _vr_name="$1"
  _vr_ver="$2"
  _vr_legacy="${3:-}"

  _vr_ext=tar.xz
  if [ -n "$_vr_legacy" ]; then
    # $_vr_legacy is a GLOB by design, so it is deliberately unquoted here --
    # quoting it would match the pattern literally and no version could ever
    # select .tar.bz2. Same reason tests/lib-assert.sh's _glob leaves its
    # pattern unquoted, and the same suppression it carries.
    # shellcheck disable=SC2254
    case "$_vr_ver" in
      $_vr_legacy) _vr_ext=tar.bz2 ;;
    esac
  fi

  printf 'https://download.videolan.org/pub/videolan/%s/%s/%s-%s.%s' \
    "$_vr_name" "$_vr_ver" "$_vr_name" "$_vr_ver" "$_vr_ext"
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

# describe_payload FILE NAME
# One line naming what actually landed, printed wherever a download fails its
# recorded size or digest -- verify_file rc 2 (#70). The rc-3 path (no record
# at all) says something else and is not a payload question. DIAGNOSTIC ONLY:
# verify_file owns the accept/reject decision and nothing here touches it.
#
# A host that answers a tarball request with HTTP 200 and an interstitial --
# an Anubis bot challenge, a captive portal -- produces an ordinary size
# mismatch, so the first thing the operator reads is "failed verification".
# That reads as "the sidecar is wrong" or "upstream re-rolled the tarball",
# which are the two causes a maintainer chases first and both are wrong: no
# archive was served at all. The 7,438-byte dav1d "tarball" that cost this
# project a multi-hour build was such a page, and the diagnosis cost far more
# than the failure.
#
# Silent when the payload IS an archive, because a line that prints on every
# failure says nothing: a truncated tarball is still a tarball, and reporting
# it here would drown the case worth reading.
describe_payload() {
  _dp_file="$1"
  _dp_name="$2"

  # file(1) is POSIX but absent from minimal containers, and a missing
  # diagnostic must never perturb the failure path it is describing.
  command_exists file || return 0
  [ -f "$_dp_file" ] || return 0

  if [ ! -s "$_dp_file" ]; then
    warn "$_dp_name is empty -- the host answered with no body"
    return 0
  fi

  # file(1)'s answer is not trusted text: for several types it ECHOES bytes out
  # of the payload (a shebang line, an embedded comment or path), and the
  # payload here is whatever an origin chose to serve. Printed raw, an ANSI
  # escape inside a "description" rewrites the very line the operator is
  # reading to diagnose the failure. So it is reduced to printable characters
  # and capped -- a diagnosis is one line, and a crafted one is otherwise as
  # long as the attacker likes. LC_ALL=C keeps the classes byte-defined, so the
  # filter cannot vary with the operator's locale; `[:print:]` already includes
  # space, so `[:blank:]` is there for TAB alone -- kept so a tab inside a
  # description reads as the whitespace it is rather than closing the gap
  # between two words.
  _dp_full=$(file -b "$_dp_file" 2>/dev/null | LC_ALL=C tr -dc '[:print:][:blank:]')
  [ -n "$_dp_full" ] || return 0

  # The cap is MARKED. A description cut at 160 characters otherwise ends
  # mid-word and reads as a complete sentence, so the operator cannot tell
  # file(1) said more -- which is the one failure mode this whole function
  # exists to remove, reintroduced by the fix for a different one.
  _dp_desc=$(printf '%s' "$_dp_full" | cut -c1-160)
  [ "$_dp_desc" = "$_dp_full" ] || _dp_desc="$_dp_desc..."

  case "$_dp_full" in
    # Anything file(1) recognises as an archive: this failure is about the
    # bytes, not about what was served, and there is nothing to add. Two
    # patterns cover every archive shape in play, `Zip archive data` and
    # `7-zip archive data` included -- both say "archive".
    *compressed*|*archive*) return 0 ;;
    # Named as a web page rather than as HTML, and quoting the description,
    # because file(1) answers `XML 1.0 document` for the other body that lands
    # here -- an S3/GCS <Error><Code>AccessDenied</Code></Error> or a SOAP
    # fault served as 200. Telling the operator that is "HTML" is the same
    # species of misleading first line this function exists to remove.
    *HTML*|*XML*)
      warn "$_dp_name is a web page ($_dp_desc), not an archive -- the host may be serving a bot challenge or a captive portal rather than the file" ;;
    *)
      warn "$_dp_name is not an archive: $_dp_desc" ;;
  esac
}

# redownload_and_verify URL FILE ORIGIN
# fetch()'s ONE second chance for a file that failed verification: say what
# arrived, replace it, verify the replacement, and refuse to build on a second
# failure with nothing left behind. ORIGIN names where the failed copy came
# from ("Cached", "Freshly downloaded"), which is the only thing the two call
# sites differ in.
#
# The cached branch has had this since #19; the fresh branch died on the first
# mismatch instead, reasoning that a fresh mismatch "is a dead end, not a
# corrupt cache". The asymmetry was backwards (#70). A cached mismatch is bytes
# that verified once and no longer do -- the more suspicious of the two. A
# fresh mismatch is the case most likely to be TRANSIENT: a truncation, a 5xx
# or a challenge page served as 200, one bad edge node. The branch with the
# second chance needed it less.
#
# The cached branch's safety argument carries over verbatim, and is why one
# retry is enough rather than a loop: the retry is verified too, so a hostile
# origin simply fails twice.
redownload_and_verify() {
  _rd_url="$1"
  _rd_file="$2"
  _rd_origin="$3"

  describe_payload "$DISTDIR/$_rd_file" "$_rd_file"
  warn "$_rd_origin $_rd_file failed verification, re-downloading"
  rm -f "$DISTDIR/$_rd_file"
  download_file "$_rd_url" "$DISTDIR/$_rd_file"
  verify_file "$DISTDIR/$_rd_file" "$_rd_file"
  # rc 3 (missing record) here means the hash file lost its entry between
  # fetch()'s verify_file and this one -- not reachable in practice, but a
  # plain `||` would delete on rc 3 the same as on rc 2, exactly the
  # keep-on-missing-record inversion the case shape exists to prevent. A
  # genuine rc 3 dies with the file kept, as it does everywhere else in fetch().
  case $? in
    0) return 0 ;;
    3) die_no_record "$_rd_file" "The re-downloaded file was left in place" ;;
    *)
      describe_payload "$DISTDIR/$_rd_file" "$_rd_file"
      rm -f "$DISTDIR/$_rd_file"
      die "$_rd_file failed verification after re-download. Refusing to build." ;;
  esac
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
            # support/download/dl-wrapper.
            redownload_and_verify "$_url" "$_file" Cached
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
            # The same second chance the cached branch above takes, through the
            # same helper: a fresh mismatch is the case most likely to be
            # transient, not a dead end (#70).
            redownload_and_verify "$_url" "$_file" "Freshly downloaded"
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
