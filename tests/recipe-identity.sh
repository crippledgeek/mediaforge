#!/bin/sh
# One recipe identity for every name a user can type.
#
# THE BUG THIS PINS. The codebase carried two notions of what a recipe is
# called. lib/registry.sh builds the registry from _order.conf PATHS, so
# --disable=, --enable= and --skip-checksum= are all validated against recipe
# FILENAMES; lib/resolve.sh likewise writes its mutex exclusions into
# DISABLE_PKGS by filename. check_guards then compared those names against
# PKG_NAME, which is a DISPLAY name that three recipes deliberately differ on:
#
#   recipes/other/vapoursynth.sh          PKG_NAME="VapourSynth"
#   recipes/other/freetype2.sh            PKG_NAME="FreeType2"
#   recipes/other/freetype2-harfbuzz.sh   PKG_NAME="FreeType2-hb"
#
# So `--disable=vapoursynth` passed validation, printed no warning, and did
# nothing -- the recipe built anyway and its FFmpeg flag was still emitted.
#
# NOT MERELY A UX WART. The FFmpeg-flag half is the one that would ship a wrong
# binary, and the resolver makes it reachable without anyone typing a name: a
# mutex group containing one of those three would write the loser's FILENAME
# into DISABLE_PKGS, the guard would not match it, and both members of the
# group would be built and both flags emitted.
#
# The fix is recipe_key() in lib/registry.sh -- derived from PKG_HASH_FILE,
# which load_recipe sets from the recipe's own path -- used everywhere a
# CLI-facing name is compared. PKG_NAME keeps the log lines, which is what it
# is for; renaming the three recipes instead was the riskier direction, since
# PKG_NAME also names the stamp files an already-built workspace carries.
#
# Usage: tests/recipe-identity.sh
# Exit 0 = pass, 1 = regression.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT" || exit 1
_fail=0

_pass() { printf 'PASS [%s]\n' "$1"; }
_bad()  { printf 'FAIL [%s] %s\n' "$1" "${2-}" >&2; _fail=1; }

# ── the divergence this is all about actually still exists ──────────────────
# Asserted rather than assumed: if someone renames the three PKG_NAMEs to match
# their filenames, every other assertion here would pass for a reason that has
# nothing to do with recipe_key, and this file would quietly stop testing it.
# That is not a failure -- it is a signal that the fix moved -- so it reports
# as one loudly instead of leaving a green file measuring nothing.
# Sorted rather than left in glob order: the shell's order depends on the
# locale's collation, so an unsorted comparison passes here and fails elsewhere.
_diverge=$(for _f in "$ROOT"/recipes/*/*.sh; do
  _n=$(awk -F'"' '/^PKG_NAME=/ { print $2; exit }' "$_f")
  _b=${_f##*/}; _b=${_b%.sh}
  [ "$_n" = "$_b" ] || printf '%s\n' "$_b"
done | LC_ALL=C sort | tr '\n' ' ')
_diverge=${_diverge% }

# ── end to end: --disable=<filename> reaches a divergently-named recipe ─────
# Through the real CLI under --dry-run, because the defect was precisely that
# every layer in between (validation, the registry, the resolver) agreed on the
# filename and only the guard did not.
#
# ANDed with the divergence check above rather than asserting that separately:
# the divergence is a property of the tree BEFORE the fix as much as after, so
# a standalone assertion on it would pass on the pre-fix tree and tell
# tests/oracle-baseline.sh that this file detects something it does not.
_dis=$(./mediaforge.sh build --dry-run --yes --disable=vapoursynth 2>&1)
if [ "$_diverge" = "freetype2 freetype2-harfbuzz vapoursynth" ] \
   && printf '%s' "$_dis" | grep -q 'Skipping VapourSynth (disabled via CLI)'; then
  _pass disable-by-filename-skips-divergent-recipe
else
  _bad disable-by-filename-skips-divergent-recipe "--disable=vapoursynth did not skip the recipe"
fi

# The half that would ship a wrong binary. run_recipe re-accumulates a skipped
# recipe's PKG_FFMPEG_OPT unless it can tell the skip was a POLICY exclusion,
# and it told them apart by the same mismatched name -- so even once the recipe
# is skipped, the flag has to be gone from the configure line too.
# Matched on the `Would configure FFmpeg with:` line specifically: the word
# appears elsewhere in a dry-run log for unrelated reasons.
_disline=$(printf '%s\n' "$_dis" | grep 'Would configure FFmpeg with:' | head -1)
if [ -n "$_disline" ] && ! printf '%s' "$_disline" | grep -q -- '--enable-vapoursynth'; then
  _pass disable-by-filename-drops-ffmpeg-flag
else
  _bad disable-by-filename-drops-ffmpeg-flag "configure line still carries --enable-vapoursynth: [$_disline]"
fi

# Not one recipe's bug: the same must hold for the other two divergent names.
_dis2=$(./mediaforge.sh build --dry-run --yes --disable=freetype2-harfbuzz 2>&1)
if printf '%s' "$_dis2" | grep -q 'Skipping FreeType2-hb (disabled via CLI)'; then
  _pass disable-by-filename-skips-second-divergent-recipe
else
  _bad disable-by-filename-skips-second-divergent-recipe "--disable=freetype2-harfbuzz did not skip the recipe"
fi

# ── in process: both directions of check_guards, on a synthetic recipe ──────
# No recipe currently combines PKG_DISABLED=true with a divergent PKG_NAME, so
# the --enable= direction has no end-to-end route today. It is one recipe edit
# away from having one, and it is the same comparison, so it is exercised
# directly against check_guards with the divergence constructed here.
#
# check_guards exists on the pre-fix tree, so these need no _require_fn guard:
# there they run and legitimately report the old behaviour as a failure.
# lib/platform.sh is deliberately NOT sourced: it needs build-time state this
# file has no reason to set up, and check_guards only reads OS_LINUX/OS_ARCH
# behind guards the synthetic recipe below leaves off.
. "$ROOT/lib/utils.sh"
. "$ROOT/lib/registry.sh"
. "$ROOT/lib/framework.sh"
OS_LINUX=true
OS_ARCH=""

_synth_reset() {
  reset_recipe
  PKG_NAME="SynthName"
  PKG_VERSION="1"
  PKG_HASH_FILE="$ROOT/recipes/other/synth-file.hash"
  ENABLE_GPL=true
  ENABLE_NONFREE=true
  DISABLE_PKGS=""
  ENABLE_PKGS=""
}

_synth_reset
DISABLE_PKGS="synth-file"
if check_guards >/dev/null 2>&1; then
  _bad guard-disables-on-filename-not-display-name "check_guards ran a recipe whose filename is in DISABLE_PKGS"
else
  _pass guard-disables-on-filename-not-display-name
fi

# ...and the display name must NOT be a way in, or the two identities are still
# both live and the next mutex group picks whichever one its author guessed.
_synth_reset
DISABLE_PKGS="SynthName"
if check_guards >/dev/null 2>&1; then
  _pass guard-ignores-display-name-in-disable-list
else
  _bad guard-ignores-display-name-in-disable-list "check_guards skipped a recipe listed only by its display name"
fi

_synth_reset
PKG_DISABLED=true
ENABLE_PKGS="synth-file"
if check_guards >/dev/null 2>&1; then
  _pass enable-by-filename-forces-divergent-recipe
else
  _bad enable-by-filename-forces-divergent-recipe "--enable=<filename> did not force-enable an opt-in recipe with a divergent PKG_NAME"
fi

# ...and an underivable identity is FATAL, not a quiet fall back to the display
# name. This guard originally read `$(recipe_key) || _guard_key="$PKG_NAME"`,
# and that fallback is precisely what hid a real defect: a test file sourced
# lib/framework.sh without lib/registry.sh, recipe_key was undefined, the
# fallback fired, and check_guards compared against the very identity this
# branch removed -- with the suite green throughout. A path documented as
# unreachable must prove it by stopping, not by degrading to the wrong answer.
#
# Run in a subshell because die() calls exit; without it a regression here would
# terminate this file rather than report.
_synth_reset
PKG_HASH_FILE=""
DISABLE_PKGS="synth-file"
_fatalout=$( check_guards 2>&1 )
_fatalrc=$?
# Both halves matter. A non-zero status alone passes on the pre-fix tree for the
# wrong reason -- there, check_guards with an empty PKG_HASH_FILE simply returns
# 0 or 1 from its ordinary guards and never says anything about identity -- so
# the message is what distinguishes a deliberate abort from a routine skip.
if [ "$_fatalrc" -ne 0 ] && printf '%s' "$_fatalout" | grep -qF 'Cannot derive a CLI identity'; then
  _pass underivable-identity-is-fatal
else
  _bad underivable-identity-is-fatal "expected a fatal identity error; rc=$_fatalrc output=[$_fatalout]"
fi

printf 'DONE:\n'
exit "$_fail"
