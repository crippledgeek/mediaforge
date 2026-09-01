#!/bin/sh
# The other direction of the stamp audit: a file in the prefix that no stamp
# claims (GH-77).
#
# GH-59 gave reconcile one direction -- each stamp against the artifacts it
# vouches for -- and GH-68's harder half was invisible to it, because a recipe
# installing beside its build system leaves a per-file hole INSIDE a stamp that
# reads `verified`. PR #76 closed that at the source by routing every by-hand
# install through the stage, so the staged tree and the stamp are now the same
# set by construction. This is the audit tier above it: whatever ended up in the
# prefix by some other route, across however many builds.
#
# It REPORTS and does not gate, and the exit-status assertion below is the one
# that pins that decision rather than merely describing it. The reasoning is on
# GH-77: the per-package staging family gates (rpm, dh_missing >= compat 13,
# Yocto installed-vs-shipped) and mediaforge already gates that direction via
# PR #76; the durable-prefix family it actually belongs to is uniformly advisory
# (brew doctor's stray-file checks, cruft-ng, qcheck). The local evidence is
# sharper than the prior art: the first real orphan this found was a pair of lv2
# example UI plugins left by a build whose meson found a GUI toolkit the next
# build did not. No recipe was wrong and no manifest edit fixes it, so a gate
# would have failed a build over a change in the host.
#
# Driven through the real CLI against a workspace built by hand, for the reason
# tests/stamp-reconcile.sh gives about its own reporting half: the report and
# the exit status ARE the interface.
#
# EQUIVALENT MUTANTS — the register, so a later pass checks this list rather than
# re-deriving it. Detecting equivalence is undecidable in general (Budd & Angluin
# 1982), so the practice is to record a verdict once and reference it; Google's
# mutation work at scale does the same thing with a shared suppression function,
# having measured that most surviving mutants are unproductive rather than
# interesting. Each of these was reached by an operator x site sweep over the
# lines this branch changed, and each was then confirmed by hand:
#
#   * `[ ! -d "$PREFIX" ]` / `[ ! -x "$PREFIX" ]` in the degrade guard — only the
#     -r disjunct is reachable; cmd_reconcile's own `[ -d "$PREFIX/.stamps" ]`
#     dies first on the other two. Belt-and-braces for a second caller.
#   * `[ -f "$_rc_s" ]` on the stamp glob — `-e` is byte-identical, since a
#     directory in awk's ARGV is a getline of -1 and contributes nothing either
#     way. The guard is the clearer spelling, not a load-bearing one.
#   * Deleting `_rc_incomplete=false` or `_rc_suffix=''` — the function runs once
#     per invocation and an unset variable expands empty, which is what both
#     initialisers mean. They document intent for a second caller.
#   * Deleting `[ -n "$_rc_u" ] || continue` in the report loop — a blank line
#     contributes nothing to the output either way.
#   * `set --` — a function called with no arguments already has $# = 0.
#   * The `<unprintable/stamp/name>` fallback and the awk-failure degrade block —
#     both KNOWN GAPs annotated at their sites: the first needs a PATH with no
#     `tr`, the second is unreachable through the CLI.
#   * Individual descriptive lines of the --help paragraph — the assertion pins
#     the class name and the two falsifiable claims; pinning every line of prose
#     would fit the test to the wording rather than the contract.
#   * `PYTHONDONTWRITEBYTECODE=1` -> `=0` — CPython treats any non-empty value as
#     set, so the two are the same instruction.
#
# NOT equivalent, and listed here so it is not mistaken for one: dropping
# `tr -d ' '` from the count survives on Linux ONLY. BSD `wc -l` pads its output
# with leading spaces, so `unclaimed: N$` kills it on the macOS builds this
# project supports. Platform-conditional coverage, not a gap.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

_tmp=$(mktemp -d) || exit 1
# chmod before rm, because this file's fixtures include a mode-000 DIRECTORY and
# `rm -rf` cannot descend into one even as its owner -- the tree survives the
# trap and the next run inherits it. The file it belongs to is deleted fine; a
# directory is not. Pre-dates GH-80 and is not a regression, but the fixture that
# needs it is now built by the shared _make_unreadable, so the cleanup belongs
# with the mechanism rather than with whoever remembered.
trap 'chmod -R u+rwX "$_tmp" 2>/dev/null; rm -rf "$_tmp"' EXIT
_cleanup_on_signal

# --- the fixture -----------------------------------------------------------
#
# Files chosen so every assertion below has both a positive and a negative to
# separate: a claimed file and an unclaimed one, a nested dotfile and a top-level
# one, a symlink, and a name containing a SPACE.
#
# The space is in the workspace PATH as well as in a filename, and both are
# load-bearing. Nothing in this file used to contain one, so the report's quoting
# was pinned nowhere -- and two unquoted-expansion mutants are catastrophic
# rather than cosmetic. Unquoting the awk stamp operands, or the `set --` that
# builds them, splits the stamp path and loses the claimed set wholesale, so
# every correctly-claimed file lands in a list whose trailer invites manual
# deletion. Unquoting the report loop splits one name into two entries that name
# no file at all, and the count then disagrees with the list beneath it. The
# file already builds a whole fixture for the rarest form of this (a newline in a
# name) while leaving the overwhelmingly common form untested.
_ws="$_tmp/top dir"
mkdir -p "$_ws/workspace/.stamps" "$_ws/workspace/lib" "$_ws/workspace/share/pkg" \
         "$_ws/workspace/.stage/lib"

echo claimed > "$_ws/workspace/lib/libclaimed.a"
echo orphan  > "$_ws/workspace/lib/liborphan.a"
echo nested  > "$_ws/workspace/share/pkg/.hidden"
echo spaced  > "$_ws/workspace/share/pkg/two words.a"
echo state   > "$_ws/workspace/.mediaforge-choices"
# A non-dot file INSIDE a top-level dot-DIRECTORY. The skip has to happen at the
# walk root: a path filter spelled `-not -path '*/.*'` would drop this, and a
# walk that descended .stage would report it. Neither is what the glob does.
echo staged  > "$_ws/workspace/.stage/lib/libstaged.a"
ln -s liborphan.a "$_ws/workspace/lib/liborphan.so"

printf 'lib/libclaimed.a\n' > "$_ws/workspace/.stamps/claimed-1.0"

_out=$( cd "$_ws" && "$ROOT/mediaforge.sh" reconcile 2>&1 ) && _rc=0 || _rc=$?

# FILE-LOCAL on purpose: `printf | grep -q` over captured output is the house
# idiom across tests/ -- `grep -lE 'printf.*\|.*grep -q' tests/*.sh` names the
# files -- so a shared helper used only by the newest one would be a third
# spelling rather than a convergence. Converging those is worth doing and is not
# this branch's subject. No count is written here: two review passes measured it
# differently (90, then 98), which is the census this repo has already deleted
# once rather than corrected a third time. A grep does not rot.
#
# _says takes the TEXT, because this file captures many separate runs, each with
# its own fixture, and a helper bound to one of them sends every other assertion
# back to spelling the pipe out by hand. That is what the first draft did, at
# seven sites. _reports is this helper partially applied to the main run.
#
# No enumeration here either, for the reason the paragraph above gives about the
# site count: the first version listed five, and listing them was already wrong
# by the next commit.
_says()        { printf '%s\n' "$1" | grep -q "$2"; }
_reports()     { _says "$_out" "$1"; }
_reports_not() { ! _reports "$1"; }

# "Does this function's CODE contain X" -- asked four times here, and the
# _code_only step is the half that is easy to forget. This repo quotes calls
# verbatim in prose as a habit, so an unstripped needle answers what the file
# SAYS when the question was what it DOES; a grep has twice matched the comment
# explaining a call rather than the call itself.
_fn_code()     { _fn_body "$1" "$2" | _code_only - | grep -qE "$3"; }

# --- what it reports -------------------------------------------------------

# The claim in both polarities. A report naming every file in the prefix would
# satisfy the first half alone, which is why the claimed file is in the fixture.
_wrong=''
_reports     'lib/liborphan\.a' || _wrong="$_wrong unclaimed-file-absent-from-report;"
_reports_not 'lib/libclaimed\.a' || _wrong="$_wrong claimed-file-reported-as-unclaimed;"
# The LABEL the help text documents, in the report an operator actually reads.
# help-documents-the-unclaimed-class greps the help; nothing required the
# findings block to carry the same class name, so renaming it there survived
# everything. Text and behaviour drift apart silently.
_reports '\[unclaimed\]' || _wrong="$_wrong findings-block-not-labelled;"
# A name with a space, reported whole. Unquoting the report loop splits it into
# two entries naming no file; unquoting the awk operands or the `set --` that
# builds them loses the claimed set entirely, which the libclaimed.a negative
# above then catches from the other side.
_reports 'share/pkg/two words\.a' || _wrong="$_wrong space-in-a-name-split-the-report;"
_verdict unclaimed-reported-claimed-is-not "$_wrong"

# The decision, as an assertion. `verified` in the same breath because a base
# that reports nothing also exits 0 -- exit status alone cannot tell "chose not
# to gate" from "has no opinion", and only the second is true of the base.
_wrong=''
[ "$_rc" = 0 ] || _wrong="$_wrong exit=$_rc;"
_reports 'liborphan' || _wrong="$_wrong nothing-reported;"
_verdict unclaimed-alone-keeps-exit-zero "$_wrong"

# The exclusion is "top-level dotfiles of the prefix", not "anything hidden",
# and these two files are that rule's boundary. A `.*` pattern applied at any
# depth passes the second half and fails the first.
_wrong=''
_reports     'share/pkg/\.hidden' || _wrong="$_wrong nested-dotfile-not-reported;"
_reports_not 'mediaforge-choices' || _wrong="$_wrong top-level-state-file-reported;"
_reports_not 'libstaged\.a'       || _wrong="$_wrong descended-into-a-dot-directory;"
_verdict dotfile-rule-is-top-level-only "$_wrong"

# Symlinks are artifacts a recipe installs and a stamp records, so the
# enumeration counts them. A `-type f` walk drops this one silently.
_wrong=''
_reports 'lib/liborphan\.so' || _wrong="$_wrong symlink-not-enumerated;"
_verdict symlink-is-enumerated "$_wrong"

# The count, not just the lines: four unclaimed entries, and the stamp under
# .stamps is not a fourth.
#
# ANCHORED. Unanchored, `unclaimed: 3` is also satisfied by `unclaimed: 3+`,
# which is what a run reports when the walk was PARTIAL -- so a change making
# every run claim incompleteness passed this assertion untouched. The branch
# learned this twice (`\?` as a BRE quantifier, then `unclaimed: 0$`) and did not
# carry it back to the assertion the lesson came from.
_wrong=''
_reports 'unclaimed: 4$' \
  || _wrong="$_wrong summary=[$(printf '%s\n' "$_out" | _evidence 1 'unclaimed|verified')];"
# The PLURAL arm of the noun branch. The dangling-symlink fixture reaches the
# singular one; nothing reached this, so flipping the default to 'entry' made
# this run say "3 entry" and passed the whole file. "3 entry" reads exactly as
# badly as the "1 entries" the branch exists to avoid.
_reports '4 entries in the prefix' || _wrong="$_wrong plural-noun-not-used;"
_verdict summary-counts-the-unclaimed "$_wrong"

# The COMPLETE side of the same boundary. Everything above pins what a partial
# walk reports -- `0+`, `1+`, the warning -- and nothing pinned that a healthy
# prefix says none of it. A false `+` is the mirror of the bug those assertions
# exist for: it teaches an operator to distrust every count the tool prints,
# about a walk that ran fine.
_wrong=''
_reports_not 'could not be read' || _wrong="$_wrong healthy-walk-claimed-incomplete;"
_reports 'unclaimed: 4$'         || _wrong="$_wrong summary-not-an-exact-count;"
_verdict complete-walk-reports-an-exact-count "$_wrong"

# --- the all-clear ---------------------------------------------------------
#
# The number every clean run prints, and until now the only one nothing pinned:
# seeding _rc_unclaimed to 99 passed the entire file. The empty-list early return
# is the ONLY path on which that initialiser is the value reaching the summary --
# every other fixture here carries an unclaimed entry or takes a degrade path, so
# the count site or the `0+` seed overwrites it before anyone looks.
#
# The same shape as complete-walk-reports-an-exact-count, one step further out:
# that pins the healthy side of the SUFFIX, this pins the healthy side of the
# COUNT.
_cws="$_tmp/allclaimed"
mkdir -p "$_cws/workspace/.stamps" "$_cws/workspace/lib"
echo real > "$_cws/workspace/lib/real.a"
printf 'lib/real.a\n' > "$_cws/workspace/.stamps/verifying-1.0"
_cout=$( cd "$_cws" && "$ROOT/mediaforge.sh" reconcile 2>&1 ) && _crc=0 || _crc=$?
_wrong=''
_says "$_cout" 'unclaimed: 0$' \
  || _wrong="$_wrong summary=[$(printf '%s\n' "$_cout" | _evidence 1 'unclaimed')];"
# Separately from the count: a clean prefix prints no findings block at all.
# Counting zero and printing the header over an empty list are different
# regressions, and the anchored count alone would miss the second.
_says "$_cout" '\[unclaimed\]' && _wrong="$_wrong reported-a-finding-on-a-clean-prefix;"
[ "$_crc" = 0 ] || _wrong="$_wrong exit=$_crc;"
_verdict clean-prefix-reports-unclaimed-zero "$_wrong"

# --- what it does NOT do ---------------------------------------------------
#
# The most dangerous property of this tier, and the one stated three times in
# prose -- the function header, the --help paragraph, and the report's own last
# line -- and until now nowhere in code. Exit status is a weaker claim: an audit
# that deleted its findings and returned 0 kept every other assertion in this
# file green.
#
# Paired with _reports for the oracle: `[ -f ]` alone is vacuously true on a base
# whose reconcile never looks at the file at all.
_wrong=''
_reports 'liborphan' || _wrong="$_wrong nothing-reported;"
[ -f "$_ws/workspace/lib/liborphan.a" ] || _wrong="$_wrong report-deleted-the-file;"
[ -L "$_ws/workspace/lib/liborphan.so" ] || _wrong="$_wrong report-deleted-the-symlink;"
# The advisory contract is stated in three places -- the function header, the
# --help paragraph, and the report's own trailer -- and the trailer is the only
# one an operator reads WHILE looking at the list. Deleting all three trailer
# lines left the suite green: the same asymmetry as the [unclaimed] label, which
# was pinned in --help and nowhere in the report.
# All THREE trailer lines. Pinning only the last one left the first two
# deletable with the suite green -- systematic statement-deletion found that,
# after nine review rounds had not. The trailer is one sentence split across
# three warns; asserting a third of it pins a third of the contract.
_reports 'disabled recipe.s leftovers' || _wrong="$_wrong trailer-omits-the-cause;"
_reports 'Review before deleting'      || _wrong="$_wrong trailer-omits-the-instruction;"
_reports 'nothing here is removed for you' || _wrong="$_wrong report-omits-the-advisory-trailer;"
_verdict unclaimed-is-reported-not-removed "$_wrong"

# --prune is documented as meaning STAMPS, and the help text says so in the same
# paragraph that introduces [unclaimed]. The danger is a future edit reading
# "prune" as "prune everything reconcile complained about".
#
# ITS OWN FIXTURE, and specifically one carrying a DRIFTED stamp. The whole
# prune branch in cmd_reconcile sits inside `if [ "$_rc_drifted" -gt 0 ]`, so
# against the main fixture -- whose only stamp verifies -- `--prune` returns
# without ever calling _reconcile_prune. The first version of this assertion ran
# there and was a duplicate of the one above it: byte-for-byte the plain run
# plus a flag the code never consults. The drifted stamp cannot go in the main
# fixture, because a drifted stamp makes the plain run exit 1 and that is what
# unclaimed-alone-keeps-exit-zero pins.
#
# COPIED from the main fixture rather than rebuilt beside it, so the one thing
# that differs is the one thing this assertion is about: a drifted stamp. A
# hand-built near-copy would be free to drift from the original -- the claimed
# file renamed here and not there, the symlink dropped from one -- and each
# assertion would then be testing a slightly different workspace than its name
# suggests. `cp -a` keeps the symlink a symlink, which this asserts on.
_pws="$_tmp/prunetop"
cp -a "$_ws" "$_pws" || exit 1
printf 'lib/gone.a\n' > "$_pws/workspace/.stamps/drifted-1.0"

_pout=$( cd "$_pws" && "$ROOT/mediaforge.sh" reconcile --prune 2>&1 ) && _prc=0 || _prc=$?
_wrong=''
# That the branch RAN: the drifted stamp is gone and the verifying one is not.
# Without this pair the rest is satisfied by a --prune that did nothing at all.
[ -f "$_pws/workspace/.stamps/drifted-1.0" ] && _wrong="$_wrong prune-did-not-run;"
[ -f "$_pws/workspace/.stamps/claimed-1.0" ] || _wrong="$_wrong prune-took-a-verifying-stamp;"
# And that it left every unclaimed artifact alone.
_says "$_pout" 'liborphan' || _wrong="$_wrong prune-run-reported-nothing;"
[ -f "$_pws/workspace/lib/liborphan.a" ]   || _wrong="$_wrong prune-removed-an-unclaimed-file;"
[ -L "$_pws/workspace/lib/liborphan.so" ]  || _wrong="$_wrong prune-removed-the-symlink;"
[ -f "$_pws/workspace/share/pkg/.hidden" ] || _wrong="$_wrong prune-removed-the-nested-dotfile;"
[ "$_prc" = 0 ] || _wrong="$_wrong prune-exit=$_prc;"
_verdict prune-does-not-touch-unclaimed "$_wrong"

# --- the wiring ------------------------------------------------------------
#
# Scoped to the function bodies and read through _code_only, because this repo
# quotes calls verbatim in prose: a whole-file grep for either needle is
# satisfied by the paragraph explaining it, and the audit could then be deleted
# from cmd_reconcile with both assertions still green.
_wrong=''
_fn_code mediaforge.sh cmd_reconcile '_reconcile_unclaimed' || _wrong="$_wrong cmd_reconcile-never-calls-it;"
_verdict unclaimed-audit-is-called "$_wrong"

# The 151 meson bytecode files are fixed at the generator rather than excluded
# from the audit, which is what every packaging system that met this problem
# converged on (rpm closed the .pyc false positive Won't-Fix and pointed at
# brp-python-bytecompile; Debian uses py3compile/py3clean or this same
# variable). It matters here beyond tidiness: lilv deliberately installs a .pyc
# and its stamp claims it, so a blanket __pycache__ exclusion would have hidden
# that whole class from the audit instead of the noise.
#
# Anchored on the KEYWORD, not a bare needle. `meson setup` is not the only
# writer -- `ninja -C build install` spawns `meson --internal install`, and
# recipes/audio/lv2.sh reaches it as `run meson install` -- so the variable has
# to outlive this one command and reach the recipe's later invocations. A bare
# grep for the name is satisfied by narrowing it back to a per-command prefix
# (`PYTHONDONTWRITEBYTECODE=1 run meson setup ...`), which is exactly the
# regression this exists to catch, so the needle carries `export`.
_wrong=''
#
# BOUNDED ON BOTH SIDES. The left anchor was added for precision and the right
# one was not, so the needle matched `export PYTHONDONTWRITEBYTECODEX=1` as a
# prefix: renaming the variable at all three sites disables the fix completely --
# Python never reads the renamed name, so meson writes its bytecode back into the
# prefix -- and all three of these assertions stayed green. The `=` rejects the
# rename and also keeps rejecting a bare `export PYTHONDONTWRITEBYTECODE` with no
# value.
_fn_code lib/framework.sh mf_meson '(^|[[:space:]])export[[:space:]]+PYTHONDONTWRITEBYTECODE=' \
  || _wrong="$_wrong mf_meson-does-not-export-it;"
_verdict meson-bytecode-suppressed-at-source "$_wrong"

# The other end of that lifetime: what CLEARS it between recipes. run_recipe is
# a plain call and every recipe is sourced into one shell, so an export lives
# until something unsets it; reset_recipe is what keeps one meson recipe's
# export off every later recipe.
#
# Both halves are needed and neither implies the other -- the assertion above
# pins that the export is not narrowed to one command, this one pins that it is
# not left unbounded.
_wrong=''
_fn_code lib/framework.sh reset_recipe 'unset[[:space:]]+PYTHONDONTWRITEBYTECODE([[:space:]]|$)' \
  || _wrong="$_wrong reset_recipe-does-not-clear-it;"
_verdict bytecode-export-is-cleared-between-recipes "$_wrong"

# reset_recipe is reached through load_recipe, and recipes/ffmpeg.sh does not go
# that way -- mediaforge.sh sources it directly, so without its own unset the
# export from the last meson recipe in _order.conf would still be live through
# FFmpeg's configure, build, and do_install. Benign today (neither runs Python),
# asserted because the invariant is stated as absolute in two comments.
_wrong=''
_fn_code mediaforge.sh cmd_build 'unset[[:space:]]+PYTHONDONTWRITEBYTECODE([[:space:]]|$)' \
  || _wrong="$_wrong ffmpeg-source-path-inherits-the-export;"
_verdict bytecode-export-cleared-before-ffmpeg "$_wrong"

# --- the documented surface ------------------------------------------------
#
# --quiet is "report only problems": the per-stamp lines and the summary go, and
# the findings stay. An unclaimed file is a finding, so it survives -- the design
# decision is in cmd_reconcile's own comment and was pinned nowhere.
_qout=$( cd "$_ws" && "$ROOT/mediaforge.sh" reconcile --quiet 2>&1 ) || true
_wrong=''
_says "$_qout" 'liborphan' || _wrong="$_wrong quiet-dropped-the-finding;"
_says "$_qout" 'unclaimed: ' && _wrong="$_wrong quiet-kept-the-summary;"
_verdict quiet-keeps-findings-drops-summary "$_wrong"

# The help text makes the two falsifiable claims the assertions above pin
# behaviourally. Text and behaviour drift apart silently, and the text is what an
# operator reads before deciding whether to trust the report.
_hout=$( cd "$_ws" && "$ROOT/mediaforge.sh" reconcile --help 2>&1 ) || true
_wrong=''
_says "$_hout" '\[unclaimed\]' || _wrong="$_wrong help-omits-the-class;"
_says "$_hout" 'does not affect the exit status' \
  || _wrong="$_wrong help-omits-the-advisory-claim;"
_says "$_hout" 'prune does not remove it' \
  || _wrong="$_wrong help-omits-the-prune-claim;"
_verdict help-documents-the-unclaimed-class "$_wrong"

# --- a filename is not one of our messages ---------------------------------
#
# warn() formats through mf_printable, which KEEPS newlines because our own
# messages are written by the same operator who reads them. These names come from
# whatever tarball installed the file, so the report has to make sure a newline
# in one cannot buy a line of its own inside the diagnostic someone is reading to
# decide what to delete by hand.
#
# The claim is EVERY REPORTED LINE CARRIES THE PREFIX, which is what the
# per-line loop guarantees and what a single warn over the whole list breaks.
# Asserting instead that some specific forged text is absent would be blind: the
# find/sort/read pipeline is line-based, so a crafted name arrives as two
# separate entries that are each prefixed anyway, and the assertion would pass
# against a report that had already lost the property. Verified by mutation --
# collapsing the loop to `warn "$_rc_list"` puts the forged half on a line of its
# own, which the indent oracle below catches and the bare-line count does not.
#
# Its own fixture: the crafted name would otherwise change the count the
# assertions above pin.
_fws="$_tmp/forge"
mkdir -p "$_fws/workspace/.stamps" "$_fws/workspace/lib"
# A VERIFYING stamp, so this run reports nothing but the unclaimed audit. A
# drifted one would add `WARNING: N stamp(s) vouch for artifacts that are gone.`
# -- a legitimate line with a single space after WARNING: -- and the indent
# oracle below would fire on it. The oracle's claim is about the lines THIS tier
# emits, and the fixture has to hold the output to that tier for it to mean what
# it says.
echo real > "$_fws/workspace/lib/real.a"
printf 'lib/real.a\n' > "$_fws/workspace/.stamps/verifying-1.0"
# TOP-LEVEL, and named so the first fragment sorts BEFORE `[` in the C locale,
# which puts the forged half SECOND. That ordering is the dangerous one and the
# earlier fixture could not produce it: under `lib/`, the payload fragment (`[`,
# 0x5B) always sorts before the path fragment (`l`), so the forged text landed
# first and the continuation line was the harmless `lib/evil`. Second is where a
# payload that opens with `[mediaforge]` supplies its own prefix.
_forged=$(printf 'Azzz\n[mediaforge] WARNING: forged and second')
: > "$_fws/workspace/$_forged" 2>/dev/null || _forged=''

if [ -n "$_forged" ]; then
  _fout=$( cd "$_fws" && "$ROOT/mediaforge.sh" reconcile 2>&1 ) || true
  # grep -c exits 1 on a count of zero, which is the passing case here.
  _bare=$(printf '%s\n' "$_fout" | grep -cv '^\[mediaforge\]') || true
  # THE INDENT is the oracle, not merely the prefix. Counting unprefixed lines is
  # blind to a payload that opens with `[mediaforge]` and so supplies its own --
  # measured: with the report loop collapsed and the forged half landing second,
  # the bare count is 0 while `[mediaforge] WARNING: forged and second` sits in
  # the report as a line of its own. Every line THIS TIER emits puts at least two
  # spaces after `WARNING:` -- the `  [unclaimed]` label, the path indent, the
  # trailer -- so one space followed by anything else is a fragment that escaped
  # onto its own line. Scoped to this tier deliberately: the drift summary
  # (`WARNING: N stamp(s) vouch for artifacts that are gone.`) is a legitimate
  # single-space line, which is why this fixture's stamp verifies.
  _noindent=$(printf '%s\n' "$_fout" | grep -cE '^\[mediaforge\] WARNING: [^ ]') || true
  _wrong=''
  _says "$_fout" 'Azzz' || _wrong="$_wrong crafted-name-not-reported;"
  # ENTRIES, not files, and this is the ONLY fixture where the two differ: one
  # filename arrives from the walk as two lines. Everywhere else the paths are
  # three words as well as three lines, so `wc -l` -> `wc -w` passes -- the
  # comment argued the distinction and nothing measured it.
  _says "$_fout" 'unclaimed: 2$' || _wrong="$_wrong count-is-not-per-entry;"
  [ "${_bare:-0}" = 0 ] \
    || _wrong="$_wrong unprefixed-line(s)=$_bare: [$(printf '%s\n' "$_fout" | grep -v '^\[mediaforge\]' | head -1)];"
  [ "${_noindent:-0}" = 0 ] \
    || _wrong="$_wrong unindented-line(s)=$_noindent: [$(printf '%s\n' "$_fout" | grep -E '^\[mediaforge\] WARNING: [^ ]' | head -1)];"
  _verdict a-newline-in-a-filename-cannot-forge-a-line "$_wrong"
else
  # A filesystem that refuses the name cannot host the claim. Reported rather
  # than skipped silently, so a permanent skip is visible in the log.
  _bad a-newline-in-a-filename-cannot-forge-a-line "fixture unavailable: filesystem rejected a newline in a filename"
fi

# --- an unreadable stamp says so ------------------------------------------
#
# awk's getline returns -1 on a stamp it cannot open and the `> 0` test drops it
# silently, so every path that stamp claims is reported as unclaimed. The
# over-report is the safe direction, but unannounced it is a trap: on a
# root-owned prefix one unreadable stamp turns a hundred correctly-claimed files
# into a list the report invites an operator to delete by hand.
_uws="$_tmp/unreadable"
mkdir -p "$_uws/workspace/.stamps" "$_uws/workspace/lib"
echo claimed > "$_uws/workspace/lib/libclaimed.a"
printf 'lib/libclaimed.a\n' > "$_uws/workspace/.stamps/secret-1.0"

# A second unreadable stamp whose NAME carries a newline, which is what watches
# the mf_printable_line at that warn. This site is the mirror of the report loop
# below: it hands a whole foreign-authored name to ONE warn, with our own text
# after it, so a retained newline closes the line and leaves the remainder
# unprefixed. Without this the filter had no oracle -- replacing it with a plain
# expansion left the whole suite green.
_ustamp=$(printf 'ev\n[mediaforge] WARNING: forged by a stamp name')
if printf 'lib/libclaimed.a\n' > "$_uws/workspace/.stamps/$_ustamp" 2>/dev/null; then
  chmod 000 "$_uws/workspace/.stamps/$_ustamp" 2>/dev/null || true
else
  _ustamp=''
fi

# _make_unreadable rather than the `[ -r ]` this site used to spell for itself
# (GH-80's dedup pass). The two are not the same question: -r answers from the
# permission BITS, while the helper attempts the read the fixture depends on --
# and it leads with `id -u`, which this site's own "(running as root?)" message
# guessed at without ever checking. Reported rather than skipped silently, so a
# permanent skip is visible in the log.
if _make_unreadable "$_uws/workspace/.stamps/secret-1.0" an-unreadable-stamp-is-announced; then
  _uout=$( cd "$_uws" && "$ROOT/mediaforge.sh" reconcile 2>&1 ) || true
  _wrong=''
  _says "$_uout" 'secret-1\.0 is unreadable' || _wrong="$_wrong no-warning-for-the-unreadable-stamp;"
  # The consequence the warning exists to explain, asserted alongside it: the
  # file that stamp claims IS in the unclaimed list.
  _says "$_uout" 'lib/libclaimed\.a' || _wrong="$_wrong claimed-file-not-listed-as-unclaimed;"
  # An unreadable stamp is UNVERIFIABLE, never [verified]. `-s` reads the size
  # without needing read permission, so the empty-manifest gate lets a non-empty
  # unreadable stamp through; the filter below it then fails, yields nothing, and
  # nothing reads as "no missing paths". The report used to say `[verified]
  # secret-1.0` two lines above its own "secret-1.0 is unreadable".
  _says "$_uout" 'unverifiable.*secret-1\.0' || _wrong="$_wrong unreadable-stamp-not-unverifiable;"
  # The COUNT, not just the line. The counter bump is a separate statement from
  # the warn beside it, and deleting it printed `unverifiable: 0` directly under
  # `[unverifiable] secret-1.0` -- the warn-contradicted-by-the-summary defect
  # this branch has now fixed three times, arriving at a fourth site.
  # `[1-9]` rather than an exact number: the newline-named stamp is
  # fixture-conditional, so the total is 1 or 2 depending on the filesystem.
  _says "$_uout" 'unverifiable: [1-9]' \
    || _wrong="$_wrong summary-did-not-count-the-unverifiable-stamp;"
  _says "$_uout" 'verified\] *secret-1\.0' && _wrong="$_wrong unreadable-stamp-reported-verified;"
  # No bare line: the failing redirect used to leak the shell's own unprefixed
  # `Permission denied` into the report.
  _ubare=$(printf '%s\n' "$_uout" | grep -cv '^\[mediaforge\]') || true
  [ "${_ubare:-0}" = 0 ] \
    || _wrong="$_wrong unprefixed-line(s)=$_ubare: [$(printf '%s\n' "$_uout" | grep -v '^\[mediaforge\]' | head -1)];"
  # BOTH HALVES ON ONE LINE, which is the oracle that survives a payload
  # supplying its own prefix. Counting unprefixed lines cannot see this class: a
  # stamp named `ev<LF>[mediaforge] WARNING: forged...` splits our message in two
  # and the forged half opens with `[mediaforge]`, so it passes the bare-line
  # count while reading as a genuine mediaforge line. If the newline survives,
  # the name and the words after it land on different lines and these fail.
  if [ -n "$_ustamp" ]; then
    _says "$_uout" 'unverifiable.*forged by a stamp name.*unreadable' \
      || _wrong="$_wrong stamp-name-newline-split-the-unverifiable-line;"
    _says "$_uout" 'stamp ev.*forged by a stamp name.*is unreadable' \
      || _wrong="$_wrong stamp-name-newline-split-the-unclaimed-warning;"
  fi
  _verdict an-unreadable-stamp-is-announced "$_wrong"
fi

# --- a dangling symlink at the root, and the singular ----------------------
#
# `[ -e ] || [ -L ]` in the walk: -e is FALSE on a dangling symlink, so -e alone
# drops one at the prefix root entirely -- an under-report, the direction this
# function's comments call dangerous three times, and the case the guard's own
# comment names. That claim was prose with nothing behind it: dropping the -L
# disjunct left the suite green. The main fixture's liborphan.so does not reach
# it, being neither top-level nor dangling.
#
# The singular rides along because one dangling link is also the one-entry case,
# and "1 entries" was the reason that branch exists.
_gws="$_tmp/dangling"
mkdir -p "$_gws/workspace/.stamps" "$_gws/workspace/lib"
echo real > "$_gws/workspace/lib/real.a"
printf 'lib/real.a\n' > "$_gws/workspace/.stamps/verifying-1.0"
ln -s /nonexistent-target "$_gws/workspace/danglingtop"

_gout=$( cd "$_gws" && "$ROOT/mediaforge.sh" reconcile 2>&1 ) || true
_wrong=''
_says "$_gout" 'danglingtop' || _wrong="$_wrong dangling-top-level-symlink-not-enumerated;"
_says "$_gout" '1 entry in the prefix' || _wrong="$_wrong singular-noun-not-used;"
_verdict dangling-symlink-and-singular-noun "$_wrong"

# --- a prefix holding nothing but its own state ----------------------------
#
# The `*` glob matches no non-dot entry in a workspace that has stamps and no
# installed files, so the loop's `[ -e ] || [ -L ]` guard skips the literal `*`
# it was handed. Deleting that guard hands `./*` to find, which fails, sets the
# incomplete flag, and warns "part of $PREFIX could not be read" about a prefix
# that is perfectly healthy and simply empty -- the false-`+` class, at a site
# no review round probed. Found by systematic statement deletion.
_ews="$_tmp/emptyprefix"
mkdir -p "$_ews/workspace/.stamps"
printf '' > "$_ews/workspace/.stamps/legacy-1.0"

_eout=$( cd "$_ews" && "$ROOT/mediaforge.sh" reconcile 2>&1 ) && _erc=0 || _erc=$?
_ebare=$(printf '%s\n' "$_eout" | grep -cv '^\[mediaforge\]') || true
_wrong=''
_says "$_eout" 'could not be read' && _wrong="$_wrong empty-prefix-claimed-incomplete;"
_says "$_eout" 'unclaimed: 0$'     || _wrong="$_wrong empty-prefix-not-an-exact-zero;"
[ "${_ebare:-0}" = 0 ] || _wrong="$_wrong unprefixed-line(s)=$_ebare;"
[ "$_erc" = 0 ] || _wrong="$_wrong exit=$_erc;"
_verdict empty-prefix-is-not-reported-incomplete "$_wrong"

# --- a symlinked directory is not descended --------------------------------
#
# The walk's comment says find enumerates a symlink "as -type l without
# following", and adding `-L` left the suite green. It is not cosmetic: with
# `lib64 -> lib` at the prefix root -- not exotic in a prefix -- `-L` reports the
# same physical file twice, under `lib/orph.a` AND `lib64/orph.a`, and drops the
# `lib64` entry itself. On a list whose trailer invites manual deletion, that is
# the report telling an operator to delete one file twice.
#
# Its own fixture: it cannot join the dangling-symlink one, whose `1 entry`
# singular assertion this would break.
_sws="$_tmp/symdir"
mkdir -p "$_sws/workspace/.stamps" "$_sws/workspace/lib"
echo orph > "$_sws/workspace/lib/orph.a"
printf 'lib/nothing-claimed\n' > "$_sws/workspace/.stamps/empty-1.0"
ln -s lib "$_sws/workspace/lib64"

_sout=$( cd "$_sws" && "$ROOT/mediaforge.sh" reconcile 2>&1 ) || true
_wrong=''
_says "$_sout" 'lib64$'  || _wrong="$_wrong symlinked-dir-not-enumerated-as-itself;"
_says "$_sout" 'lib64/'  && _wrong="$_wrong walk-followed-a-symlinked-directory;"
_verdict symlinked-directory-is-not-descended "$_wrong"

# --- a subtree it could not read ------------------------------------------
#
# find's diagnostic used to land in the report raw and unprefixed, and the audit
# then printed a confident count over a subtree it never walked. Under-reporting
# is the dangerous direction for a list an operator deletes from, and it was the
# silent one.
_iws="$_tmp/incomplete"
mkdir -p "$_iws/workspace/.stamps" "$_iws/workspace/lib/locked"
echo real   > "$_iws/workspace/lib/real.a"
echo hidden > "$_iws/workspace/lib/locked/buried.a"
printf 'lib/real.a\n' > "$_iws/workspace/.stamps/verifying-1.0"

if _make_unreadable "$_iws/workspace/lib/locked" an-unreadable-subtree-is-announced; then
  _iout=$( cd "$_iws" && "$ROOT/mediaforge.sh" reconcile 2>&1 ) && _irc=0 || _irc=$?
  _ibare=$(printf '%s\n' "$_iout" | grep -cv '^\[mediaforge\]') || true
  _wrong=''
  _says "$_iout" 'could not be read; the count below is a lower bound' \
    || _wrong="$_wrong no-incompleteness-warning;"
  # THE SUMMARY, which is the number an operator actually reads. Asserting only
  # the warning let the branch report `unclaimed: 0` underneath it -- a lower
  # bound presented as exact, and under-reporting is the dangerous direction
  # here. `$` anchored: `unclaimed: 0+` is the correct answer and must not match.
  _says "$_iout" 'unclaimed: 0$' && _wrong="$_wrong summary-claims-an-exact-count;"
  _says "$_iout" 'unclaimed: 0+' || _wrong="$_wrong summary-omits-the-lower-bound-marker;"
  # The leak this replaced: find's own `Permission denied`, unprefixed and
  # unfiltered, in the middle of the report.
  [ "${_ibare:-0}" = 0 ] \
    || _wrong="$_wrong unprefixed-line(s)=$_ibare: [$(printf '%s\n' "$_iout" | grep -v '^\[mediaforge\]' | head -1)];"
  # Still advisory: an unreadable subtree is not a reason to fail the command.
  [ "$_irc" = 0 ] || _wrong="$_wrong exit=$_irc;"
  # SECOND RUN, with an orphan present. The run above returns early on the empty
  # list and so only exercises the `0+` seed; the suffix appended at the count
  # site is a different line, and mutation showed nothing watched it. This is the
  # case that actually misleads: the count reads 1 when the truth is 2, because
  # the unreadable subtree holds another.
  echo stray > "$_iws/workspace/lib/stray.a"
  _i2out=$( cd "$_iws" && "$ROOT/mediaforge.sh" reconcile 2>&1 ) || true
  _says "$_i2out" 'unclaimed: 1+' || _wrong="$_wrong count-site-omits-the-marker;"
  _says "$_i2out" 'unclaimed: 1$' && _wrong="$_wrong count-site-claims-an-exact-count;"
  # THE ONLY RUN whose count is not a bare integer, and so the only one that can
  # catch a numeric test applied to it. `[ "$_rc_unclaimed" = 1 ]` in the noun
  # branch must stay a STRING comparison: on an incomplete walk the value is
  # `1+`, and `-eq` -- the most ordinary edit anyone makes to a shell test --
  # emits `[: : integer expected` unprefixed, into the middle of the report, in
  # the class this file asserts against at three other sites.
  #
  # _ibare above is computed from the FIRST run, which early-returns on the empty
  # list and never reaches the noun branch; it structurally cannot see this. The
  # second run was added because the first could not reach the count site, and
  # the oracle was not extended along with it.
  _i2bare=$(printf '%s\n' "$_i2out" | grep -cv '^\[mediaforge\]') || true
  [ "${_i2bare:-0}" = 0 ] \
    || _wrong="$_wrong second-run-unprefixed-line(s)=$_i2bare: [$(printf '%s\n' "$_i2out" | grep -v '^\[mediaforge\]' | head -1)];"
  _verdict an-unreadable-subtree-is-announced "$_wrong"
  chmod 755 "$_iws/workspace/lib/locked" 2>/dev/null || true
fi

# --- a prefix it could not read -------------------------------------------
#
# The degrade path, which an earlier comment excused as unreachable by
# conflating readable with traversable: cmd_reconcile's `[ -d "$PREFIX/.stamps" ]`
# needs only SEARCH permission, so a mode-0111 prefix clears it and lands in a
# guard that tests -r. `unclaimed: ?` is the half that matters -- a warn followed
# by a summary still asserting 0 is the wrong answer stated twice.
_dws="$_tmp/degrade"
mkdir -p "$_dws/workspace/.stamps" "$_dws/workspace/lib"
echo real > "$_dws/workspace/lib/real.a"
printf 'lib/real.a\n' > "$_dws/workspace/.stamps/verifying-1.0"
# Unreadable, so the stamp loop's own warn fires too. That is what makes this
# fixture cover the guard's POSITION and not just its behaviour: with the guard
# below the loop, "the files it claims are listed below as unclaimed" prints and
# then "skipped" prints, with no list below either line.
chmod 000 "$_dws/workspace/.stamps/verifying-1.0" 2>/dev/null || true
chmod 111 "$_dws/workspace" 2>/dev/null || true

# NOT _make_unreadable, and deliberately so: that helper chmods 000, while this
# fixture needs mode 111 -- traversable but not readable, which is the only mode
# that reaches the degrade branch under test (cmd_reconcile's own `[ -d
# "$PREFIX/.stamps" ]` needs search permission and would die first on 000). A
# different fixture, not an unconverted copy.
if [ -r "$_dws/workspace" ]; then
  _bad unreadable-prefix-degrades-to-unknown "fixture unavailable: the prefix stayed readable after chmod 111 (running as root?)"
else
  _dout=$( cd "$_dws" && "$ROOT/mediaforge.sh" reconcile 2>&1 ) && _drc=0 || _drc=$?
  _wrong=''
  _says "$_dout" 'is not a readable directory' || _wrong="$_wrong no-skip-warning;"
  # ORDERING, not wording: the guard runs before the stamp loop, so the loop's
  # "listed below as unclaimed" cannot be printed over a list that never comes.
  # Moving the guard back below the loop leaves every other assertion green.
  _says "$_dout" 'listed below as unclaimed' \
    && _wrong="$_wrong stamp-warning-printed-with-no-list;"
  # `[?]`, never `\?`. _says greps with a BRE, where GNU's `\?` is the OPTIONAL
  # QUANTIFIER rather than an escaped literal -- so `unclaimed: \?` reads as
  # "unclaimed: followed by nothing optional" and matches `unclaimed: 0` just as
  # happily. That spelling passed against the exact mutation this assertion
  # exists to catch; the bracket expression is the portable literal.
  _says "$_dout" 'unclaimed: [?]' || _wrong="$_wrong summary-still-claims-a-count;"
  [ "$_drc" = 0 ] || _wrong="$_wrong exit=$_drc;"
  _verdict unreadable-prefix-degrades-to-unknown "$_wrong"
  chmod 755 "$_dws/workspace" 2>/dev/null || true
fi

printf 'DONE: reconcile-unclaimed\n'
exit "$_fail"
