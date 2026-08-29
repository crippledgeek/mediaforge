#!/bin/sh
# The sidecar comment MARKER must have exactly one definition, and the code that
# parses sidecars must actually READ it.
#
# Usage: tests/hash-comment-grammar.sh
# Exit 0 = pass, 1 = regression.
#
# SCOPE. This file pins the marker's `#` and its leading-whitespace tolerance --
# the half lib/download.sh consumes. It does NOT pin the constant's trailing
# `[[:space:]]*`, which is inert here: `$0 ~ CMT` is an unanchored-tail match, so
# both parsers skip exactly the same lines with or without it. That half is
# load-bearing only for provenance_pinned_fprs in tests/lib-provenance.sh, whose
# pin pattern is `^`-anchored -- a surviving leading space makes every pin
# invisible. Dropping it is caught by tests/signing-keys.sh and
# tests/upstream-provenance.sh, both of which carry floors that fire on it.
# Asserting it here would assert behaviour this file's subject does not have.
#
# WHY THIS EXISTS. #44 gave the marker a single definition and rewrote its three
# test consumers onto it. The two PRODUCTION copies survived: hash_file_validate
# and hash_lookup each carried a literal /^[[:space:]]*#/, matched against the
# same sidecars, in the functions tests/checksum-verification.sh exercises. The
# tree held one definition for the tests and a hand-written pair for the code.
#
# Asserted by MUTATION rather than by grep, because a grep answers the wrong
# question. "Does the literal still appear anywhere" is a question about the
# text; the claim worth pinning is that changing the definition changes what the
# parser does. A future copy spelled differently -- `^ *#`, or a `case` guard
# instead of an awk rule -- would satisfy a grep and still be a second
# definition. Overriding the constant and demanding the behaviour move with it
# catches every spelling, including ones nobody has written yet.
#
# Each consumer is probed separately and with a DIFFERENT override, because they
# fail independently: converging one and leaving the other is precisely the
# half-done state this file exists to reject, and a single shared probe would let
# the converged half carry the copy.
#
#   hash_file_validate -- NARROW the grammar to something no line matches, so the
#     fixture's comment lines stop being skipped and are read as records. Both
#     have a field count the record grammar rejects, so a reading parser reports
#     them and dies. A parser holding its own literal skips them and succeeds.
#
#   hash_lookup -- REPOINT the grammar at the sha256 record, so a reading parser
#     skips the very line it was asked for and returns nothing. A parser holding
#     its own literal still finds it.
#
# Repoint rather than widen, and not for want of a portable widening:
# `^[[:space:]]*[#s]` is a strict superset, identical in BRE and ERE, and would
# be observable. It is rejected because it swallows the `size` record too, so the
# probe would stop isolating the line under test. Repointing mutes exactly one
# record, which is the assertion.
#
# The consequence to know is that under probe 2 the comment lines are not treated
# as comments either; the probe holds because a comment's first field is `#`, so
# `$1 == key` can never fire on one whatever its field count. What WOULD break
# probe 2 is a second three-field record for the same (filename, keyword) pair
# placed BEFORE the real one -- not a comment of any shape. Note where that
# breaks: the override mutes the duplicate too, so it is the SHIPPED-grammar
# conjunct that fails, because hash_lookup prints the first match and exits and
# would return the duplicate's digest.
#
# Narrowing is not observable in hash_lookup (neither comment line has three
# fields, so it matches no lookup either way) and repointing is not observable in
# hash_file_validate (a skipped record is not an error), which is why the two
# probes are not the same probe.
#
# Each consumer gets ONE compound assertion: the shipped grammar reads the
# fixture correctly AND overriding the constant moves the behaviour. Paired
# deliberately -- tests/oracle-baseline.sh requires that no assertion in a newly
# added file passes on the merge base, and the first half necessarily passes
# there, since it asserts behaviour the base already has right. Standing alone it
# was reported as an offender, correctly: on its own it detects nothing. Paired,
# the half the base gets wrong carries it, and the claim is the honest one --
# "this consumer parses correctly BY READING the shared definition", not two
# unrelated facts.
#
# The override is applied AFTER sourcing and restored afterwards, rather than
# passed in through the environment. lib/download.sh assigns the constant at
# source time, so an environment value would simply be overwritten -- and making
# the assignment defer to a pre-set one would let the environment retune sidecar
# parsing in a real build, which is a footgun rather than a testing seam. Saving
# with `${VAR-}` keeps this file runnable on a base where the constant does not
# exist yet, so it still reaches its DONE sentinel there.
#
# Each probe runs the function in a subshell because hash_file_validate calls
# die(), which exits -- uncontained, the first probe would take the script with
# it and the later assertion would never report.
#
# INT and TERM exit rather than sharing the EXIT handler, because a POSIX shell
# RESUMES the script after a non-EXIT trap returns: catching Ctrl-C to clean up
# and then running the remaining assertions is not what an interrupt means. The
# exit re-enters the EXIT trap, so cleanup still happens exactly once, and
# 128+signal is the status a killed process conventionally reports.
#
# No `set -e`: each check reports independently and the script exits with the
# accumulated status, so one failure does not hide the other --
# tests/oracle-baseline.sh depends on that, since a file that aborts early cannot
# prove the assertions past the abort point.
set -u

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$_here/.." && pwd)
cd "$ROOT" || exit 1

# shellcheck source=lib/utils.sh
# SCRIPT_DIR is how lib/utils.sh locates lib/stage.sh (GH-59). mediaforge.sh
# sets it from $0; a test sourcing the library directly supplies it itself.
SCRIPT_DIR="$ROOT"
. "$ROOT/lib/utils.sh"
# shellcheck source=lib/download.sh
. "$ROOT/lib/download.sh"

_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

_tmp=''
trap 'rm -rf ${_tmp:+"$_tmp"}' EXIT
_cleanup_on_signal
_tmp=$(mktemp -d) || exit 1

# A digest of the right shape and length; its value is never compared against a
# real file, only carried through the parser.
_dgst=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
_fx="$_tmp/demo.hash"

# The header line has FOUR fields and the indented one SIX, which is what makes
# probe 1 observable: a parser that stops treating them as comments must report
# them as malformed, since the record grammar demands exactly three.
#
# The INDENTED comment pins the grammar's leading-whitespace tolerance, which is
# load-bearing and was unguarded until a surviving mutant said so: narrowing the
# constant to `^#` left both probes green, because neither noticed a tolerance no
# fixture line exercised.
cat > "$_fx" <<EOF
# sha256 from https://example.invalid/SHA256SUMS
  # indented, and still a comment
$(printf 'sha256\t%s\tdemo-1.0.tar.gz' "$_dgst")
$(printf 'size\t123\tdemo-1.0.tar.gz')
EOF

# 1. hash_file_validate. Narrowed to match nothing, the comment lines are no
#    longer comments and must be reported as malformed.
_saved=${HASH_COMMENT_RE-}
HASH_COMMENT_RE='^@@no-line-matches-this@@'
( hash_file_validate "$_fx" ) >/dev/null 2>&1
_st=$?
HASH_COMMENT_RE=$_saved
if ( hash_file_validate "$_fx" ) >/dev/null 2>&1 && [ "$_st" -ne 0 ]; then
  _pass validate-reads-shared-constant
else
  _bad validate-reads-shared-constant \
    "rejected a well-formed sidecar, or ignored an overridden HASH_COMMENT_RE and so still holds its own copy of the grammar"
fi

# 2. hash_lookup. Repointed at the sha256 record, the lookup must skip the very
#    line it was asked for.
_saved=${HASH_COMMENT_RE-}
HASH_COMMENT_RE='^[[:space:]]*sha256'
_muted=$( hash_lookup "$_fx" demo-1.0.tar.gz sha256 )
HASH_COMMENT_RE=$_saved
if [ "$(hash_lookup "$_fx" demo-1.0.tar.gz sha256)" = "$_dgst" ] && [ -z "$_muted" ]; then
  _pass lookup-reads-shared-constant
else
  _bad lookup-reads-shared-constant \
    "failed to read a well-formed sidecar, or ignored an overridden HASH_COMMENT_RE (returned '$_muted') and so still holds its own copy"
fi

printf 'DONE: hash-comment-grammar\n'
exit "$_fail"
