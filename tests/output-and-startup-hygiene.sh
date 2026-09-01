#!/bin/sh
# Pins two things mediaforge must get right before it is allowed to say anything
# or delete anything: that its own output cannot be rewritten by the values it
# prints, and that it refuses to run at all when it cannot tell where it is.
#
# THE OUTPUT HALF. log/warn/die interpolate values mediaforge did not choose --
# paths, filenames, tool output, and the operator's own command line, which
# reaches die() verbatim in every "Unknown argument for X: $1". A CR or an ANSI
# escape inside one of those does not merely look wrong: it rewrites the line
# being read to diagnose the problem, so the diagnostic lies.
#
# There are TWO forms of the filter, and the difference is who wrote the text.
# mf_printable keeps newlines, because for our own messages the newline is
# formatting and the author is the reader; nineteen calls in lib/ pass
# deliberately multi-line text. mf_printable_line collapses them and fails
# closed, because its input is what an origin served or a remote API answered,
# and a newline there would let that text forge a line of its own -- a
# convincing `[mediaforge] ...` one -- inside the diagnostic an operator is
# reading to decide whether to trust a download.
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
# It probes with `version`, NOT with `clean`. The guard sits above the library
# sourcing and far above dispatch, so any subcommand exercises it identically --
# but tests/oracle-baseline.sh runs this file against the MERGE BASE, where
# there is no guard, and `clean` there would reach full_cleanup with an empty
# $TOPDIR and actually run `rm -rf /packages`. Harmless as an unprivileged user
# on a sane host, and still an absolute-path rm executed in the course of
# proving those paths must never be targeted.
#
# Every grep over shell source here reads through _code_only. Twice on this
# branch an assertion matched the words in a COMMENT rather than in the code --
# once in this file, found by mutation -- so a needle that has not had comments
# stripped is asking what a file SAYS, not what it does.
# EQUIVALENT MUTANTS -- registered so a later pass reads this rather than
# re-deriving it. Dropping _code_only from _reporter_args leaves the census
# green: the paragraphs in this tree that quote a reporter call verbatim now
# quote the ASCII form, so stripping comments removes nothing the needle would
# otherwise have matched. It is kept for the false ALARM it prevents -- the next
# paragraph to quote a call and then use a dash would fail a correct tree, and
# this repo's prose uses the dash throughout -- and it will stop being equivalent
# the moment one does.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

_tmp=$(mktemp -d) || { printf 'FAIL [tmpdir]\n' >&2; exit 1; }
trap 'rm -rf "$_tmp"' EXIT
_cleanup_on_signal

# --- the startup half -------------------------------------------------------
# First, and with no vacuity guard: a tree without the guard fails these two on
# their own terms rather than reporting them as unmeasurable, so the file needs
# no wrapper block spanning most of its length.
#
# The working directory is removed while the shell is still in it, which is what
# makes `pwd` fail. Run in a subshell so this test's own cwd is not the casualty.
mkdir -p "$_tmp/gone"
_rc=0
_out=$( (cd "$_tmp/gone" && rmdir "$_tmp/gone" && "$ROOT/mediaforge.sh" version) 2>&1 ) || _rc=$?
_said=$(printf '%s' "$_out" | tr '\n' ' ')
if [ "$_rc" -ne 0 ]; then
  _pass startup-refuses-a-deleted-workdir
else
  _bad startup-refuses-a-deleted-workdir "mediaforge ran with no working directory, so \$TOPDIR was empty and /packages and /workspace were the derived targets: $_said"
fi

# Refusing is not enough by itself: this failure is bewildering (every path in
# the message is wrong, or absent), so the refusal has to name the cause.
case "$_said" in
  *"working directory"*) _pass startup-names-the-cause ;;
  *) _bad startup-names-the-cause "refused without naming the missing working directory: $_said" ;;
esac

# --- the output half --------------------------------------------------------
# Anchored `^mf_printable()`, because an unanchored needle is satisfied by a doc
# comment naming the function after the function itself is gone -- and this file
# would then source lib/utils.sh, get empty output from every reporter, and
# report a pile of confusing failures instead of "the feature is absent".
if ! _lib_code | grep -q '^mf_printable()'; then
  for _a in escape-stripped-from-a-fatal control-chars-stripped-from-a-warning \
            printable-text-survives newlines-survive-in-our-own-messages \
            message-survives-without-tr line-form-fails-closed-without-tr \
            payload-description-is-one-line payload-description-shares-the-helper \
            remote-tag-is-filtered reporters-share-the-helper \
            filter-still-deletes-multibyte ascii-separator-survives \
            census-sees-a-planted-offender \
            reporter-text-survives-the-filter; do
    _bad "$_a" "mf_printable is absent — claim would be vacuous"
  done
  printf 'DONE: output-and-startup-hygiene\n'
  exit "$_fail"
fi

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

# `[:print:]` does not include newline and `tr -d` DELETES rather than replaces,
# so the first version of mf_printable turned a two-line message into one line
# with the words jammed together at the seam ("hash file X:line two here").
# Nineteen calls in lib/ pass deliberately multi-line text. The single-line
# needle above cannot see any of that -- which is exactly what its own comment
# warns about, a filter that eats ordinary text while both escape assertions
# stay green.
_out=$( (warn "first line
second line") 2>&1 || true )
case "$_out" in
  *"first line
second line"*) _pass newlines-survive-in-our-own-messages ;;
  *) _bad newlines-survive-in-our-own-messages "a deliberately multi-line message did not survive as two lines: $(printf '%s' "$_out" | tr '\n' '|')" ;;
esac

# The two forms diverge when `tr` is missing, and the direction is the point.
# OURS fails open: tests/ccache.sh runs mediaforge under a sandbox PATH holding
# only what its case needs, `tr` was not in it, and the first version of this
# helper made `die` announce FATAL and say nothing about why. Losing the reason
# is worse than an unfiltered byte the operator typed themselves.
_nopath="$_tmp/nobin"
mkdir -p "$_nopath"
_out=$( (PATH="$_nopath"; export PATH; die "cause worth keeping") 2>&1 || true )
case "$_out" in
  *"cause worth keeping"*) _pass message-survives-without-tr ;;
  *) _bad message-survives-without-tr "with no tr on PATH the reason was stripped from the message: $_out" ;;
esac

# THEIRS fails closed, for the same reason in reverse: the author is remote, so
# returning the raw string would drop newline, ESC and CR stripping together in
# precisely the adversarial case the form exists for. One missing diagnostic
# line in an environment with no `tr` is the cheaper half of that trade, and
# describe_payload already returns early on an empty description.
_line=$( (PATH="$_nopath"; export PATH; mf_printable_line "raw${_esc}[2K bytes") 2>&1 || true )
if [ -z "$_line" ]; then
  _pass line-form-fails-closed-without-tr
else
  _bad line-form-fails-closed-without-tr "with no tr on PATH an origin's text came back unfiltered: $_line"
fi

# The collapsing itself.
_multi=$(mf_printable_line "one
two")
case "$_multi" in
  *"
"*) _bad payload-description-is-one-line "mf_printable_line let a newline through, so an origin can forge a line" ;;
  onetwo) _pass payload-description-is-one-line ;;
  *) _bad payload-description-is-one-line "unexpected result from mf_printable_line: $_multi" ;;
esac

# The extraction actually replaced the original, and describe_payload is on the
# single-line form rather than the general one. Read through _code_only: the
# first version of this matched the words in the COMMENT above the call, so
# mutating the call from mf_printable_line to mf_printable left it green.
_dl_code=$(_code_only "$ROOT/lib/download.sh")
case "$_dl_code" in
  *"tr -dc '[:print:][:blank:]'"*)
    _bad payload-description-shares-the-helper "lib/download.sh still carries its own printable filter" ;;
  *mf_printable_line*)
    _pass payload-description-shares-the-helper ;;
  *)
    _bad payload-description-shares-the-helper "describe_payload does not filter its text through mf_printable_line; an origin's newline could forge a line" ;;
esac

# The other remote-text path, and it is not a download at all. check_updates
# prints a tag captured out of a GitHub API response into a COLUMN-ALIGNED
# table, where a CR rewrites the rows already drawn above it rather than only
# its own cell. Asserted through the one function both of _github_latest's
# extraction paths end in.
# shellcheck source=lib/updates.sh
. "$ROOT/lib/updates.sh"
_tag=$(_strip_tag_prefix "v1.2.3${_cr}fake row")
case "$_tag" in
  *"$_cr"*) _bad remote-tag-is-filtered "a CR in a GitHub tag reached the version table: $_tag" ;;
  "1.2.3fake row") _pass remote-tag-is-filtered ;;
  *) _bad remote-tag-is-filtered "unexpected stripped tag: $_tag" ;;
esac

# All three reporters, not just the one that was easiest to reach. die() is the
# one that prints operator-supplied argv, log() the one that runs thousands of
# times -- a filter applied to some of them is a filter an attacker picks around.
_missing=''
for _fn in log warn die; do
  _code_only "$ROOT/lib/utils.sh" | grep -qE "^$_fn\(\).*mf_printable" || _missing="$_missing $_fn"
done
if [ -z "$_missing" ]; then
  _pass reporters-share-the-helper
else
  _bad reporters-share-the-helper "these reporters print interpolated values unfiltered:$_missing"
fi

# --- what the reporters are allowed to SAY ---------------------------------
# The filter above is byte-defined on purpose, and the cost of that is paid
# here: `[:print:]` in the C locale is 0x20-0x7E, every byte of a multibyte
# UTF-8 character is outside it, and `tr -d` deletes rather than replaces. An
# em-dash written into a die() message is therefore gone before any operator
# sees it, leaving the two spaces that surrounded it:
#
#   [mediaforge] FATAL: No stamps at .../.stamps  run 'mediaforge.sh build' first
#
# Two spellings would fix that and only one is safe. Relaxing the filter to
# admit printable multibyte cannot be done with a byte class: C1 controls are
# 0x80-0x9F and UTF-8 continuation bytes are 0x80-0xBF, so they overlap. The
# em-dash U+2014 is E2 80 94 -- both of its continuation bytes sit inside C1 --
# and no `tr` range separates "the tail of a character" from "a bare CSI on a
# terminal in an 8-bit locale". Telling them apart needs a UTF-8 decoder, and
# it would widen mf_printable_line, the form whose input is written by whoever
# answers a request. So the filter stays strict and the call sites stay ASCII.
#
# That decision is only worth anything if it holds, which is what these two
# assert: the filter still deletes what the decision assumes it deletes, and no
# reporter argument in the tree contains such a byte.
_out=$(log "em—dash" 2>&1 || true)
case "$_out" in
  *"em—dash"*) _bad filter-still-deletes-multibyte "mf_printable now passes multibyte through; the ASCII-only rule below rests on it not doing that, so the trade in lib/utils.sh needs re-deciding rather than this assertion relaxing" ;;
  *"emdash"*) _pass filter-still-deletes-multibyte ;;
  *) _bad filter-still-deletes-multibyte "unexpected result from a multibyte message: $_out" ;;
esac

# The ASCII separator the call sites use instead, asserted through die() --
# the reporter that prints on a fresh checkout, and the one the issue's example
# came from.
_out=$( (die "No stamps -- run build first") 2>&1 || true )
case "$_out" in
  *"No stamps -- run build first"*) _pass ascii-separator-survives ;;
  *) _bad ascii-separator-survives "the ASCII separator did not survive the filter: $_out" ;;
esac

# The census, as one function so the probes below cannot drift from the thing
# they are probing. Three things about how it is spelled:
#
# THE ARGUMENT, NOT THE LINE. lib/resolve.sh builds menu_radiolist labels that
# end `) || die "H.264 prompt cancelled"`, and those labels reach the terminal
# through lib/menu.sh's own printf, never through this filter -- their em-dashes
# render correctly today. A line-granular census demands four correct lines be
# changed, so the needle keeps only the tail from the last reporter command word
# onward. A second reporter earlier on the same line is the gap that leaves;
# reporters end statements here (die exits, `|| warn "..."` terminates), so the
# shape does not occur, and a continuation line of a multi-line message is
# likewise unseen.
#
# THE BYTE CLASS IS WRITTEN OUT rather than borrowed from the filter, because
# GNU grep and GNU tr DISAGREE about `[:print:]` under LC_ALL=C: grep counts
# 0x80-0xFF as printable, tr does not. Asking grep for "what tr deletes" in tr's
# own words returns nothing at all, and the census reads as clean on a tree full
# of em-dashes.
#
# COMMENTS ARE STRIPPED, and this is the one of the three that catches nothing
# TODAY -- mutation removing _code_only left the census green, because the
# paragraphs quoting a reporter call verbatim now quote the ASCII form. It stays
# because the failure it prevents is a false ALARM rather than a miss: the next
# paragraph to quote a call and then use a dash would fail a correct tree, and
# this repo's prose uses the dash throughout. _code_only's truncation runs the
# other way -- it cuts at a `#` inside a string too, so a message containing one
# could hide a later em-dash. That is a missed offender, and a cosmetic one.
#
# The path is a parameter rather than something read out of $ROOT. `VAR=x fn`
# is not a scoped assignment when fn is a FUNCTION -- POSIX keeps it in the
# shell afterwards -- so a probe calling this as `ROOT="$_tmp" _reporter_args`
# silently redirected every later assertion at the temp dir, and the census
# scanned nothing and passed. That was written here, and caught by the two
# assertions below.
_reporter_args() { # path to a shell file
  _code_only "$1" \
    | sed -n -E 's/^(.*[^[:alnum:]_])?(log|warn|die)[[:space:]]+//p' \
    | LC_ALL=C grep '[^[:blank:] -~]'
}

# The census itself takes the tree as a parameter, so the probe below runs THIS
# loop rather than a second spelling of it. Three separate mutations survived
# the earlier shape -- a dead needle, an empty file list, and the needle simply
# not being called on the files -- and each of them looks exactly like a clean
# tree, because that is what a census reports by saying nothing. A probe that
# re-implements the walk cannot see any of the three.
_census() { # tree root
  for _oh_f in mediaforge.sh lib/*.sh recipes/*.sh recipes/*/*.sh; do
    [ -f "$1/$_oh_f" ] || continue
    _reporter_args "$1/$_oh_f" | sed "s|^|$_oh_f: |"
  done
}

# A tree shaped like the real one, holding one message with an em-dash in it.
# It is the whole population, so a walk that opens nothing and a needle that
# matches nothing both show up here as silence where an offender was planted.
mkdir -p "$_tmp/census/lib" "$_tmp/census/recipes/hwaccel"
printf 'die "planted %s offender"\n' "$(printf '\342\200\224')" > "$_tmp/census/mediaforge.sh"
: > "$_tmp/census/lib/utils.sh"
: > "$_tmp/census/recipes/hwaccel/nv-codec.sh"
_probe=$(_census "$_tmp/census")
case "$_probe" in
  *"mediaforge.sh: "*"planted"*) _pass census-sees-a-planted-offender ;;
  '') _bad census-sees-a-planted-offender "the census reported nothing over a tree whose only message holds an em-dash, so its silence on the real tree is not evidence of anything" ;;
  *) _bad census-sees-a-planted-offender "the census found something other than the planted offender: $_probe" ;;
esac

_offenders=$(_census "$ROOT")
if [ -z "$_offenders" ]; then
  _pass reporter-text-survives-the-filter
else
  _bad reporter-text-survives-the-filter "these reporter arguments contain a byte mf_printable deletes, so the operator never sees it:
$_offenders"
fi

printf 'DONE: output-and-startup-hygiene\n'
exit "$_fail"
