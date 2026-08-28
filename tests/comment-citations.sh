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
# The scanner cannot trip over its own source: the pattern below is written as
# a regex, whose characters are not the literal shape it looks for, and it
# lives on a line that carries no "#" at all -- so this file is scanned like
# every other and reports nothing about itself.
_candidates=$(awk '
  {
    _h = index($0, "#")
    if (_h == 0) next
    _c = substr($0, _h)
    while (match(_c, /[A-Za-z0-9_+.-]+\.(sh|conf|md):[0-9]+/)) {
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

printf 'DONE:\n'
exit "$_fail"
