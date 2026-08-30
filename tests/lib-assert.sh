# shellcheck shell=sh
# The assertion reporters, defined ONCE.
#
# Sourced by path from the test that uses it, and requires that test to have
# initialised $_fail to 0 -- _bad sets it, and the caller exits with it.
#
# Called as `_pass <assertion-name>`, `_bad <assertion-name> "<detail>"`, or
# `_bad <assertion-name>` where the name is the whole claim and there is no
# detail to add -- the majority shape in tests/install-manifest-reconcile.sh,
# whose _pass and _bad said the same sentence before they had names. The name is
# what the reporter prints, so it should read as the claim being made
# ("symlinked-leaf-replaced-not-followed"), not as a restatement of the detail.
#
# Before this file existed the pair was copy-pasted into every test that wanted
# it, in three spellings, and the copies drifted. Of the seven that already used
# this file's `FAIL [<name>] <detail>` shape, five omitted the `tr '\n' ' '`
# below and two did not. That is not cosmetic. tests/oracle-baseline.sh measures
# a newly added test by COUNTING assertion lines, and the BASELINE run is
# counted with `grep -c '^PASS'` and `grep -c '^FAIL'` separately (the combined
# `^(PASS|FAIL)` pattern counts the current tree, not the base). So a detail
# line that happens to begin with `PASS` -- an assertion name quoted back inside
# a failure message, say -- is counted as an assertion that passed on the base,
# and the gate reports the file as an offender that cannot be detecting its
# change. Flattening the detail to one line is what makes the count mean what
# the gate thinks it means.
#
# A third spelling (`FAIL: <sentence>` on stdout, with no assertion name) was
# converged over two changes -- #45 took tests/hash-comment-grammar.sh, #46 the
# last six -- which is why no file outside this one defines the pair any more.
# #48 then took the twelve that defined nothing but inlined the printf at each
# call site instead, which no definition-grep could see.
# `grep -rnE '_pass\(\)|_bad\(\)' tests/` is the check -- ERE, because `\|`
# alternation is a GNU extension a BSD grep silently matches nothing with, and
# unanchored, so an indented redefinition inside a function or a file that
# copied only _bad is caught too. It answers "does anything else DEFINE the
# pair", which is narrower than this paragraph's subject: a test that inlines
# `printf 'PASS ...'` at each call site is a copy that no definition-grep can
# see, and `grep -rnE "printf '(PASS|FAIL)" tests/` is the complement that
# finds those. No file census is written here: the enumeration this header used
# to carry drifted twice in three commits, and a grep does not.
#
# FAIL goes to stderr and PASS to stdout, so a caller can read the failures
# alone. oracle-baseline captures both (`sh "$_f" 2>&1`), so the split does not
# hide an assertion from it.
#
# Evidence for a failure detail: at most $1 lines of the log on stdin matching
# the ERE $2, falling back to the LAST $1 lines when nothing matches -- or when
# grep cannot run the pattern at all, which is the same answer for the same
# reason -- so a detail is never empty and never unbounded. A malformed ERE is
# not silent (grep says so on stderr, beside the FAIL line), but _evidence only
# runs once a test has already failed, so a broken pattern lies dormant until
# the moment the diagnosis is wanted. Every pattern in-tree is a fixed literal;
# a computed one would want checking here first. Both failures were real. A grep for
# 'monoton|error' finds nothing when an encoder fails some other way, leaving
# `FAIL [name]` with no diagnosis at all; and an uncapped `cat` of a linker log
# becomes one flattened multi-kilobyte line, since _bad collapses newlines.
#
# `grep -- "$2"` so a pattern beginning with a dash (`-L`) is read as a pattern
# rather than as options: without it `grep -iE "-L"` takes -L as
# --files-without-match and prints "(standard input)" instead of the match.
_evidence() {
  _ev=$(cat)
  _ev_hit=$(printf '%s\n' "$_ev" | grep -iE -- "$2" | head -n "$1")
  [ -n "$_ev_hit" ] || _ev_hit=$(printf '%s\n' "$_ev" | tail -n "$1")
  printf '%s' "$_ev_hit"
}

# Cleanup that also runs when the RUN IS INTERRUPTED, not only when it ends.
#
# A file that registers `trap ... EXIT` alone has cleanup that depends on the
# interpreter. Measured 2026-08-29 against a script holding a mktemp -d, sent
# SIGTERM:
#
#     dash   the directory SURVIVED -- the EXIT trap never ran
#     bash   the directory was removed -- the EXIT trap ran
#
# mediaforge is POSIX sh so that it runs where /bin/sh is dash, which is where
# the leak is real; a host whose /bin/sh is bash cannot see it. Eight files were
# written that way (GH-64). What leaks is whatever the file put in TMPDIR, and
# TMPDIR is tmpfs on many systems, so the cost is RAM rather than disk.
#
# This registers the SIGNAL half only, and every caller keeps its own EXIT
# handler: POSIX `trap` has no append form, so a shared EXIT registration here
# would silently replace the caller's -- the same reason tests/lib-scratch.sh
# gives for registering none.
#
# Exiting from the handler, rather than cleaning up in it, is what makes one
# handler enough: the exit runs the caller's EXIT trap, whatever that file has
# to remove. 130 and 143 are the conventional 128+signum statuses, and the form
# is the one tests/hash-comment-grammar.sh and tests/signing-keys.sh already
# use -- this converges on the idiom rather than adding a ninth.
#
# NOT for a SIGKILL, which no shell can trap. A run killed by the OOM killer
# leaves its temporary tree behind no matter what is registered here.
_cleanup_on_signal() {
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

_pass() { printf 'PASS [%s]\n' "$1"; }
_bad() {
  if [ "$#" -ge 2 ]; then
    printf 'FAIL [%s] %s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ')" >&2
  else
    printf 'FAIL [%s]\n' "$1" >&2
  fi
  _fail=1
}

# The verdict of a COMPOUND assertion: several things had to hold, and the
# caller accumulated one sentence into REASONS for each that did not. REASONS
# is REQUIRED -- empty means every half held, and a caller that omits it aborts
# under `set -u` rather than passing quietly, which is the right way round for
# what is always a mistake. (_bad's one-argument form does not extend here: a
# verdict with no accumulator has nothing to decide.)
#
# `if [ -z "$_wrong" ]; then _pass NAME; else _bad NAME "$_wrong"; fi` is the
# shape a multi-part claim ends with WHEN THE ACCUMULATOR IS THE DETAIL, and it
# was written out at every such site -- including four times in
# tests/assert-reporter.sh, which exists to pin this library. Where the detail
# is DECORATED (`_bad NAME "not ignored:$_uncovered"`, a head -3 of it, a
# three-way elif ladder) the site keeps its own `if`: what varies there is the
# wording, not the mechanism. Those sites are legitimately in that state; this
# helper has not converged them and should not.
#
# Two greps, because one only sees what it already took: `grep -rn _verdict
# tests/` finds the converted sites, and
# `grep -rnE 'if \[ -z "\$_[a-z_]+" \]' tests/` finds the candidates it has
# not. That is the same blind spot this file names above for _pass/_bad, and it
# gets the same complement rather than a list that rots.
#
# The accumulate-then-report shape is what lets one assertion state a claim
# with several halves and still report ONE line, which is what
# tests/oracle-baseline.sh counts -- reporting each half separately would let
# the halves that are unchanged behaviour pass on the merge base.
_verdict() { # name  reasons
  if [ -z "$2" ]; then
    _pass "$1"
  else
    _bad "$1" "$2"
  fi
}

# Glob-match reporters. The pattern "run something, glob-match the result,
# _pass or _bad with the actual value in the detail" was written five times
# across tests/compiler-flags.sh and tests/debug-levels.sh, in two polarities.
# It is the same convergence the reporters themselves went through in #45/#46/
# #48: the copies agreed only by inspection, and the detail string -- the thing
# a reader sees when a test fails -- had already drifted between them.
#
# $3 is a GLOB by design, so it is deliberately unquoted in the case. The caller
# passes the actual value in $2 and a describing prefix in $4, so the failure
# line says what was fed in as well as what came out.
#
# NOTE the polarity trap these replaced: a "must NOT match" check is satisfied by
# the empty string, so on a tree lacking the feature it passes having verified
# nothing. _glob_not therefore FAILS on empty input rather than passing, and
# callers that can legitimately produce empty must say so before calling.
_glob() { # name  actual  glob  detail-prefix
  # shellcheck disable=SC2254
  case "$2" in
    $3) _pass "$1" ;;
    *)  _bad "$1" "$4 got=[$2]" ;;
  esac
}

_glob_not() { # name  actual  glob  detail-prefix
  if [ -z "$2" ]; then
    _bad "$1" "$4 produced nothing — a negative claim on empty input is vacuous"
    return
  fi
  # shellcheck disable=SC2254
  case "$2" in
    $3) _bad "$1" "$4 got=[$2]" ;;
    *)  _pass "$1" ;;
  esac
}

# A file's CODE, with its prose removed: everything from an unquoted `#` to end
# of line, plus the leading whitespace before it.
#
# Every caller wants it for one reason. A recipe that stopped doing X almost
# always gains a COMMENT explaining that it used to do X and why it no longer
# does -- so an assertion grepping for X matches the explanation and fails on
# the fixed tree, reporting the fix as the defect. Stripping comments first is
# what makes "this file does not do X" mean the code rather than the prose.
#
# Extracted once there were six character-identical copies across two files
# (three in tests/git-commit-pinning.sh, three in tests/generated-archive-urls.sh,
# the latter added by GH-69). They agreed only by inspection.
#
# KNOWN LIMIT, inherited unchanged from those copies: this is a text strip, not
# a shell parser, so a `#` inside a quoted value truncates the line early -- a
# URL fragment (`.../x.tar.gz#sha=...`) or a literal `#` in a flag would lose
# everything after it. That direction is safe for the assertions in-tree, which
# all ask "does the code contain X": losing trailing text can only produce a
# false NEGATIVE on the match, never a false positive that passes a file the
# grep should have caught. A caller asking the opposite question -- "the code
# must CONTAIN this" -- has to consider it, which is why it is stated here
# rather than left to be rediscovered.
_code_only() { # file
  sed 's/[[:space:]]*#.*$//' "$1"
}

# Every file in lib/, comments stripped, as one stream. Requires the caller to
# have set $ROOT, the same caller contract this file's header already states for
# $_fail.
#
# Here rather than in each test because two of them grew identical copies within
# two commits of each other -- and because the question they both ask is one a
# plain grep answers WRONGLY: counting a call site or a forbidden idiom across
# lib/ has to read what the files DO, and prose in this repo quotes calls
# verbatim as a habit. Naming individual files is the other half of the trap: a
# copy can grow in a file the list does not mention.
_lib_code() {
  for _lc_f in "$ROOT"/lib/*.sh; do
    _code_only "$_lc_f"
  done
}

# The value of a top-level shell assignment, read out of a file rather than by
# sourcing it. `_shell_var profiles/ffmpeg-8.0.1.conf PKG_COMMIT_X264`.
#
# Sourcing is what this exists to avoid: a profile or a recipe is shell, so
# reading it that way executes it, and a recipe additionally expects framework
# state a test does not have. Reading the text answers the narrower question a
# test actually asks -- "what does the FILE say" -- and a value the file never
# sets comes back empty, which every caller already distinguishes.
#
# Extracted once there were FIVE call sites in two files, in THREE spellings:
# the keyword-parameterised form twice in tests/git-commit-pinning.sh, a
# hardcoded `/^PKG_COMMIT_LIBRIST=/` beside them, a hardcoded `/^PKG_NAME=/` in
# tests/recipe-identity.sh, and -- the one an earlier count of this note missed
# -- a `/^PKG_COMMIT=/` that printed `$0` rather than `$2`.
#
# That fifth is the interesting one, because it is the only site whose semantics
# the extraction CHANGED: whole line to first quoted field. Its caller (the
# librist pin assertion) therefore still greps the SHA out of the result, and
# would be wrong if it did not.
#
# Returns the FIRST double-quoted field, so the answer for a defaulted
# assignment (`PKG_COMMIT="${PKG_COMMIT_LIBRIST:-<sha>}"`) is the whole
# `${...:-...}` expression rather than the SHA inside it. That is the honest
# answer to "what does the file say"; a caller wanting the default extracts it
# from the result. NAME is used as an ERE, which every caller in-tree satisfies
# by being an ordinary `[A-Z_]+` variable name.
_shell_var() { # file  name
  awk -F'"' -v k="^$2=" '$0 ~ k { print $2; exit }' "$1"
}

# "Is this wiring present in that file?" -- a literal grep reported as a named
# assertion. Defined here after being written twice: tests/debug-levels.sh and
# tests/ccache.sh had character-identical copies that already disagreed on the
# failure wording ("never calls" vs "never mentions"), which is the drift the
# header above describes happening again in miniature.
#
# grep -qF, not -qE: every needle in-tree is a fixed string (a case label, a
# help line, a function name), and one containing a regex metacharacter -- a
# `--ccache)` label ends in one -- would silently match something else.
_wired() { # name  file  needle
  if grep -qF -- "$3" "$2" 2>/dev/null; then
    _pass "$1"
  else
    _bad "$1" "$2 never mentions $3"
  fi
}

# The 1-based line number where PATTERN first matches the text on stdin, empty
# if it never does.
#
# The shape every ORDERING assertion needs: this call must come before that one,
# and the claim is about position rather than presence. It was written out at
# eight sites across five files -- tests/{clean-modes,debug-levels,storage-guard,
# stamp-reconcile,ffmpeg-stamped}.sh -- each spelling `grep -n | head -1 |
# cut -d: -f1` again, and one of them (storage-guard) additionally hand-rolling a
# comment filter that `_code_only` already does properly.
#
# Text on STDIN rather than a filename, because the eight sites are split
# between a file and a captured string, and stdin is the one interface that
# takes both: `_match_line PAT < file`, or `printf '%s\n' "$out" | _match_line
# PAT`. When reading source rather than output, pipe through _code_only first so
# a call named in a comment cannot be mistaken for the call itself.
#
# EXITS 0 whether or not it matched, because `cut` is last in the pipeline and
# it is `grep` that returns 1. Every caller assigns the result directly under
# `set -eu` -- four through this function, the rest through _code_line -- and
# tests/clean-modes.sh dropped its `|| true` on the strength of it, so the
# property is load-bearing rather than incidental. Counted rather than
# remembered: an earlier draft said "five call sites", which was the number of
# FILES.
#
# NOT used by tests/debug-levels.sh's second grep, which deliberately collects
# EVERY matching line number to find whether any of them follows a position.
# That is a different question and stays spelled out where it is asked.
_match_line() { # pattern   (text on stdin)
  grep -nE -- "$1" | head -1 | cut -d: -f1
}

# The same question asked of a FILE's code: where does this first appear, with
# comments stripped.
#
# Three sites spelled `_code_only F | _match_line P` and a fourth captured the
# stripped source into a variable and wrapped it in a local helper -- one
# concept, three spellings. Naming it matters more than the keystrokes it saves:
# the rule that a source grep reads through _code_only is one every site
# otherwise re-decides, and tests/debug-levels.sh got it wrong exactly that way:
# BOTH halves of an ordering claim read raw source, so either could have matched
# the symbol inside a COMMENT. Not a coordinate mismatch, and not a split
# between the halves -- two earlier drafts of this sentence claimed each of
# those. _code_only is a sed substitution that blanks rather than deletes, so
# any two reads of one file always share a numbering. Making the correct form
# the short form is what stops that recurring.
#
# MEASURED, so the claim is not stronger than the evidence: removing the strip
# fails NO assertion today. All ten pinned needles first match at the same
# line with the strip and without it -- for two different reasons, and the split
# is by PROPERTY, not by file. Two earlier drafts of this paragraph partitioned
# it by file and were wrong in both directions.
#
# SEVEN are line-anchored (mf_stage_pending_reset, mf_stage_reserved_reset,
# mf_stage_begin, run make install, stamp_write "ffmpeg", mf_stage_end -- all
# `^[[:space:]]*` -- and save_stored_choices): a `#`-prefixed mention cannot
# match them at all, whatever the prose says. FIVE of those seven are also
# END-anchored (the four `[[:space:]]*$` ones and save_stored_choices' bare
# `$`), which makes them strip-DEPENDENT in the opposite direction: a trailing
# `# comment` on the real call would defeat the needle, and matches only
# because the strip removes the comment and the whitespace before it.
#
# THREE are unanchored (file "$PREFIX/bin/ffmpeg", mf_storage_guard, the
# MF_DEFAULT_OPT assignment) and are safe only because each symbol's first
# occurrence is its call rather than prose about it. That group is what this
# strip defends, and `file "$PREFIX/bin/ffmpeg"` is the one to watch: it is
# unanchored, it lives in a recipe whose comments quote calls verbatim, and
# nothing but habit keeps a matching comment from appearing above it.
_code_line() { # file  pattern
  _code_only "$1" | _match_line "$2"
}

# Reading shell SOURCE: fold continuations, then extract one function's body.
#
# Two tests need this and had one copy between them, which was about to become
# two: tests/debug-levels.sh scans recipes for the make macro that carries the
# composed flags, and tests/compiler-flags.sh has to tell a recipe that DERIVES
# CFLAGS from one that replaces it -- both of which mean following a value into
# the helper that produces it.
#
# Fold first: gsm, bzip2 and librtmp put the flags macro on the line AFTER
# `run make`, and a line-oriented grep reads those as a bare make.
# `-` reads stdin, which is what lets a caller fold a stream it assembled from
# several sources rather than one file on disk -- tests/ffmpeg-stamped.sh scans
# a recipe, mediaforge.sh and all of lib/ as one text. awk spells stdin `-`
# itself, so this is a pass-through rather than a special case.
_logical_lines() { # file, or - for stdin
  awk '{ if (sub(/\\$/, "")) { buf = buf $0; next } print buf $0; buf = "" }' "$1"
}

# Terminates on a `}` at COLUMN ZERO, not on any line ending in one. Any other
# rule is not brace matching: an ordinary body line ending in a close brace --
# `_v=${SOMEVAR}`, a brace group, an inline awk program -- ends the extraction
# early and everything below it becomes invisible, which reads as a passing
# scan rather than an unread file. A phase written on ONE line closes where it
# opens, so it is finished at the start line instead of swallowing the file.
_fn_body() { # file  function-name
  _logical_lines "$1" | awk -v fn="$2" '
    $0 ~ "^[[:space:]]*" fn "\\(\\)" {
      f = 1
      if ($0 ~ /\}[[:space:]]*$/) { print; f = 0; next }
    }
    f { print }
    f && /^\}/ { f = 0 }'
}

# Does this function actually USE the composed CFLAGS -- in code, not in prose?
#
# Both scanners ask it: tests/compiler-flags.sh to tell a recipe that DERIVES
# its flags from one that replaces them, and tests/debug-levels.sh to vouch for
# a helper feeding a make macro. Both asked it as a bare substring search over
# the helper's whole body, and a security review reproduced the bypass that
# allows:
#
#     _evil_cflags() {
#       # NOTE: does not use $CFLAGS here, this is a decoy comment only
#       printf '%s' "-O2 -w"
#     }
#
# The comment satisfied the search, so a helper dropping -fPIC, the prefix
# include path and any operator hardening flags read as legitimate derivation.
#
# Full-line comments are stripped and the reference must be a real token, not a
# substring: a bare CFLAGS match also hits the macro NAMES -- XCFLAGS and
# CCFLAGS both end in it -- and $CFLAGS_BACKUP is not a use of $CFLAGS either.
#
# Residual, stated rather than papered over: a trailing comment on a line that
# is otherwise code (`printf '%s' "-O2"  # $CFLAGS`) still satisfies this.
# Stripping those means parsing shell quoting, since a # inside a quoted flag
# value is not a comment. The reproduced bypass was a comment-only line; this
# closes that and leaves the narrower one visible here.
_uses_composed_cflags() { # file  function-name
  _fn_body "$1" "$2" |
    grep -vE '^[[:space:]]*#' |
    grep -qE '[$]CFLAGS([^_A-Za-z0-9]|$)'
}
