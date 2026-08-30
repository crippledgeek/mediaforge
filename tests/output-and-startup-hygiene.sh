#!/bin/sh
# Pins two things mediaforge must get right before it is allowed to say anything
# or delete anything: that its own output cannot be rewritten by the values it
# prints, and that it refuses to run at all when it cannot tell where it is.
#
# THE OUTPUT HALF. log/warn/die interpolate values mediaforge did not choose --
# paths, filenames, tool output, and the operator's own command line, which
# reaches die() verbatim in every "Unknown argument for X: $1". A CR or an ANSI
# escape inside one of those does not merely look wrong: it rewrites the line
# being read to diagnose the problem, so the diagnostic lies. lib/download.sh
# already carried this filter inline for describe_payload, where the text comes
# from whoever answered the request (GH-70); mf_printable is that same rule
# extracted, and describe_payload now calls it. This file asserts BOTH callers,
# because an extraction whose original still carries a private copy has added a
# third spelling rather than removed one.
#
# THE STARTUP HALF. $TOPDIR comes from `pwd`, and `pwd` fails when the working
# directory has been removed from under the shell -- `mkdir d; cd d; rmdir d` is
# the whole reproduction. Unguarded, $TOPDIR is empty, $DISTDIR becomes
# "/packages" and $PREFIX "/workspace", and every later `rm -rf` takes those
# literally. That exposure predates this branch, but the branch made it reachable
# from the DEFAULT `clean` rather than only from the flagged one, which is what
# put it in scope: the whole design rests on "the unflagged verb is the safe
# one".
#
# The assertions are behavioural where they can be. The sanitizer is checked by
# running mediaforge with an escape sequence in an argument and reading what
# comes back, not by grepping for a tr; the startup guard by actually deleting
# the working directory first. Only the shared-definition claim is structural,
# because "these two call the same helper" is not observable from outside.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

_tmp=$(mktemp -d) || { printf 'FAIL [tmpdir]\n' >&2; exit 1; }
trap 'rm -rf "$_tmp"' EXIT
_cleanup_on_signal

# --- the output half --------------------------------------------------------
# Guarded per HALF, not per file. The startup assertions below are about the
# $TOPDIR guard and have nothing to do with the sanitizer, so a tree carrying
# one and not the other must report the absent one and MEASURE the other --
# reporting "mf_printable is absent" against a $TOPDIR regression would send the
# next reader to the wrong file.
#
# The condition is a grep and not `command -v`: lib/utils.sh is not sourced
# until after this block, so a function-existence test here could only ever be
# false and would make the guard look stricter than it is.
_have_printable=true
grep -q 'mf_printable()' lib/utils.sh || _have_printable=false
if [ "$_have_printable" = false ]; then
  for _a in escape-stripped-from-a-fatal control-chars-stripped-from-a-warning \
            printable-text-survives newlines-survive-in-our-own-messages \
            message-survives-without-tr payload-description-is-one-line \
            payload-description-shares-the-helper reporters-share-the-helper; do
    _bad "$_a" "mf_printable is absent — claim would be vacuous"
  done
fi

if [ "$_have_printable" = true ]; then

# shellcheck source=lib/utils.sh
SCRIPT_DIR="$ROOT"
. "$ROOT/lib/utils.sh"

# A real ESC and a real CR, built with printf rather than written literally: a
# literal escape in a test file is invisible in every diff that reviews it.
_esc=$(printf '\033')
_cr=$(printf '\r')

# The whole point is the bytes that MOVE THE CURSOR, so the assertion is that
# they are gone -- not that some substitute appeared in their place.
_out=$( (die "boom${_esc}[2Kwiped") 2>&1 || true )
case "$_out" in
  *"$_esc"*) _bad escape-stripped-from-a-fatal "an ESC survived into a FATAL line" ;;
  *boom*wiped*) _pass escape-stripped-from-a-fatal ;;
  *) _bad escape-stripped-from-a-fatal "the message did not survive stripping: $_out" ;;
esac

# CR is the one an ANSI-stripping filter is most likely to miss, and on its own
# it is enough to overwrite a line from its start.
_out=$( (warn "before${_cr}after") 2>&1 || true )
case "$_out" in
  *"$_cr"*) _bad control-chars-stripped-from-a-warning "a CR survived into a WARNING line" ;;
  *before*after*) _pass control-chars-stripped-from-a-warning ;;
  *) _bad control-chars-stripped-from-a-warning "the message did not survive stripping: $_out" ;;
esac

# A filter that ate ordinary text would satisfy both assertions above while
# making every message useless, and TAB is the character most likely to be lost
# to a filter written as [:print:] alone.
_out=$(log "plain /path/to-file_1.2.tar.xz	tabbed" 2>&1 || true)
case "$_out" in
  *"plain /path/to-file_1.2.tar.xz	tabbed"*) _pass printable-text-survives ;;
  *) _bad printable-text-survives "ordinary text did not come through intact: $_out" ;;
esac

# R2, and the reason this file exists twice over: `[:print:]` does not include
# newline and `tr -d` DELETES rather than replaces, so the first version of
# mf_printable turned a two-line message into one line with the words jammed
# together at the seam ("hash file X:line two here"). Nineteen calls in lib/ pass
# deliberately multi-line text. The single-line needle above cannot see any of
# that, which is precisely what its own comment warned about -- a filter that
# eats ordinary text while both escape assertions stay green.
_out=$( (warn "first line
second line") 2>&1 || true )
case "$_out" in
  *"first line
second line"*) _pass newlines-survive-in-our-own-messages ;;
  *) _bad newlines-survive-in-our-own-messages "a deliberately multi-line message did not survive as two lines: $(printf '%s' "$_out" | tr '\n' '|')" ;;
esac

# The exception, and why the helper has two forms. describe_payload reports text
# an ORIGIN chose; a newline retained there would let it forge a line of its own,
# and a convincing `[mediaforge] ` one at that. So that path collapses newlines
# while ours keep them.
_multi=$(mf_printable_line "one
two")
case "$_multi" in
  *"
"*) _bad payload-description-is-one-line "mf_printable_line let a newline through, so an origin can forge a line" ;;
  onetwo) _pass payload-description-is-one-line ;;
  *) _bad payload-description-is-one-line "unexpected result from mf_printable_line: $_multi" ;;
esac

# The extraction actually replaced the original, and describe_payload is on the
# single-line form rather than the general one.
#
# Read through _code_only (tests/lib-assert.sh), because the first version of
# this grep matched the words in the COMMENT above the call: mutating the call
# from mf_printable_line to mf_printable left the assertion green, since the
# sentence explaining the choice still named it. A grep over shell source that
# does not strip comments is asking what the file SAYS, not what it does.
#
# With comments stripped, the bare name IS the call, so the needle needs no
# surrounding syntax -- which also keeps a `$(` out of a case pattern, where it
# would either be parsed as a command substitution or need single quotes that
# read as a mistake.
_dl_code=$(_code_only lib/download.sh)
case "$_dl_code" in
  *"tr -dc '[:print:][:blank:]'"*)
    _bad payload-description-shares-the-helper "lib/download.sh still carries its own printable filter" ;;
  *mf_printable_line*)
    _pass payload-description-shares-the-helper ;;
  *)
    _bad payload-description-shares-the-helper "describe_payload does not filter its text through mf_printable_line; an origin's newline could forge a line" ;;
esac

# All three reporters, not just the one that was easiest to reach. die() is the
# one that prints operator-supplied argv, log() the one that runs thousands of
# times -- a filter applied to some of them is a filter an attacker picks around.
_missing=''
for _fn in log warn die; do
  grep -qE "^$_fn\\(\\).*mf_printable" lib/utils.sh || _missing="$_missing $_fn"
done
if [ -z "$_missing" ]; then
  _pass reporters-share-the-helper
else
  _bad reporters-share-the-helper "these reporters print interpolated values unfiltered:$_missing"
fi

# The filter must not be able to EAT the message. Found by tests/ccache.sh
# rather than by this file: it runs mediaforge under a sandbox PATH containing
# only what its case needs, `tr` was not in it, and the first version of
# mf_printable turned every reported line into the empty string -- so `die`
# announced FATAL and said nothing about why. The message is the point; the
# filter is a precaution on top of it.
# A real but EMPTY directory as the whole search path, rather than a literal
# non-existent one: it is the shape tests/ccache.sh actually produces (a sandbox
# bin/ holding only what the case needs), and a `PATH=` assignment whose value is
# a bare literal is what SC2123 exists to catch.
mkdir -p "$_tmp/nobin"
_nopath="$_tmp/nobin"
_out=$( (PATH="$_nopath"; export PATH; die "cause worth keeping") 2>&1 || true )
case "$_out" in
  *"cause worth keeping"*) _pass message-survives-without-tr ;;
  *) _bad message-survives-without-tr "with no tr on PATH the reason was stripped from the message: $_out" ;;
esac

fi

# --- the startup half -------------------------------------------------------
# The working directory is removed while the shell is still in it, which is what
# makes `pwd` fail. Run in a subshell so this test's own cwd is not the casualty.
mkdir -p "$_tmp/gone"
_rc=0
_out=$( (cd "$_tmp/gone" && rmdir "$_tmp/gone" && "$ROOT/mediaforge.sh" clean) 2>&1 ) || _rc=$?
if [ "$_rc" -ne 0 ]; then
  _pass startup-refuses-a-deleted-workdir
else
  _bad startup-refuses-a-deleted-workdir "mediaforge ran to completion with no working directory, so \$TOPDIR was empty and /packages and /workspace were the targets: $(printf '%s' "$_out" | tr '\n' ' ')"
fi

# Refusing is not enough by itself: this failure is bewildering (every path in
# the message is wrong, or absent), so the refusal has to name the cause.
case "$(printf '%s' "$_out" | tr '\n' ' ')" in
  *"working directory"*) _pass startup-names-the-cause ;;
  *) _bad startup-names-the-cause "refused without naming the missing working directory: $(printf '%s' "$_out" | tr '\n' ' ')" ;;
esac

printf 'DONE: output-and-startup-hygiene\n'
exit "$_fail"
