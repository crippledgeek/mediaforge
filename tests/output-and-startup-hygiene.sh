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
# re-deriving it.
#
#
# _census's "no tree at $1" guard is equivalent for the same structural reason a
# guard usually is: it fires only when the caller is already wrong, so removing
# it changes nothing a correct tree can observe. Its test is the mutation that
# aims the census at a path that does not exist, which the guard turns from a
# clean-looking PASS into a named failure.
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
# they are probing.
#
# IT FOLLOWS A MESSAGE ACROSS LINES. A first version read only the line the
# reporter word sits on, and declared the tree clean while SIX em-dashes were
# still being deleted from lib/install.sh's die() messages -- among them the
# sudoers-policy diagnostic, the longest text in the tree and the one an
# operator reads when a privileged install has failed. So the awk below keeps a
# running double-quote parity and treats the whole quoted string as the
# argument. Per-line parity is not enough and was the bug: a continuation line
# carrying no quote at all is even, which reads as "the message ended here" and
# closed it after one line.
#
# COMMENTS ARE STRIPPED, and this catches nothing TODAY -- see the equivalent
# mutant registered at the top of this file. It is kept for the false ALARM it
# prevents, not a miss it catches.
#
# THE BYTE CLASS IS WRITTEN OUT rather than borrowed from the filter as
# `[^[:print:][:blank:]]`, because that spelling means different things to
# different greps. Measured 2026-09-02 on an em-dash: GNU grep 3.12 agrees with
# GNU coreutils tr 9.11 and matches it, but ugrep 7.8.4 -- which some shells,
# this harness's own included, shadow `grep` with -- treats 0x80-0xFF as
# printable under LC_ALL=C and matches nothing. Borrowing the class would make
# the census read clean on a tree full of em-dashes wherever such a grep answers
# first. The explicit range matches under both, which is the property wanted.
#
# WHAT IT DOES NOT SEE, all of it a miss rather than a false alarm except the
# first:
#   * the reporter word is not required to be in command position, so
#     `_msg="check the log -- really"`, a case label, or a heredoc body that
#     emits a generated script containing one would be reported as an offending
#     argument. No line in the tree has that shape today -- checked, including
#     every heredoc body in the walked files -- and it is the gap that can fail
#     a CORRECT tree, so it is the one to watch.
#   * a message assembled into a variable on one line and passed to a reporter
#     on another -- _pf_context in lib/install.sh is that shape. Seeing those
#     needs dataflow, not grep.
#   * a SINGLE-quoted message spanning lines. The scan tracks both quote kinds,
#     so nothing desyncs, but only a double quote marks a message as continuing;
#     the later lines of a `log '"'"'...'"'"'` written across two are not read. No
#     reporter in the tree takes a single-quoted argument.
#   * two reporter words on one line: awk match() is leftmost, so the tail is
#     kept from the FIRST -- and text between the two is therefore read as part
#     of the first message. No line in the tree has two.
_reporter_args() { # path to a shell file
  awk '
    # Cut a comment only where a comment can START: outside both quote kinds,
    # at line start or after whitespace. This is deliberately NOT _code_only,
    # which cuts at ANY `#` -- the same departure tests/signal-cleanup.sh makes
    # for its own question, and for the same reason: _code_only is right for a
    # caller asking "does this file contain X", and wrong for one carrying
    # state across lines. Truncating a warn whose argument holds a ${VAR#...}
    # takes the closing quote with it, the count goes odd, and every line after
    # it reads as message text until another odd line or EOF. That was live at
    # two sites, swallowing nine lines and twenty-seven, and it fails a CORRECT
    # tree -- the worse direction, since lib/resolve.sh menu labels are
    # legitimately non-ASCII and one new ${VAR#...} above them away from being
    # reported as broken messages.
    BEGIN { SQ = sprintf("%c", 39) }   # a literal quote here would end the program
    function code(s,   i, c, cut) {
      cut = length(s) + 1
      esc = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (esc)              { esc = 0; continue }
        if (c == "\\" && !sq) { esc = 1; continue }
        if (c == SQ && !dq)   { sq = !sq; continue }
        if (c == "\"" && !sq) { dq = !dq; continue }
        if (c == "#" && !dq && !sq && (i == 1 || substr(s, i - 1, 1) ~ /[ \t]/)) {
          cut = i
          break
        }
      }
      return substr(s, 1, cut - 1)
    }
    {
      # $dq carried from the previous line IS "we are inside a message". A
      # character scan rather than a quote count, because counting cannot see
      # which quote opened first: an awk -F option in lib/registry.sh and the
      # sed programs in lib/updates.sh each hold one double quote inside a
      # single-quoted span, and a counter reads those as opening a string.
      # Scanning also ends a message correctly at a trailing escaped backslash,
      # which a count reads as an escaped quote and follows past.
      was_in = dq
      line = code($0)
      if (!was_in) {
        emitting = 0
        if (match(line, /(^|[^[:alnum:]_])(log|warn|die)[ \t]+/)) {
          emitting = 1
          print substr(line, RSTART + RLENGTH)
        }
      } else if (emitting) {
        print line
      }
      if (!dq) emitting = 0
    }' "$1" | LC_ALL=C grep '[^[:blank:] -~]'
}

# The census takes the tree as a parameter and walks it through the shared
# helper, so the probe below runs THIS code rather than a second spelling of it.
# Three mutations survived an earlier shape -- a dead needle, an empty file
# list, and the needle never being called on the files -- and all three look
# exactly like a clean tree, because that is what a census reports by saying
# nothing.
_census() { # tree root
  # A root with no mediaforge.sh in it is a broken call, not a clean tree, and
  # the two are otherwise the same empty output: aiming this at a path that does
  # not exist left the assertion below green. It reports rather than returning,
  # so the caller reads it as an offender and says where it came from.
  if [ ! -f "$1/mediaforge.sh" ]; then
    printf 'census: no tree at %s\n' "$1"
    return
  fi
  for _oh_f in $(_tree_sh_files "$1"); do
    _reporter_args "$1/$_oh_f" | sed "s|^|$_oh_f: |"
  done
}

# A tree shaped like the real one, holding one offender of each shape the
# census has to survive. Because _tree_sh_files roots its globs at the tree it
# is given, this fixture IS the population rather than an intersection with the
# repo's filenames, so a planted file need not mirror a real one.
#
# Each file is here because a mutation lived without it:
#
#   mediaforge.sh   the single-line case, and the root the walk refuses to run
#                   without.
#   lib/multi.sh    a FOUR-line message with the offender on the third line.
#                   Neither two nor three lines can tell cumulative quote parity
#                   from per-line parity -- the shipped bug, which found two of
#                   lib/install.sh's six and missed the four inside its longest
#                   message. Per-line parity still prints line two, because the
#                   opening line already set the flag; it only loses the thread
#                   on the line AFTER a quote-less one, which is why the four
#                   it missed were all inside _place_file's sudoers-policy die
#                   in lib/install.sh -- the offending line there is the fourth
#                   of its message.
#   lib/escaped.sh  a message whose FIRST line carries an escaped quote and
#                   whose offender is on the second. One escaped quote is what
#                   flips that line's parity: counted raw it is even, so an
#                   unescaped count treats the message as finished and never
#                   reaches the offender. A single-line escaped message cannot
#                   show this -- two quotes and four are both even, so both
#                   spellings agree.
#   recipes/hwaccel/nested.sh
#                   the doubly-nested glob. Dropping `recipes/*/*.sh` from the
#                   walk stops scanning nearly every recipe in the real tree,
#                   and no other file here is deep enough to notice.
mkdir -p "$_tmp/census/lib" "$_tmp/census/recipes/hwaccel"
_em=$(printf '\342\200\224')
printf 'die "planted %s offender"\n' "$_em" > "$_tmp/census/mediaforge.sh"
printf 'die "first line\n  second line\n  third %s line\n  fourth line"\n' "$_em" \
  > "$_tmp/census/lib/multi.sh"
printf 'warn "opens with a \\" escape\n  then %s here"\n' "$_em" > "$_tmp/census/lib/escaped.sh"
printf 'log "nested %s offender"\n' "$_em" > "$_tmp/census/recipes/hwaccel/nested.sh"
# A bare parameter expansion BEFORE a call on the same line. Its `#` is outside
# quotes, which is where a comment can legally start -- only the preceding
# character says otherwise. Cutting on `#` alone truncates the line before the
# reporter and the message is never seen at all.
printf '_p=%s{_f#lib/}; warn "expanded %s offender"\n' '$' "$_em" \
  > "$_tmp/census/lib/expansion-then-call.sh"

_probe=$(_census "$_tmp/census")
_probe_missing=''
for _oh_want in 'mediaforge.sh: ' 'lib/multi.sh: ' 'lib/escaped.sh: ' \
                'lib/expansion-then-call.sh: ' 'recipes/hwaccel/nested.sh: '; do
  case "$_probe" in
    *"$_oh_want"*) ;;
    *) _probe_missing="$_probe_missing $_oh_want" ;;
  esac
done
if [ -z "$_probe_missing" ]; then
  _pass census-sees-a-planted-offender
elif [ -z "$_probe" ]; then
  _bad census-sees-a-planted-offender "the census reported nothing over a tree in which every message holds an em-dash, so its silence on the real tree is not evidence of anything"
else
  _bad census-sees-a-planted-offender "the census missed a planted offender in:$_probe_missing
it reported: $_probe"
fi

# The census must also stay SILENT where it should. Comment-stripping used to
# cut at any `#`, so `warn "  ${_st_f#"$1"}"` lost its closing quote, the state
# flipped on, and every line after it was reported as message text -- nine lines
# at one live site, twenty-seven at another. Nothing in the tree happened to be
# non-ASCII inside those windows, so the census stayed green while being one new
# parameter expansion away from failing a correct tree. The second file is the
# shape that fails a message-count: a double quote inside a single-quoted span,
# as lib/registry.sh and lib/updates.sh both carry.
mkdir -p "$_tmp/quiet/lib"
: > "$_tmp/quiet/mediaforge.sh"
# The `$` arrives as an argument so the literal parameter expansion this
# fixture is ABOUT does not read as one shellcheck should warn on.
printf 'warn "x %s{_v#pfx}"\n_label="menu %s label"\n' '$' "$_em" > "$_tmp/quiet/lib/expansion.sh"
printf 'log %s"-F%s\n_x="menu %s label"\n' "'" "'" "$_em" > "$_tmp/quiet/lib/sqspan.sh"
# A multi-line string that is NOT a reporter argument. Its later lines sit
# inside double quotes exactly as a message's do, so the only thing separating
# them is whether a reporter word opened the string -- and emitting on the quote
# state alone, without that, reports an ordinary assignment as a broken message.
# The completed reporter call on the first line matters: it is what leaves the
# emitting flag set, so a version that never clears it carries that state into
# the assignment below and reports its continuation as a broken message.
printf 'warn "a clean message"\n_x="a multi-line value\n  with %s a dash"\n' "$_em" \
  > "$_tmp/quiet/lib/notareporter.sh"
_quiet=$(_census "$_tmp/quiet")
if [ -z "$_quiet" ]; then
  _pass census-does-not-cry-wolf
else
  _bad census-does-not-cry-wolf "the census reported an offender in code that holds no reporter message, so a correct tree fails this gate:
$_quiet"
fi

_offenders=$(_census "$ROOT")
if [ -z "$_offenders" ]; then
  _pass reporter-text-survives-the-filter
else
  _bad reporter-text-survives-the-filter "these reporter arguments contain a byte mf_printable deletes, so the operator never sees it:
$_offenders"
fi

printf 'DONE: output-and-startup-hygiene\n'
exit "$_fail"
