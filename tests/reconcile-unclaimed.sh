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
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

_tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$_tmp"' EXIT
_cleanup_on_signal

# --- the fixture -----------------------------------------------------------
#
# Five files, chosen so every assertion below has both a positive and a
# negative to separate: a claimed file and an unclaimed one, a nested dotfile
# and a top-level one, and a symlink.
_ws="$_tmp/topdir"
mkdir -p "$_ws/workspace/.stamps" "$_ws/workspace/lib" "$_ws/workspace/share/pkg" \
         "$_ws/workspace/.stage/lib"

echo claimed > "$_ws/workspace/lib/libclaimed.a"
echo orphan  > "$_ws/workspace/lib/liborphan.a"
echo nested  > "$_ws/workspace/share/pkg/.hidden"
echo state   > "$_ws/workspace/.mediaforge-choices"
# A non-dot file INSIDE a top-level dot-DIRECTORY. The skip has to happen at the
# walk root: a path filter spelled `-not -path '*/.*'` would drop this, and a
# walk that descended .stage would report it. Neither is what the glob does.
echo staged  > "$_ws/workspace/.stage/lib/libstaged.a"
ln -s liborphan.a "$_ws/workspace/lib/liborphan.so"

printf 'lib/libclaimed.a\n' > "$_ws/workspace/.stamps/claimed-1.0"

_out=$( cd "$_ws" && "$ROOT/mediaforge.sh" reconcile 2>&1 ) && _rc=0 || _rc=$?

# Every assertion below asks the same two questions of the same captured report,
# so they are asked once here rather than at every site. FILE-LOCAL on purpose:
# `printf | grep -q` over captured output is spelled out at ~90 sites across
# tests/, so this is the house idiom and a shared helper used only by the newest
# file would be a third spelling rather than a convergence. Converging those is
# worth doing and is not this branch's subject.
_reports()     { printf '%s\n' "$_out" | grep -q "$1"; }
_reports_not() { ! _reports "$1"; }

# --- what it reports -------------------------------------------------------

# The claim in both polarities. A report naming every file in the prefix would
# satisfy the first half alone, which is why the claimed file is in the fixture.
_wrong=''
_reports     'lib/liborphan\.a' || _wrong="$_wrong unclaimed-file-absent-from-report;"
_reports_not 'lib/libclaimed\.a' || _wrong="$_wrong claimed-file-reported-as-unclaimed;"
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

# The count, not just the lines: three unclaimed entries, and the stamp under
# .stamps is not a fourth.
_wrong=''
_reports 'unclaimed: 3' \
  || _wrong="$_wrong summary=[$(printf '%s\n' "$_out" | _evidence 1 'unclaimed|verified')];"
_verdict summary-counts-the-unclaimed "$_wrong"

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
_verdict unclaimed-is-reported-not-removed "$_wrong"

# --prune is documented as meaning STAMPS, and the help text says so in the same
# paragraph that introduces [unclaimed]. The danger is a future edit reading
# "prune" as "prune everything reconcile complained about".
_pout=$( cd "$_ws" && "$ROOT/mediaforge.sh" reconcile --prune 2>&1 ) && _prc=0 || _prc=$?
_wrong=''
printf '%s\n' "$_pout" | grep -q 'liborphan' || _wrong="$_wrong prune-run-reported-nothing;"
[ -f "$_ws/workspace/lib/liborphan.a" ]  || _wrong="$_wrong prune-removed-an-unclaimed-file;"
[ -L "$_ws/workspace/lib/liborphan.so" ] || _wrong="$_wrong prune-removed-the-symlink;"
[ -f "$_ws/workspace/share/pkg/.hidden" ] || _wrong="$_wrong prune-removed-the-nested-dotfile;"
[ "$_prc" = 0 ] || _wrong="$_wrong prune-exit=$_prc;"
_verdict prune-does-not-touch-unclaimed "$_wrong"

# --- the wiring ------------------------------------------------------------
#
# Scoped to the function bodies and read through _code_only, because this repo
# quotes calls verbatim in prose: a whole-file grep for either needle is
# satisfied by the paragraph explaining it, and the audit could then be deleted
# from cmd_reconcile with both assertions still green.
_wrong=''
_fn_body mediaforge.sh cmd_reconcile | _code_only - | grep -q '_reconcile_unclaimed' \
  || _wrong="$_wrong cmd_reconcile-never-calls-it;"
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
_fn_body lib/framework.sh mf_meson | _code_only - \
  | grep -qE '(^|[[:space:]])export[[:space:]]+PYTHONDONTWRITEBYTECODE' \
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
_fn_body lib/framework.sh reset_recipe | _code_only - \
  | grep -q 'unset PYTHONDONTWRITEBYTECODE' \
  || _wrong="$_wrong reset_recipe-does-not-clear-it;"
_verdict bytecode-export-is-cleared-between-recipes "$_wrong"

# reset_recipe is reached through load_recipe, and recipes/ffmpeg.sh does not go
# that way -- mediaforge.sh sources it directly, so without its own unset the
# export from the last meson recipe in _order.conf would still be live through
# FFmpeg's configure, build, and do_install. Benign today (neither runs Python),
# asserted because the invariant is stated as absolute in two comments.
_wrong=''
_fn_body mediaforge.sh cmd_build | _code_only - \
  | grep -q 'unset PYTHONDONTWRITEBYTECODE' \
  || _wrong="$_wrong ffmpeg-source-path-inherits-the-export;"
_verdict bytecode-export-cleared-before-ffmpeg "$_wrong"

# --- the documented surface ------------------------------------------------
#
# --quiet is "report only problems": the per-stamp lines and the summary go, and
# the findings stay. An unclaimed file is a finding, so it survives -- the design
# decision is in cmd_reconcile's own comment and was pinned nowhere.
_qout=$( cd "$_ws" && "$ROOT/mediaforge.sh" reconcile --quiet 2>&1 ) || true
_wrong=''
printf '%s\n' "$_qout" | grep -q 'liborphan' || _wrong="$_wrong quiet-dropped-the-finding;"
printf '%s\n' "$_qout" | grep -q 'unclaimed: ' && _wrong="$_wrong quiet-kept-the-summary;"
_verdict quiet-keeps-findings-drops-summary "$_wrong"

# The help text makes the two falsifiable claims the assertions above pin
# behaviourally. Text and behaviour drift apart silently, and the text is what an
# operator reads before deciding whether to trust the report.
_hout=$( cd "$_ws" && "$ROOT/mediaforge.sh" reconcile --help 2>&1 ) || true
_wrong=''
printf '%s\n' "$_hout" | grep -q '\[unclaimed\]' || _wrong="$_wrong help-omits-the-class;"
printf '%s\n' "$_hout" | grep -q 'does not affect the exit status' \
  || _wrong="$_wrong help-omits-the-advisory-claim;"
printf '%s\n' "$_hout" | grep -q 'prune does not remove it' \
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
# collapsing the loop to `warn "$_rc_list"` emits a bare, unprefixed `lib/evil`.
#
# Its own fixture: the crafted name would otherwise change the count the
# assertions above pin.
_fws="$_tmp/forge"
mkdir -p "$_fws/workspace/.stamps" "$_fws/workspace/lib"
printf 'lib/nothing\n' > "$_fws/workspace/.stamps/empty-1.0"
_forged=$(printf 'evil\n[mediaforge] WARNING: forged by a filename')
: > "$_fws/workspace/lib/$_forged" 2>/dev/null || _forged=''

if [ -n "$_forged" ]; then
  _fout=$( cd "$_fws" && "$ROOT/mediaforge.sh" reconcile 2>&1 ) || true
  # grep -c exits 1 on a count of zero, which is the passing case here.
  _bare=$(printf '%s\n' "$_fout" | grep -cv '^\[mediaforge\]') || true
  _wrong=''
  printf '%s\n' "$_fout" | grep -q 'evil' || _wrong="$_wrong crafted-name-not-reported;"
  [ "${_bare:-0}" = 0 ] \
    || _wrong="$_wrong unprefixed-line(s)=$_bare: [$(printf '%s\n' "$_fout" | grep -v '^\[mediaforge\]' | head -1)];"
  _verdict a-newline-in-a-filename-cannot-forge-a-line "$_wrong"
else
  # A filesystem that refuses the name cannot host the claim. Reported rather
  # than skipped silently, so a permanent skip is visible in the log.
  _bad a-newline-in-a-filename-cannot-forge-a-line "fixture unavailable: filesystem rejected a newline in a filename"
fi

printf 'DONE: reconcile-unclaimed\n'
exit "$_fail"
