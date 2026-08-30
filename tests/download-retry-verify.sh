#!/bin/sh
# Regression test (GH-70): a FRESH download that fails verification gets the
# same second chance a cached one already had, and a failure says what actually
# arrived.
#
# Two defects, one incident. `fetch()` re-downloaded a CACHED file that failed
# verification and verified the replacement, but killed the build on the first
# FRESH mismatch -- the asymmetry backwards, since a cached mismatch is bytes
# that verified once and no longer do, while a fresh mismatch is the case most
# likely to be transient. And the payload that caused it was an Anubis bot
# challenge served as HTTP 200: 7,438 bytes reported as `Download complete`,
# then `failed verification`, which reads as "the sidecar is wrong" -- the wrong
# thing to chase, at a cost of hours.
#
# Everything here is driven from a local stub origin, so nothing touches the
# network. The origin serves a SCRIPTED SEQUENCE of bodies -- one per request,
# the last repeating -- and counts requests, which is what makes "retried
# exactly once" measurable rather than inferred from an exit status.
#
# Assertions are compound where the claim needs both halves, and every one of
# them carries a half that the pre-fix tree gets wrong: several of the
# behaviours below (the rc-3 keep-and-die, the cached branch's single retry) are
# deliberately UNCHANGED by this work, and an assertion that only restated them
# would pass on the merge base while guarding nothing. Each is therefore stated
# against the behaviour that did change -- see tests/oracle-baseline.sh.
set -u

# python3, file(1) and curl are dependencies of this TEST, not of mediaforge.
command -v python3 >/dev/null 2>&1 || { echo 'SKIP (no python3)'; exit 0; }
command -v file >/dev/null 2>&1 || { echo 'SKIP (no file(1))'; exit 0; }
command -v curl >/dev/null 2>&1 || { echo 'SKIP (no curl)'; exit 0; }

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

# Sourced before the trap below, because the handler it installs must exist by
# the time the trap that calls it is registered.
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

WORK=$(mktemp -d)
SRV_PID=''
trap 'kill "$SRV_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
_cleanup_on_signal

ARCHIVE=stub-1.0.tar.gz
DIST="$WORK/dist"
SEQ="$WORK/seq"
COUNT="$WORK/count"
PORT_FILE="$WORK/port"
LOG="$WORK/log"

# ---- fixtures -------------------------------------------------------------
# A real archive, so a run that is meant to SUCCEED also extracts.
mkdir -p "$WORK/src/stub-1.0"
echo 'stub payload' > "$WORK/src/stub-1.0/file.txt"
( cd "$WORK/src" && tar czf "$WORK/good.tar.gz" stub-1.0 )

# The payload the incident actually served: HTTP 200, an interstitial body.
cat > "$WORK/challenge.html" <<'HTML'
<!DOCTYPE html>
<html><head><title>Making sure you&#39;re not a bot!</title>
<link rel="stylesheet" href="/.within.website/x/xess/xess.min.css">
</head><body><p>Making sure you're not a bot!</p></body></html>
HTML

# The other body that reaches the same branch, and the reason it does not say
# "HTML": an object-store denial served as 200. file(1) answers `XML 1.0
# document` for it, with no "HTML" anywhere.
cat > "$WORK/denied.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>
XML

# A truncated ARCHIVE: fails verification for the same reason the challenge
# page does, and is still recognisably an archive. The diagnostic must tell
# these two apart, which is the whole of its value.
dd if="$WORK/good.tar.gz" of="$WORK/truncated.tar.gz" bs=1 count=100 2>/dev/null

GOOD="$WORK/good.tar.gz"
HTML_BODY="$WORK/challenge.html"
TRUNC="$WORK/truncated.tar.gz"
XML_BODY="$WORK/denied.xml"

# The sidecar the good archive verifies against, in the grammar lib/download.sh
# parses (`<keyword>  <value>  <filename>`).
{
  printf '# Locally calculated for %s\n' "$ARCHIVE"
  printf 'sha256\t%s\t%s\n' "$(sha256sum < "$GOOD" | awk '{print $1}')" "$ARCHIVE"
  printf 'size\t%s\t%s\n' "$(wc -c < "$GOOD" | tr -d ' ')" "$ARCHIVE"
} > "$WORK/stub.hash"

# A well-formed sidecar with no record for this file at all -- verify_file's
# rc 3, which must keep the file and never enter the retry.
printf '# no record for %s\n' "$ARCHIVE" > "$WORK/empty.hash"

# ---- stub origin ----------------------------------------------------------
# Answers 200 to every GET with the body named by the next line of $SEQ (the
# last line repeats), and appends one line to $COUNT per request. Re-reading
# both files per request is what lets one server serve every scenario below.
python3 -c '
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

seq_file, count_file, port_file = sys.argv[1:4]

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        with open(seq_file) as f:
            seq = [l.strip() for l in f if l.strip()]
        with open(count_file) as f:
            n = sum(1 for l in f if l.strip())
        with open(count_file, "a") as f:
            f.write("x\n")
        body = open(seq[min(n, len(seq) - 1)], "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

srv = HTTPServer(("127.0.0.1", 0), H)
with open(port_file, "w") as f:
    f.write(str(srv.server_address[1]))
    f.flush()
srv.serve_forever()
' "$SEQ" "$COUNT" "$PORT_FILE" &
SRV_PID=$!

_i=0
PORT=''
while [ "$_i" -lt 50 ]; do
  PORT=$(cat "$PORT_FILE" 2>/dev/null)
  [ -n "$PORT" ] && break
  sleep 0.1
  _i=$((_i + 1))
done
if [ -z "$PORT" ]; then
  printf 'ERROR: the fixture server did not start\n' >&2
  exit 1
fi
URL="http://127.0.0.1:$PORT/$ARCHIVE"

# ---- the unit under test --------------------------------------------------
# SCRIPT_DIR is how lib/utils.sh locates lib/stage.sh (GH-59); mediaforge.sh
# sets it from $0, and a test sourcing the library supplies it itself.
SCRIPT_DIR="$ROOT"
# shellcheck source=lib/utils.sh
. "$ROOT/lib/utils.sh"
# shellcheck source=lib/download.sh
. "$ROOT/lib/download.sh"
_fail=0

# fetch() reads PKG_URL / PKG_FILENAME / PKG_DIRNAME through `${N:-$PKG_*}`
# defaults, so under `set -u` an unset one aborts before the download and every
# assertion below reads as a false pass.
PKG_URL=''
PKG_FILENAME=''
PKG_DIRNAME=''
DISTDIR="$DIST"
export PKG_URL PKG_FILENAME PKG_DIRNAME DISTDIR

# checksum_skipped() resolves the current recipe through recipe_key()
# (lib/registry.sh), which this test does not source -- there is no recipe.
# Stubbed to "no recipe name" rather than left undefined so the failure is the
# declared one instead of a command-not-found on stderr.
recipe_key() { return 1; }

SEED=''

# The sidecar verify_file reads, defaulted and reset the same way $SEED is, and
# for the same reason: it was set to the recordless one and restored by hand
# either side of a single scenario, so a scenario appended between those two
# lines would have inherited it, taken the rc-3 path, and still read as a
# plausible pass.
HASH_DEFAULT="$WORK/stub.hash"
HASH="$HASH_DEFAULT"

# _run SEQUENCE...
# Point the origin at a fresh scripted sequence, clear the request counter and
# the download directory, and run one fetch() to completion. die() exits, so
# the call is subshelled; RC, REQ and $LOG are the measurements.
#
# Called with all THREE arguments, the third empty. fetch()'s extraction step
# reads `$3` bare rather than `${3:-}`, which is harmless in a build (nothing
# in mediaforge.sh sets `-u`) and aborts a `set -u` test on the one path that
# reaches it -- the successful one. An empty third argument is what a recipe's
# own defaulted call resolves to, so this changes nothing else: the directory
# is still auto-derived from the filename and the extraction still strips one
# component.
#
# $SEED names a file to plant in DISTDIR as an already-cached copy before the
# fetch, or is empty for a fresh one. That is the ONLY thing fetch()'s two
# branches differ in, so one runner drives both rather than the cached case
# getting an open-coded copy of this.
_run() {
  PKG_HASH_FILE="$HASH"
  : > "$COUNT"
  printf '%s\n' "$@" > "$SEQ"
  rm -rf "${DIST:?}"
  mkdir -p "$DIST"
  [ -n "$SEED" ] && cp "$SEED" "$DIST/$ARCHIVE"
  ( fetch "$URL" "$ARCHIVE" "" ) > "$LOG" 2>&1
  RC=$?
  REQ=$(wc -l < "$COUNT" | tr -d ' ')
  # Both cleared HERE, not by each caller. A scenario appended after the cached
  # or the recordless one would otherwise inherit that state silently, measure
  # a branch it does not name, and keep passing.
  SEED=''
  HASH="$HASH_DEFAULT"
}

# Did the run leave the archive in DISTDIR? Every scenario below asks it, and
# it is the load-bearing half of more than one assertion: a refusal that still
# caches the bad bytes poisons the next build's cache hit.
_cached() {
  if [ -f "$DIST/$ARCHIVE" ]; then printf yes; else printf no; fi
}

# ---- the runs -------------------------------------------------------------
# Every distinct scenario runs ONCE, here, and the assertions below read what
# it recorded. Written the other way round first -- each assertion driving its
# own fetch -- it re-ran the two-bad-payloads scenario five times: slower, and
# worse, it let two assertions naming the same scenario measure two different
# runs of it.

# A bad payload, then a good one: the recovery this change exists for.
_run "$HTML_BODY" "$GOOD"
_good_rc=$RC; _good_req=$REQ; _good_cached=$(_cached)
_good_matches=no; cmp -s "$DIST/$ARCHIVE" "$GOOD" 2>/dev/null && _good_matches=yes
_good_extracted=no; [ -f "$DIST/stub-1.0/file.txt" ] && _good_extracted=yes

# Two bad payloads: the refusal, and the request count that proves ONE retry.
_run "$HTML_BODY" "$HTML_BODY"
_html_rc=$RC; _html_req=$REQ; _html_left=$(_cached); _html_log=$(cat "$LOG")

# The same shape with a truncated ARCHIVE instead of a page. It fails
# verification for the same reason and is still recognisably an archive, which
# is what makes it the control for the diagnostic.
_run "$TRUNC" "$TRUNC"
_trunc_rc=$RC; _trunc_req=$REQ; _trunc_left=$(_cached); _trunc_log=$(cat "$LOG")

# An XML denial rather than a challenge page: same branch of the diagnostic,
# different wording obligation.
_run "$XML_BODY" "$XML_BODY"
_xml_log=$(cat "$LOG")

# No recorded digest at all -- verify_file's rc 3, which keeps the file and
# must not enter the retry.
HASH="$WORK/empty.hash"
_run "$HTML_BODY"
_norec_rc=$RC; _norec_req=$REQ; _norec_left=$(_cached); _norec_log=$(cat "$LOG")

# A CACHED bad copy: the branch that always had the retry. It is not fetched,
# so its single retry is one request where the fresh path's is two.
SEED="$HTML_BODY"
_run "$HTML_BODY"
_cached_rc=$RC; _cached_req=$REQ; _cached_left=$(_cached)

# ---- 1. a fresh mismatch is retried, and a good second response builds -----
_wrong=''
[ "$_good_rc" -eq 0 ] || _wrong="$_wrong fetch failed (rc=$_good_rc) instead of recovering;"
[ "$_good_req" -eq 2 ] || _wrong="$_wrong made $_good_req request(s), expected 2 (one retry);"
[ "$_good_cached" = yes ] || _wrong="$_wrong no $ARCHIVE was left in DISTDIR;"
[ "$_good_matches" = yes ] || _wrong="$_wrong the cached copy is not the good archive;"
[ "$_good_extracted" = yes ] || _wrong="$_wrong the archive was not extracted;"
if [ -z "$_wrong" ]; then
  _pass fresh-mismatch-retried-once-then-builds
else
  _bad fresh-mismatch-retried-once-then-builds "$_wrong"
fi

# ---- 2. two fresh failures still refuse to build, leaving nothing ----------
_wrong=''
[ "$_html_rc" -ne 0 ] || _wrong="$_wrong fetch returned 0 on two bad payloads;"
[ "$_html_req" -eq 2 ] || _wrong="$_wrong made $_html_req request(s), expected exactly 2;"
[ "$_html_left" = no ] || _wrong="$_wrong the bad payload was left in DISTDIR;"
if [ -z "$_wrong" ]; then
  _pass two-fresh-failures-die-after-one-retry-with-nothing-cached
else
  _bad two-fresh-failures-die-after-one-retry-with-nothing-cached "$_wrong"
fi

# ---- 3. the retry is scoped to a MISMATCH: rc 3 keeps the file and stops ---
# Stated as the contrast, deliberately. "A missing record dies with the file
# kept" is true of the pre-fix tree too, so on its own it guards nothing; the
# claim that needed guarding is that the new retry did not widen into the
# missing-record path.
_wrong=''
[ "$_norec_rc" -ne 0 ] || _wrong="$_wrong a missing record returned 0;"
[ "$_norec_req" -eq 1 ] || _wrong="$_wrong a missing record made $_norec_req request(s), expected 1 (no retry);"
[ "$_norec_left" = yes ] || _wrong="$_wrong a missing record deleted the download instead of keeping it;"
case "$_norec_log" in
  *makesum*) ;;
  *) _wrong="$_wrong the missing-record failure never mentions makesum;" ;;
esac
[ "$_html_req" -eq 2 ] || _wrong="$_wrong a mismatch made $_html_req request(s), expected 2 -- the retry it is being contrasted with never happened;"
if [ -z "$_wrong" ]; then
  _pass retry-covers-mismatch-not-missing-record
else
  _bad retry-covers-mismatch-not-missing-record "$_wrong"
fi

# ---- 4. one retry, in BOTH branches -- the cached path is not doubled ------
# Measured together because "the cached branch still retries once" is unchanged
# behaviour and cannot detect this change on its own.
_wrong=''
[ "$_cached_rc" -ne 0 ] || _wrong="$_wrong a cached mismatch returned 0;"
[ "$_cached_req" -eq 1 ] || _wrong="$_wrong a cached mismatch made $_cached_req request(s), expected exactly 1;"
[ "$_cached_left" = no ] || _wrong="$_wrong a cached mismatch left the bad file behind;"
[ "$_html_req" -eq 2 ] || _wrong="$_wrong a fresh mismatch made $_html_req request(s), expected 2;"
if [ -z "$_wrong" ]; then
  _pass cached-and-fresh-mismatch-each-retry-exactly-once
else
  _bad cached-and-fresh-mismatch-each-retry-exactly-once "$_wrong"
fi

# ---- 5. the payload is diagnosed, and only when it is not an archive -------
_wrong=''
case "$_html_log" in
  *"not an archive"*) ;;
  *) _wrong="$_wrong an HTML body served as 200 was never diagnosed as such;" ;;
esac
case "$_html_log" in
  *challenge*|*portal*) ;;
  *) _wrong="$_wrong the HTML diagnosis names no cause an operator can act on;" ;;
esac
case "$_trunc_log" in
  *"not an archive"*) _wrong="$_wrong a truncated ARCHIVE was diagnosed as not an archive;" ;;
esac
if [ -z "$_wrong" ]; then
  _pass html-payload-diagnosed-truncated-archive-not
else
  _bad html-payload-diagnosed-truncated-archive-not "$_wrong"
fi

# ---- 6. the diagnosis is advisory: the verdict is the same either way ------
# The two runs compared here differ ONLY in whether the payload earned a
# diagnostic. If the message reached the accept/reject decision, their verdicts
# would diverge -- so they are compared directly, with the presence of the
# message on exactly one of them asserted in the same breath, or the comparison
# would be vacuous on a tree that diagnoses nothing.
_wrong=''
[ "$_html_rc" -eq "$_trunc_rc" ] || _wrong="$_wrong verdicts differ: rc $_html_rc (diagnosed) vs $_trunc_rc (not);"
[ "$_html_req" -eq "$_trunc_req" ] || _wrong="$_wrong request counts differ: $_html_req vs $_trunc_req;"
[ "$_html_left" = "$_trunc_left" ] || _wrong="$_wrong one run left a file behind and the other did not;"
# Labelled rather than looped over the two logs: both iterations of that loop
# appended the same sentence, so a failure said "a run did not reach the
# post-retry refusal" twice and named neither.
for _run_log in "diagnosed:$_html_log" "undiagnosed:$_trunc_log"; do
  case "${_run_log#*:}" in
    *"failed verification after re-download"*) ;;
    *) _wrong="$_wrong the ${_run_log%%:*} run did not reach the post-retry refusal;" ;;
  esac
done
case "$_html_log" in
  *"not an archive"*) ;;
  *) _wrong="$_wrong the diagnosed run carried no diagnosis, so the comparison is vacuous;" ;;
esac
if [ -z "$_wrong" ]; then
  _pass diagnosis-does-not-change-the-verdict
else
  _bad diagnosis-does-not-change-the-verdict "$_wrong"
fi

# ---- 7. the description is reduced before it reaches the terminal ---------
# file(1) ECHOES payload bytes for several types (a shebang line, an embedded
# comment), so its answer is attacker-controlled text on a path that prints
# straight to an operator's terminal -- where an ANSI escape rewrites the very
# line being read to diagnose the failure.
#
# Driven through a STUBBED file(1), not a crafted payload, because what reaches
# describe_payload depends on the local libmagic: file-5.48 renders a control
# byte as the four characters `\033` itself, so a real payload cannot exercise
# the reduction on this host and a test built on one would pass by accident
# wherever it did. The contract under test is describe_payload's own -- whatever
# file(1) hands it, what leaves is printable and bounded -- and a stub is the
# only way to state it. `command_exists` is `command -v`, which finds a shell
# function, so the stub is reached exactly as the binary would be.
_evil_desc=$(printf 'CABINET \033[31mred\033[0m data%s' \
             "$(awk 'BEGIN { while (i++ < 400) printf "x" }')")
# _stub_diag DESCRIPTION -- what describe_payload prints when file(1) says
# exactly that. The stub is defined inside the command substitution, so it is
# scoped to that subshell and the assertions using the real binary are
# unaffected.
_stub_diag() {
  _sd_desc="$1"
  (
    file() { printf '%s' "$_sd_desc"; }
    describe_payload "$GOOD" "$ARCHIVE" 2>&1
  )
}

# _pad N -- a description of exactly N characters that no archive pattern
# matches, so it reaches the branch that prints it.
_pad() {
  awk -v n="$1" 'BEGIN { s = "CABINET "; while (length(s) < n) s = s "x"; print s }'
}

_diag=$(_stub_diag "$_evil_desc")
_ctl=$(printf '%s' "$_diag" | tr -d '\n' | LC_ALL=C tr -d '[:print:][:blank:]' | wc -c | tr -d ' ')
_wrong=''
case "$_diag" in
  *CABINET*) ;;
  *) _wrong="$_wrong the description never reached the message, so nothing was measured;" ;;
esac
[ "$_ctl" -eq 0 ] || _wrong="$_wrong $_ctl control character(s) survived into the message;"
if [ -z "$_wrong" ]; then
  _pass payload-description-is-printable
else
  _bad payload-description-is-printable "$_wrong"
fi

# ---- 9. the cap is pinned AT 160, not somewhere comfortably past it --------
# A length assertion placed well beyond the cap passes at 240 as happily as at
# 160, so it guards the branch and not the threshold. These two are one
# character apart: 160 must survive whole, 161 must come back cut and MARKED,
# and no off-by-one in the cut or the marker leaves both green.
_at=$(_stub_diag "$(_pad 160)")
_over=$(_stub_diag "$(_pad 161)")
_at_desc=${_at#*is not an archive: }
_over_desc=${_over#*is not an archive: }
_wrong=''
[ "${#_at_desc}" -eq 160 ] || _wrong="$_wrong a 160-character description came back as ${#_at_desc};"
case "$_at_desc" in
  *...) _wrong="$_wrong a description AT the cap was marked as truncated;" ;;
esac
[ "${#_over_desc}" -eq 163 ] || _wrong="$_wrong a 161-character description came back as ${#_over_desc}, expected 160 plus the marker;"
case "$_over_desc" in
  *...) ;;
  *) _wrong="$_wrong a truncated description carries no marker, so it reads as complete;" ;;
esac
if [ -z "$_wrong" ]; then
  _pass description-cap-holds-at-its-boundary
else
  _bad description-cap-holds-at-its-boundary "$_wrong"
fi

# ---- 8. a web page is called a web page, not asserted to be HTML ----------
# The diagnostic's whole justification is that the first line an operator reads
# is TRUE. Reporting `XML 1.0 document` as "is HTML" and pointing at bot
# challenges would reproduce the misdiagnosis in a new place.
_wrong=''
case "$_xml_log" in
  *"is a web page"*) ;;
  *) _wrong="$_wrong an XML body served as 200 was not diagnosed as a web page;" ;;
esac
case "$_xml_log" in
  *"is HTML"*) _wrong="$_wrong an XML body was asserted to be HTML;" ;;
esac
case "$_xml_log" in
  *"XML 1.0"*) ;;
  *) _wrong="$_wrong the message does not quote what file(1) actually said;" ;;
esac
if [ -z "$_wrong" ]; then
  _pass xml-body-diagnosed-without-claiming-html
else
  _bad xml-body-diagnosed-without-claiming-html "$_wrong"
fi

printf 'DONE: download-retry-verify\n'
exit "$_fail"
