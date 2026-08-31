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
mkdir -p "$_ws/workspace/.stamps" "$_ws/workspace/lib" "$_ws/workspace/share/pkg"

echo claimed > "$_ws/workspace/lib/libclaimed.a"
echo orphan  > "$_ws/workspace/lib/liborphan.a"
echo nested  > "$_ws/workspace/share/pkg/.hidden"
echo state   > "$_ws/workspace/.mediaforge-choices"
ln -s liborphan.a "$_ws/workspace/lib/liborphan.so"

printf 'lib/libclaimed.a\n' > "$_ws/workspace/.stamps/claimed-1.0"

_out=$( cd "$_ws" && "$ROOT/mediaforge.sh" reconcile 2>&1 ) && _rc=0 || _rc=$?

# Every assertion below asks the same two questions of the same captured report,
# so they are asked once here rather than nine times inline. FILE-LOCAL on
# purpose: `printf | grep -q` over captured output is spelled out at 98 sites
# across tests/, so this is the house idiom and a shared helper used only by the
# newest file would be a third spelling rather than a convergence. Converging
# those 98 is worth doing and is not this branch's subject.
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
_wrong=''
_fn_body lib/framework.sh mf_meson | _code_only - | grep -q 'PYTHONDONTWRITEBYTECODE' \
  || _wrong="$_wrong mf_meson-still-writes-bytecode;"
_verdict meson-bytecode-suppressed-at-source "$_wrong"

# The export's LIFETIME, which is the half that cannot be read off mf_meson.
# `meson setup` is not the only writer -- `ninja -C build install` spawns
# `meson --internal install` -- so the variable has to outlive the setup call
# and reach the recipe's later ninja invocations. run_recipe is a plain call and
# every recipe is sourced into one shell, so what stops it reaching every LATER
# recipe is reset_recipe clearing it. Without this assertion the export could be
# narrowed back to a single command and the suite would not notice, because
# every assertion above is satisfied by the setup call alone.
_wrong=''
_fn_body lib/framework.sh reset_recipe | _code_only - \
  | grep -q 'unset PYTHONDONTWRITEBYTECODE' \
  || _wrong="$_wrong reset_recipe-does-not-clear-it;"
_verdict bytecode-suppression-is-recipe-scoped "$_wrong"

printf 'DONE: reconcile-unclaimed\n'
exit "$_fail"
