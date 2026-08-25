#!/bin/sh
# In-tree citations in comments must name a FUNCTION or a SYMBOL, never a line.
#
# THE DEFECT CLASS THIS REMOVES. A comment that points at another place in this
# repository by line number is correct exactly once: at the moment it is
# written. Any edit above the cited line silently retargets it, nothing
# recomputes it, no gate reads it, and the next reader believes it because a
# comment in a source tree reads as verified. Twelve such defects were found on
# one branch, two of them introduced by the very commit that fixed the previous
# one, and one of those by a change made in the same file two hundred lines
# above the citation.
#
# A name does not have that failure mode. `save_stored_choices returns early
# under DRY_RUN` stays true when the function moves, and tells the reader what
# to look for rather than where to count to. If a symbol is ever renamed, grep
# finds the stale reference; nothing finds a stale line number.
#
# SCOPE: citations into THIS repository. An immutable external reference -- an
# upstream commit SHA, an RFC section, a released tarball's file:line -- does
# not rot and is deliberately allowed, which is why a candidate only counts
# when the name it cites resolves to a shell file that exists here.
#
# Usage: tests/comment-citations.sh
# Exit 0 = pass, 1 = regression.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT" || exit 1
_fail=0

_pass() { printf 'PASS [%s]\n' "$1"; }
_bad()  { printf 'FAIL [%s] %s\n' "$1" "${2-}" >&2; _fail=1; }

# Every shell filename that exists in this tree, one per line. Membership in
# this list is what separates an in-tree citation (rots) from an external one
# (does not), so the allowance for external references costs no maintenance:
# nothing has to be listed, and a file that leaves the tree stops being matched.
_tree_names=$(find . -name '*.sh' -not -path './.git/*' -print \
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
    while (match(_c, /[A-Za-z0-9_+.-]+\.sh:[0-9]+/)) {
      print FILENAME "|" FNR "|" substr(_c, RSTART, RLENGTH)
      _c = substr(_c, RSTART + RLENGTH + 1)
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
  _bad no-in-tree-line-number-citations "$_n comment(s) cite an in-tree file by line number; cite the function or symbol instead:$_offenders"
fi

printf 'DONE:\n'
exit "$_fail"
