#!/bin/sh
# In-tree citations in comments must name a FUNCTION or a SYMBOL, never a line.
#
# THE DEFECT CLASS THIS REMOVES. A comment that points at another place in this
# repository by line number is correct exactly once: at the moment it is
# written. Any edit above the cited line silently retargets it, nothing
# recomputes it, no gate reads it, and the next reader believes it because a
# comment in a source tree reads as verified. This gate found FIFTEEN in-tree
# citations on the branch that introduced it, and TWO of them were already stale
# when it found them -- both naming a line in mediaforge.sh that the -fPIC export
# had since moved away from. That is the argument for the gate, and unlike a
# count of "defects" it is a claim a reader can check against the gate's own
# output.
#
# A name does not have that failure mode. `save_stored_choices returns early
# under DRY_RUN` stays true when the function moves, and tells the reader what
# to look for rather than where to count to. If a symbol is ever renamed, grep
# finds the stale reference; nothing finds a stale line number.
#
# SCOPE: citations into THIS repository. An immutable external reference -- an
# upstream commit SHA, an RFC section, a released tarball's file:line -- does
# not rot and is deliberately allowed, which is why a candidate only counts
# when the name it cites resolves to a file that exists here.
#
# Not only shell files. recipes/_order.conf gains a line whenever a recipe is
# added, and README.md is edited constantly, so a citation into either has the
# same rot profile as one into a function -- worse, since neither carries
# symbols to cite instead. The extension class covers all three; the
# file-exists check below is what keeps that from producing false positives.
#
# Usage: tests/comment-citations.sh
# Exit 0 = pass, 1 = regression.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT" || exit 1
_fail=0

# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

# Every filename in this repository's OWN sources, one per line. Membership in
# this list is what separates an in-tree citation (rots) from an external one
# (does not), so the allowance for external references costs no maintenance:
# nothing has to be listed, and a file that leaves the tree stops being matched.
#
# SCOPED TO THE SOURCE DIRECTORIES, not `find .`. $DISTDIR (packages/) and
# $PREFIX (workspace/) hold the extracted sources of ~80 third-party projects,
# so a bare tree walk returns thousands of names on a machine that has built and
# a hundred-odd on a clean checkout. The comparison is by basename, so those
# names ARE the predicate: an entirely legitimate citation into an upstream
# ltmain.sh or autogen.sh would be reported as an offender for developers who
# have built and not for anyone else. Nothing trips that today, which is exactly
# why it had to be fixed before something did -- a gate whose verdict depends on
# gitignored state is not a gate.
#
# `git ls-files` would be the obvious scoping, and is deliberately not used:
# tests/oracle-baseline.sh runs this file inside a `git archive` export, which
# is a plain directory with no repository to ask.
_tree_names=$( { find ./lib ./recipes ./tests ./patches ./profiles -type f -print 2>/dev/null
                 find . -maxdepth 1 -type f -print; } \
               | awk -F/ '{ print $NF }' | sort -u)

# Candidate citations: on each line, only the text from the first "#" onward is
# considered, so a filename appearing in code (a path being built, an argument)
# is not a comment and is not this rule's business.
#
# The colon does not have to touch the filename. A citation that puts blanks or
# an opening paren between the two halves has the same rot profile, and one went
# stale in-tree while this gate read past it -- the commit that wrote it had
# inserted a source line above the line it named. Both are allowed between the
# halves for that reason.
#
# Widening the pattern was not enough on its own, and shipped inert once: the
# match succeeded and the name check then threw it away, because the text
# between the halves is still attached to the name at that point. See the strip
# below. That is also why the fixture assertion exists -- a scanner is not
# exercised by a clean tree, so "the tree is clean" passes identically whether
# it works or does nothing at all.
#
# The scanner cannot trip over its own source: the pattern below is written as
# a regex, whose characters are not the literal shape it looks for, and it
# lives on a line that carries no "#" at all -- so this file is scanned like
# every other and reports nothing about itself.
_candidates=$(awk '
  {
    _h = index($0, "#")
    if (_h == 0) next
    _c = substr($0, _h)
    while (match(_c, /[A-Za-z0-9_+.-]+\.(sh|conf|md)[ \t]*[(]?:[0-9]+/)) {
      print FILENAME "|" FNR "|" substr(_c, RSTART, RLENGTH)
      _c = substr(_c, RSTART + RLENGTH)
    }
  }
' ./mediaforge.sh ./lib/*.sh ./recipes/*.sh ./recipes/*/*.sh ./tests/*.sh)

_offenders=""
_n=0
# IFS is set to newline for the loop only: a citation record carries no spaces,
# but the surrounding fields are paths and the default split would be wrong the
# first time one contains a space.
_oldifs=$IFS
IFS='
'
for _rec in $_candidates; do
  [ -n "$_rec" ] || continue
  _cite=${_rec##*|}
  _name=${_cite%%:*}
  # The widened match keeps whatever sits between the filename and the colon,
  # so a paren spelling arrives here as "utils.sh (" and matches no tree name.
  # Stripping it is what makes the widening do anything at all: without this
  # line the scanner finds the candidate and silently discards it, and the gate
  # reports the same clean tree it reported before the pattern changed.
  _name=${_name%%[ (]*}
  _name=${_name##*/}
  for _known in $_tree_names; do
    if [ "$_known" = "$_name" ]; then
      _n=$((_n + 1))
      _offenders="$_offenders
    ${_rec%%|*}:${_rec#*|} -> ${_cite}"
      break
    fi
  done
done
IFS=$_oldifs

if [ "$_n" -eq 0 ]; then
  _pass no-in-tree-line-number-citations
else
  # The offender list prints separately rather than as the _bad detail: the
  # shared reporter flattens newlines (see tests/lib-assert.sh), which is right
  # for a one-line message and would run this list into a single unreadable line.
  _bad no-in-tree-line-number-citations "$_n comment(s) cite an in-tree file by line number; cite the function or symbol instead"
  # $_offenders is built by prepending "\n    ..." per hit, so it opens with an
  # empty line; drop the blanks rather than the leading newline, which is what
  # keeps one offender per line.
  printf '%s\n' "$_offenders" | sed '/^[[:space:]]*$/d' >&2
fi

# ─── the fixture does not run itself ────────────────────────────────────────
# Skipped when this file is the one under test. The fixture RUNS the scanner,
# and a scanner that runs its own fixture runs a scanner that runs its own
# fixture: measured, that fork-bombs the machine until nothing can spawn. The
# guard is on the inner run, so the outer one still asserts.
if [ -n "${MF_CITATIONS_FIXTURE:-}" ]; then
  # Announced, not silent, matching tests/pc-exclusions-durable.sh's root
  # branch: a run that quietly drops an assertion looks identical to one that
  # made it.
  printf 'SKIP: scanner fixture (this run IS the fixture)\n'
  printf 'DONE:\n'
  exit "$_fail"
fi
# ─── the scanner detects, on a tree that is not clean ───────────────────────
# The assertion above is about the repository; this one is about the gate. They
# fail for opposite reasons and neither implies the other: a scanner that
# matched nothing at all would pass the first one on every tree forever, which
# is exactly what happened when the pattern was widened without this.
#
# Both spellings, because the widening is the part with no other coverage.
_fx=$(mktemp -d) || exit 1
# Every directory and glob the scanner names has to exist and match something:
# it passes ./mediaforge.sh ./lib/*.sh ./recipes/*.sh ./recipes/*/*.sh
# ./tests/*.sh to awk, and an unmatched glob reaches awk as a literal path it
# dies on. A fixture that cannot run the scanner proves nothing about it.
mkdir -p "$_fx/lib" "$_fx/tests" "$_fx/recipes/sub" "$_fx/patches" "$_fx/profiles"
cp "$ROOT/tests/comment-citations.sh" "$ROOT/tests/lib-assert.sh" "$_fx/tests/"
# Two citations naming a file that exists in the fixture tree, one in each
# spelling, plus one negative case for EACH predicate that can reject a
# candidate. They have to be different shapes, because they are rejected at
# different stages and a case that dies at the first one says nothing about the
# second: ltmain.sh carries an extension the scanner matches and a name the
# fixture tree lacks, so only the tree-name check can reject it, and
# libavcodec.c EXISTS in the fixture tree and is rejected by the extension
# class alone -- it has to exist, or the tree-name check rejects it first and
# the extension class goes untested. Measured: with a .c file absent from the
# tree, widening the class to accept .c leaves this assertion green.
#
# The first draft used only the .c case and called it "an external reference".
# It was rejected by the regex, so the tree-name membership check -- the thing
# the SCOPE paragraph above spends a paragraph justifying -- had no coverage at
# all: deleting it left this assertion green.
#
# The hash comes from a variable so that the line WRITING these citations
# carries none itself. The scanner reads from the first hash on a line onward,
# it scans this file like any other, and a line holding both a hash and a
# citation would be reported -- this file failing its own gate, over a fixture.
# The header makes the same point about the pattern a few lines up.
_hash='#'
printf '%s!/bin/sh\n%s see utils.sh:17\n%s and utils.sh (:26)\n%s and ltmain.sh:42\n%s and libavcodec.c:99\n' \
  "$_hash" "$_hash" "$_hash" "$_hash" "$_hash" > "$_fx/lib/probe.sh"
printf '%s!/bin/sh\n' "$_hash" > "$_fx/lib/utils.sh"
: > "$_fx/lib/libavcodec.c"
for _stub in mediaforge.sh recipes/stub.sh recipes/sub/stub.sh; do
  printf '%s!/bin/sh\n' "$_hash" > "$_fx/$_stub"
done
_fx_out=$( cd "$_fx" && MF_CITATIONS_FIXTURE=1 sh tests/comment-citations.sh 2>&1 )
_fx_rc=$?
# Exactly two: both utils.sh spellings, and neither negative case.
if [ "$_fx_rc" -ne 0 ] && printf '%s\n' "$_fx_out" | grep -q '2 comment(s) cite'; then
  _pass the-scanner-reports-both-spellings-and-neither-negative-case
else
  _bad the-scanner-reports-both-spellings-and-neither-negative-case \
    "rc=$_fx_rc, said: $(printf '%s' "$_fx_out" | tr '\n' ' ')"
fi
rm -rf "$_fx"

printf 'DONE:\n'
exit "$_fail"
