#!/bin/sh
# The .hash sidecar comment grammar must have exactly ONE definition, and the
# code that parses sidecars must actually READ it.
#
# #44 gave the sidecar comment marker a single definition and rewrote both test
# consumers onto it. The two production consumers kept their own hand-written
# copies -- lib/download.sh's hash_file_validate and hash_lookup each carried a
# literal /^[[:space:]]*#/ -- so the tree held one definition for the tests and
# a separate pair for the code under test. #45 closes that.
#
# Asserted by MUTATION rather than by grep, because a grep answers the wrong
# question. "Does the literal still appear anywhere" is a question about the
# text; the claim worth pinning is that changing the definition changes what the
# parser does. A future copy that spelled the pattern differently -- `^ *#`, or
# a `case` guard instead of an awk rule -- would satisfy a grep and still be a
# second definition. Overriding the constant and demanding the behaviour move
# with it catches every spelling, including ones nobody has written yet.
#
# Each consumer is probed separately and with a DIFFERENT override, because they
# fail independently: converging one and leaving the other is precisely the
# half-done state this file exists to reject, and a single shared probe would
# let the converged half carry the copy.
#
# The override direction is chosen per consumer so the mutation is observable:
#
#   hash_file_validate -- NARROW the grammar to something no line matches, so
#     the fixture's comment header stops being skipped and is read as a record.
#     It has four fields, so a reading parser reports it and dies. A parser
#     holding its own literal skips it and reports success.
#
#   hash_lookup -- WIDEN the grammar to cover the sha256 record itself, so a
#     reading parser skips the very line it was asked for and returns nothing.
#     A parser holding its own literal still finds it.
#
# Narrowing is not observable in hash_lookup (the header has four fields, so it
# matches no lookup either way) and widening is not observable in
# hash_file_validate (a skipped record is not an error), which is why the two
# probes are not the same probe.
#
# The override is applied AFTER sourcing and restored afterwards, rather than
# passed in through the environment. lib/download.sh assigns the constant at
# source time, so an environment value would simply be overwritten -- and making
# the assignment defer to a pre-set one (`: "${HASH_COMMENT_RE:=...}"`) would let
# the environment retune sidecar parsing in a real build, which is a footgun
# rather than a testing seam. Saving with `${VAR-}` keeps this file runnable on a
# base where the constant does not exist yet, so it still reaches its DONE
# sentinel there; tests/oracle-baseline.sh rejects a file that aborts early.
#
# Each probe runs the function in a subshell because hash_file_validate calls
# die(), which exits -- uncontained, the first probe would take the script with
# it and the later assertions would never report.
#
# No `set -e`: each check reports independently and the script exits with the
# accumulated status, so one failure does not hide the others --
# tests/oracle-baseline.sh depends on that, since a file that aborts early
# cannot prove the assertions past the abort point.
set -u

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$_here/.." && pwd)
cd "$ROOT" || exit 1

# shellcheck source=lib/utils.sh
. "$ROOT/lib/utils.sh"
# shellcheck source=lib/download.sh
. "$ROOT/lib/download.sh"

_fail=0
_pass() { printf 'PASS: %s\n' "$1"; }
_bad()  { printf 'FAIL: %s\n' "$1"; _fail=1; }

_tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$_tmp"' EXIT INT TERM

# A digest of the right shape and length; its value is never compared to a real
# file, only carried through the parser.
_dgst=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
_fx="$_tmp/demo.hash"

# The header line has FOUR fields, which is what makes probe 1 observable: a
# parser that stops treating it as a comment must report it as malformed.
#
# The INDENTED comment pins the grammar's leading-whitespace tolerance, which is
# load-bearing and was unguarded until a surviving mutant said so: narrowing the
# constant to `^#` left both probes green, because neither noticed a tolerance
# no fixture line exercised. An indented comment read as a record is five
# fields, so a narrowed grammar now fails probe 1.
cat > "$_fx" <<EOF
# sha256 from https://example.invalid/SHA256SUMS
  # indented, and still a comment
$(printf 'sha256\t%s\tdemo-1.0.tar.gz' "$_dgst")
$(printf 'size\t123\tdemo-1.0.tar.gz')
EOF

# Each consumer gets ONE compound assertion: the shipped grammar reads the
# fixture correctly AND overriding the constant moves the behaviour. Paired
# deliberately -- tests/oracle-baseline.sh requires that no assertion in a newly
# added file passes on the merge base, and the first half necessarily passes
# there (it asserts behaviour the base already has right). Standing alone it was
# reported as an offender, correctly: on its own it detects nothing. Paired, the
# half the base gets wrong carries it, and the claim is the honest one -- "this
# consumer parses correctly BY READING the shared definition", not two unrelated
# facts.

# 1. hash_file_validate. Narrowed to match nothing, the four-field header is no
#    longer a comment and must be reported as malformed.
_saved=${HASH_COMMENT_RE-}
HASH_COMMENT_RE='^@@no-line-matches-this@@'
( hash_file_validate "$_fx" ) >/dev/null 2>&1
_st=$?
HASH_COMMENT_RE=$_saved
if ( hash_file_validate "$_fx" ) >/dev/null 2>&1 && [ "$_st" -ne 0 ]; then
  _pass "hash_file_validate validates a sidecar, and does it by reading the shared constant"
else
  _bad "hash_file_validate either rejected a well-formed sidecar, or ignored an\
 overridden HASH_COMMENT_RE and so still holds its own copy of the grammar"
fi

# 2. hash_lookup. Widened to cover the sha256 record, the lookup must skip the
#    very line it was asked for.
_saved=${HASH_COMMENT_RE-}
HASH_COMMENT_RE='^[[:space:]]*sha256'
_muted=$( hash_lookup "$_fx" demo-1.0.tar.gz sha256 )
HASH_COMMENT_RE=$_saved
if [ "$(hash_lookup "$_fx" demo-1.0.tar.gz sha256)" = "$_dgst" ] && [ -z "$_muted" ]; then
  _pass "hash_lookup reads a digest, and does it by reading the shared constant"
else
  _bad "hash_lookup either failed to read a well-formed sidecar, or ignored an\
 overridden HASH_COMMENT_RE (returned '$_muted') and so still holds its own copy"
fi

printf 'DONE: hash-comment-grammar\n'
exit "$_fail"
