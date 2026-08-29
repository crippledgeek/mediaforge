#!/bin/sh
# Install-manifest reconciliation — regression tests for crippledgeek/mediaforge#15.
#
# do_install used to create an EMPTY manifest accumulator per run, append only
# what that run copied, and then overwrite the previous manifest wholesale. It
# never removed anything. So a file shipped by an older build and dropped by a
# newer one stayed on disk AND vanished from the record — and do_uninstall,
# which iterates the manifest and nothing else, could not see it again. The
# instance that surfaced it was V-Nova's split lcevc archives, orphaned by
# 829b927 merging them into one; eight .a files survived an uninstall that
# reported success, and the "isolated prefix removes itself" behaviour silently
# degraded to "prefix left behind".
#
# Most assertions here are COMPOUND, deliberately. tests/oracle-baseline.sh
# requires that no assertion passes on the merge base, and each half that proves
# the prune is conservative — a foreign file survives, a traversing entry is
# refused, a still-shipped file is kept — is true on the base as well, where
# nothing is pruned at all. Pairing each with a removal the base fails to
# perform is what keeps the safety half asserted without buying a free pass.
#
# The cases driven through UNINSTALL rather than install would not strictly need
# the pairing — the base really does act on a manifest there, and really does
# get it wrong — but they carry one anyway, because "the thing outside the
# prefix is still there" is equally satisfied by a run that died before reaching
# the sweep at all. The pairing proves the code under test ran.
#
# No `set -e`: every check reports independently and the script exits with the
# accumulated status, so one early failure does not hide the rest — and the
# baseline gate depends on that, since a file that aborts early cannot prove the
# assertions after the abort point.
set -u

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
_root=$(CDPATH='' cd -- "$_here/.." && pwd)
cd "$_root" || exit 1

_fail=0
# shellcheck source=tests/lib-assert.sh
. "$_root/tests/lib-assert.sh"
# shellcheck source=tests/lib-install-driver.sh
. "$_root/tests/lib-install-driver.sh"

# One temp root for the whole file, removed on exit however we leave. Each case
# takes a fresh subdirectory of it, so a `exit 1` on a later mktemp cannot strand
# the dirs the earlier cases made.
_tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$_tmp"' EXIT INT TERM

# $1 names a case; sets _s (staging prefix), _d (install prefix) and _out_dir as
# siblings, so a manifest entry of "../<name>" reaches a known path outside the
# install prefix without depending on how mktemp names things.
_case() {
  _s="$_tmp/$1/stage"
  _d="$_tmp/$1/dest"
  _out_dir="$_tmp/$1"
  mkdir -p "$_s" "$_d" || exit 1
}

# Driven in a separate `sh` rather than a ( ) subshell, matching
# tests/install-containment.sh: do_install reads PREFIX/AUTOINSTALL from the
# environment, and shadowing this script's own PREFIX inside a subshell would
# both confuse the reader and leak install.sh's functions into the assertions.
#
# Both merge stderr internally, so call sites need no redirection of their own —
# the output is captured and several assertions read it.
_run_install() {
  _install_sh "$1" do_install "$2"
}

_run_uninstall() {
  _install_sh "$1" do_uninstall "$2"
}

# A staging prefix holding one file of each class this file exercises, plus the
# two that a later "version" drops: a static archive beside one it keeps, and a
# header in a subdirectory of its own so the directory sweep has something to
# collect.
_make_stage() {
  mkdir -p "$1/bin" "$1/lib" "$1/include/drop" "$1/.logs"
  printf 'FFMPEG-BINARY\n' > "$1/bin/ffmpeg"
  printf 'KEPT-LIB\n'       > "$1/lib/libmediaforge-keep.a"
  printf 'DROPPED-LIB\n'    > "$1/lib/libmediaforge-drop.a"
  printf 'HEADER\n'         > "$1/include/mediaforge-probe.h"
  printf 'DROPPED-HEADER\n' > "$1/include/drop/mediaforge-drop.h"
}

# The newer "version": the same stage with the two files the recipe no longer
# ships. Mirrors recipes/other/lcevc.sh dropping the split archives.
_drop_from_stage() {
  rm -f "$1/lib/libmediaforge-drop.a" "$1/include/drop/mediaforge-drop.h"
  rmdir "$1/include/drop" 2>/dev/null || :
}

# Every regular file under the prefix, manifest excluded, prefix-relative and
# sorted — the set the manifest is supposed to describe exactly.
_disk_set() {
  ( cd "$1" 2>/dev/null || exit 0
    find . -type f ! -name .mediaforge-manifest | sed 's|^\./||' | LC_ALL=C sort )
}

# ─── an install-over-install removes what the new build no longer ships ─────
# Compound with the kept archive: "libmediaforge-keep.a is still there" is true
# on the base too, where nothing is removed at all.
_case drop
_make_stage "$_s"
_run_install "$_s" "$_d" >/dev/null
_drop_from_stage "$_s"
_prune_out=$(_run_install "$_s" "$_d")
if [ ! -e "$_d/lib/libmediaforge-drop.a" ] && [ -f "$_d/lib/libmediaforge-keep.a" ]; then
  _pass reinstall-prunes-dropped-keeps-rest
else
  _bad reinstall-prunes-dropped-keeps-rest
fi

# The manifest is the record uninstall acts on, so what it says has to match
# what is on disk EXACTLY — not merely omit the pruned entry, which the base
# also does (it overwrites the manifest wholesale, which is how the file went
# missing from the record while staying on disk). Comparing both directions is
# what makes this an oracle for the finalize as well as for the prune: a prune
# that removed too much, or a manifest that forgot a file it installed, both
# show up here and in nothing else.
_manifest_set=$(LC_ALL=C sort "$_d/.mediaforge-manifest" 2>/dev/null)
if [ -n "$_manifest_set" ] && [ "$_manifest_set" = "$(_disk_set "$_d")" ]; then
  _pass manifest-matches-disk-after-prune
else
  _bad manifest-matches-disk-after-prune
fi

# The count is reported, and it is the count of files actually removed. Silence
# would leave an operator with no way to know a privileged deletion happened.
if printf '%s\n' "$_prune_out" | grep -q 'pruned 2 file(s)'; then
  _pass prune-reports-removed-count
else
  _bad prune-reports-removed-count
fi

# A directory the prune empties is collected, like the bottom-up sweep
# do_uninstall already runs. Paired with the surviving sibling header.
if [ ! -d "$_d/include/drop" ] && [ -f "$_d/include/mediaforge-probe.h" ]; then
  _pass emptied-directory-collected-sibling-kept
else
  _bad emptied-directory-collected-sibling-kept
fi

# ─── the prune touches nothing mediaforge did not install ───────────────────
# The shared-prefix case (~/.local, /usr/local): a file the manifest never
# listed is not ours to remove, however it got there.
_case foreign
_make_stage "$_s"
_run_install "$_s" "$_d" >/dev/null
printf 'NOT-OURS\n' > "$_d/lib/libsomeone-else.a"
_drop_from_stage "$_s"
_run_install "$_s" "$_d" >/dev/null
if [ -f "$_d/lib/libsomeone-else.a" ] && [ ! -e "$_d/lib/libmediaforge-drop.a" ]; then
  _pass foreign-file-survives-prune
else
  _bad foreign-file-survives-prune
fi

# ─── a traversing entry in the OLD manifest is refused ──────────────────────
# The prune reads a file that lives inside the install prefix and drives `rm -f`
# from it, under sudo for a system prefix. That is the same trust boundary
# do_uninstall guards at its own read, so the same refusal has to apply here —
# on the copy of the manifest that was on disk BEFORE this run, which is the one
# an earlier compromise could have edited.
#
# All three spellings the guard claims to cover, not just the leading one: a
# relative climb, a climb from the middle of an otherwise innocent path, and an
# absolute path that ignores the prefix altogether.
_case traverse
_make_stage "$_s"
mkdir -p "$_out_dir/escape"
printf 'OUTSIDE\n' > "$_out_dir/escape/probe"
printf 'ABSOLUTE\n' > "$_out_dir/absolute-probe"
_run_install "$_s" "$_d" >/dev/null
{ printf '../escape/probe\n'
  printf 'lib/../../escape/probe\n'
  printf '%s\n' "$_out_dir/absolute-probe"
} >> "$_d/.mediaforge-manifest"
_drop_from_stage "$_s"
_run_install "$_s" "$_d" >/dev/null
if [ -f "$_out_dir/escape/probe" ] \
   && [ -f "$_out_dir/absolute-probe" ] \
   && [ ! -e "$_d/lib/libmediaforge-drop.a" ]; then
  _pass traversing-manifest-entry-refused
else
  _bad traversing-manifest-entry-refused
fi

# ─── the directory sweep refuses a traversing entry too ─────────────────────
# Driven through uninstall, because that is where the base reaches the sweep at
# all. The base's climb had no traversal guard: dirname("../victim/x") is
# "../victim", and the climb stops only when it reaches the target, so `rmdir`
# was invoked on a directory outside the prefix and removed it when it happened
# to be empty. An EMPTY directory is therefore the whole test — a non-empty one
# is saved by rmdir's own refusal and proves nothing about the guard.
_case sweep
_make_stage "$_s"
mkdir -p "$_out_dir/victim"
_run_install "$_s" "$_d" >/dev/null
printf '../victim/ghost\n' >> "$_d/.mediaforge-manifest"
_run_uninstall "$_s" "$_d" >/dev/null
# Paired with proof the sweep actually ran: "the victim is still there" is also
# satisfied by an uninstall that died before reaching the directory pass, which
# would turn this green for the wrong reason after some future change.
if [ -d "$_out_dir/victim" ] && [ ! -e "$_d/bin/ffmpeg" ]; then
  _pass directory-sweep-refuses-traversal
else
  _bad directory-sweep-refuses-traversal
fi

# ─── a symlinked intermediate cannot redirect the deletion ─────────────────
# The case NO lexical check can catch, and the one the guards above do not
# actually pin: `lib/libmediaforge-keep.a` spells nothing suspicious, so the
# '..'-and-leading-'/' refusal passes it, and if <prefix>/lib is a symlink the
# privileged `rm -f` follows it and deletes the file at the real target instead.
# That is #21's finding on the write path, arriving on the delete path.
#
# Measured while writing this file: mutating the containment check to accept
# everything, and separately mutating the lexical guard to refuse nothing, were
# BOTH uncaught by the traversal cases above — each guard alone still refused a
# `../`-spelled entry, so neither was being detected. This case is detected by
# containment only, which is what makes it the oracle for it. The lexical guard
# stays as defense in depth, and is deliberately not claimed to be pinned
# independently.
#
# Driven through uninstall, because that is where the base performs a deletion
# from a manifest at all: the base has no prune, so an install-side version of
# this would pass there and buy a free gate pass.
_case symlinked
_make_stage "$_s"
mkdir -p "$_out_dir/elsewhere"
printf 'NOT-OURS\n' > "$_out_dir/elsewhere/libmediaforge-keep.a"
_run_install "$_s" "$_d" >/dev/null
# Swap the class directory for a symlink out of the prefix, exactly as
# tests/install-privileged-execs.sh does for the write side. Moved aside rather
# than deleted: an attacker preserves the files, since a vanished lib/ is
# noticed and a redirected one is not.
mv "$_d/lib" "$_d/lib.orig"
ln -s "$_out_dir/elsewhere" "$_d/lib"
_sym_out=$(_run_uninstall "$_s" "$_d")
if [ -f "$_out_dir/elsewhere/libmediaforge-keep.a" ]; then
  _pass symlinked-dir-cannot-redirect-deletion
else
  _bad symlinked-dir-cannot-redirect-deletion
fi

# Refusing quietly would leave an operator with a partial uninstall and no idea
# why. Paired with a removal that DID happen, so a helper that refuses
# everything cannot satisfy this.
if printf '%s\n' "$_sym_out" | grep -q 'resolves outside' \
   && [ ! -e "$_d/bin/ffmpeg" ]; then
  _pass deletion-refusal-reported-others-proceed
else
  _bad deletion-refusal-reported-others-proceed
fi

# ─── a damaged removal helper is refused, not read as success ──────────────
# Three distinct ways the helper can be damaged, each caught by a DIFFERENT arm
# of the caller, because a single case would credit whichever arm happens to run
# first. An empty or truncated `sh -c` script exits 0 under POSIX, so a damaged
# helper is otherwise indistinguishable from a completed sweep that found
# nothing to do — uninstall would report success having deleted nothing, which
# is #15's own failure mode arriving by another route.
#
# Every case runs against a COPY of the tree, never the real one: a test that
# mutates lib/ in the shared checkout is how a green suite gets left behind on a
# broken tree.
#
# $1 names the case, $2 is the helper's replacement text (empty for a zero-byte
# file), $3 the message the caller must emit. Sets _damaged_out.
_run_with_damaged_helper() {
  _fake_root="$_out_dir/fake-$1"
  mkdir -p "$_fake_root/lib" || exit 1
  cp "$_root"/lib/*.sh "$_fake_root/lib/" || exit 1
  if [ -n "$2" ]; then
    printf '%s\n' "$2" > "$_fake_root/lib/remove-listed-files.sh"
  else
    : > "$_fake_root/lib/remove-listed-files.sh"
  fi
  # The subshell is what keeps MF_SCRIPT_DIR off the rest of this file: an
  # assignment prefixing a FUNCTION call persists in the caller's shell, unlike
  # one prefixing a command, so every later _run_install would load the damaged
  # tree too.
  _damaged_out=$( MF_SCRIPT_DIR="$_fake_root" _install_sh "$_s" do_uninstall "$_d" )
}

# Paired with "the tree is untouched" throughout: a caller that aborts for the
# right reason but only after deleting half the manifest is not the behaviour
# any of these are asking for.
_case damaged
_make_stage "$_s"
_run_install "$_s" "$_d" >/dev/null

_run_with_damaged_helper empty ''
if printf '%s\n' "$_damaged_out" | grep -q 'is empty' && [ -f "$_d/bin/ffmpeg" ]; then
  _pass empty-removal-helper-aborts-sweep
else
  _bad empty-removal-helper-aborts-sweep
fi

# A helper that is valid, non-empty, and does nothing — the input the REMOVED
# sentinel exists for, and the one the emptiness check above cannot see. Without
# the sentinel this exits 0 having removed nothing and reads as a clean sweep.
_run_with_damaged_helper silent ':'
# Greps the arm's own wording, not the word REMOVED: nothing else on this path
# prints REMOVED today, so matching it would pass by coincidence and stop the
# day a neighbouring message mentions the sentinel.
if printf '%s\n' "$_damaged_out" | grep -q 'without completing' && [ -f "$_d/bin/ffmpeg" ]; then
  _pass helper-without-sentinel-refused
else
  _bad helper-without-sentinel-refused
fi

# Truncated mid-construct: `sh` returns 2 for a syntax error, which the caller
# maps to its own message precisely so a damaged file is never reported as the
# containment refusal — sending an operator after an attack that is not
# happening, for a file that is merely broken.
_run_with_damaged_helper syntax 'if'
if printf '%s\n' "$_damaged_out" | grep -q 'failed to parse' && [ -f "$_d/bin/ffmpeg" ]; then
  _pass truncated-helper-diagnosed-as-damage
else
  _bad truncated-helper-diagnosed-as-damage
fi

# A count that is not a number. `[0-9]*` in a case pattern means "one digit then
# anything", so the accepting arm alone would admit this and the value would
# reach an arithmetic test — surfacing as a shell error about an integer
# expression rather than as a message naming the helper.
_run_with_damaged_helper malformed 'printf "REMOVED 5garbage\n"'
if printf '%s\n' "$_damaged_out" | grep -q 'malformed count' && [ -f "$_d/bin/ffmpeg" ]; then
  _pass non-numeric-count-rejected
else
  _bad non-numeric-count-rejected
fi

# ─── an unreadable manifest is refused, not counted as zero ────────────────
# `done < "$_list"` on a compound command does not abort a non-interactive
# shell when the redirection fails — execution falls through to the sentinel,
# which prints REMOVED 0 over a list that was never opened. Running the helper
# as root closed the root-owned-0600 instance of this and nothing else; a
# mode-000 manifest in a user-owned prefix reaches the same end state.
_case unreadable
_make_stage "$_s"
_run_install "$_s" "$_d" >/dev/null
chmod 000 "$_d/.mediaforge-manifest"
_unreadable_out=$(_run_uninstall "$_s" "$_d")
chmod 600 "$_d/.mediaforge-manifest"
if printf '%s\n' "$_unreadable_out" | grep -q 'cannot open the manifest' \
   && [ -f "$_d/bin/ffmpeg" ]; then
  _pass unreadable-manifest-aborts-sweep
else
  _bad unreadable-manifest-aborts-sweep
fi

# ─── the whole list costs ONE privileged exec ──────────────────────────────
# lib/remove-listed-files.sh's header argues that its containment is not the
# trade #23 refused, because checking every entry now costs one exec for the
# list instead of one per entry — ~250 on an install, 1527 on the uninstall that
# surfaced #15. That is a load-bearing design claim and nothing asserted it;
# tests/install-privileged-execs.sh pins the same property on the write side and
# this borrows its counting-`sudo`-shim technique.
#
# _remove_manifest_entries is driven directly with _priv=sudo, because a prefix
# this user cannot write is not something a test can create without being root.
# Paired with "and the files really went", so a helper that wins the count by
# refusing everything fails the same assertion.
#
# Honest about WHY this one fails on the merge base: _remove_manifest_entries
# does not exist there, so the shim log is empty and the count is 0 — absence,
# not a wrong count. Its oracle on the current tree is still the real thing: a
# revert to the per-entry `$_priv rm -f` shape logs one exec per manifest entry
# (five for this stage), which this refuses.
_case execs
_make_stage "$_s"
_run_install "$_s" "$_d" >/dev/null
_shim="$_out_dir/shim"
mkdir -p "$_shim" || exit 1
cat > "$_shim/sudo" <<'SHIM'
#!/bin/sh
printf '%s\n' "$1" >> "$SUDO_LOG"
exec "$@"
SHIM
chmod +x "$_shim/sudo"
_sudo_log="$_out_dir/sudo.log"
: > "$_sudo_log"
# Not _install_sh: this drives one internal helper with _priv forced, not an
# entry point, and it needs the sudo shim on PATH.
PATH="$_shim:$PATH" SUDO_LOG="$_sudo_log" \
PREFIX="$_s" SCRIPT_DIR="$_root" VERBOSE=0 \
sh -c "$_MF_INSTALL_SOURCES
  _priv=sudo
  _remove_manifest_entries files \"\$1/.mediaforge-manifest\" \"\$1\"
" _ "$_d" >/dev/null 2>&1
_exec_count=$(wc -l < "$_sudo_log" | tr -d ' ')
_entry_count=$(wc -l < "$_d/.mediaforge-manifest" | tr -d ' ')
if [ "$_exec_count" = 1 ] && [ "$_entry_count" -gt 1 ] && [ ! -e "$_d/bin/ffmpeg" ]; then
  _pass whole-manifest-removal-costs-one-exec
else
  _bad whole-manifest-removal-costs-one-exec
fi

# ─── the sweeps run through the same helper as everything else ─────────────
# do_uninstall's dangling-symlink sweep and its second rmdir pass were the last
# two privileged deletes composing a path lexically and never entering it. They
# now go through lib/remove-listed-files.sh's 'links' and 'emptydirs' modes.
#
# The fixpoint is what the base gets WRONG, and it is the oracle for both
# assertions below. `find -depth -type d -empty` decides -empty when it VISITS a
# directory: given lib/orphan/nested, it visits nested (empty, listed) and then
# orphan (still holding nested, so NOT listed) — and the base's single pass
# leaves orphan behind. Repeating to a fixpoint removes both. Neither directory
# is in the manifest, so the manifest-driven climb never touches them and this
# is a property of the sweep alone.
_case sweeps
_make_stage "$_s"
_run_install "$_s" "$_d" >/dev/null
mkdir -p "$_d/lib/orphan/nested" || exit 1
ln -s "$_d/lib/libmediaforge-keep.a" "$_d/lib/dangling.link"
# The live link's target must OUTLIVE the uninstall, or "live" is meaningless by
# the time the sweep runs — anything inside the prefix is removed by the
# manifest pass first, which would make this a second dangling link.
printf 'STILL-HERE\n' > "$_out_dir/anchor"
ln -s "$_out_dir/anchor" "$_d/lib/live.link"
_run_uninstall "$_s" "$_d" >/dev/null

if [ ! -d "$_d/lib/orphan" ]; then
  _pass empty-directory-sweep-reaches-fixpoint
else
  _bad empty-directory-sweep-reaches-fixpoint
fi

# The sweep's other two properties — a dangling link goes, a live one stays —
# are ALSO true on the base, which swept dangling links correctly. They are
# paired with the fixpoint result above for that reason, and that half is
# deliberately the same one assertion #1 rests on: it is the only behaviour in
# this area the base gets wrong, so it is the only pairing available.
# `-L` on the live link is the load-bearing clause and was missing: unlinking a
# symlink never touches its target, so asserting only that the anchor survives
# is satisfied by a sweep that deletes the link. Without it, mutating the link
# predicate from `[ -L ] && [ ! -e ]` to a bare `[ -L ]` would delete every
# symlink under the prefix and this file would stay green — the exact "names a
# property it does not test" shape the manifest assertion was rewritten for.
if [ ! -e "$_d/lib/dangling.link" ] && [ ! -L "$_d/lib/dangling.link" ] \
   && [ -L "$_d/lib/live.link" ] \
   && [ -f "$_out_dir/anchor" ] \
   && [ ! -d "$_d/lib/orphan" ]; then
  _pass dangling-symlink-swept-live-kept
else
  _bad dangling-symlink-swept-live-kept
fi

# ─── an already-deleted entry is not reported as an escape attempt ─────────
# _enter_contained returns three outcomes, and the reason is this message. When
# "could not enter" and "resolves outside" were one failure, a manifest entry
# whose parent directory a user had already removed by hand printed "refusing to
# remove X — it resolves outside <prefix>": an alarm about an attack, raised
# over a tidy tree. An operator who believes it goes looking for a symlink that
# was never there.
#
# Paired with the fixpoint, the only behaviour here the base gets wrong — the
# base prints no refusals at all, so the absence of the message is trivially
# true there.
_case tidied
_make_stage "$_s"
_run_install "$_s" "$_d" >/dev/null
mkdir -p "$_d/lib/orphan/nested" || exit 1
# Remove a whole class directory the manifest still lists, which is what makes
# _enter_contained fail to enter rather than fail containment.
rm -rf "${_d:?}/include"
_tidied_out=$(_run_uninstall "$_s" "$_d")
if ! printf '%s\n' "$_tidied_out" | grep -q 'resolves outside' \
   && [ ! -d "$_d/lib/orphan" ]; then
  _pass already-deleted-entry-not-an-escape
else
  _bad already-deleted-entry-not-an-escape
fi

# ─── uninstall creates nothing outside the target prefix ───────────────────
# Routing the sweeps through the helper briefly staged their root list in
# $PREFIX/.logs, following the install path's precedent. That precedent does not
# transfer: $PREFIX is set unconditionally by mediaforge.sh and uninstall needs
# nothing from it, so `./mediaforge.sh uninstall` in a fresh clone — or after
# `clean` — created a build workspace as a side effect of removing something
# else. The list belongs in /tmp, like the manifest accumulator.
#
# Paired with the fixpoint result, which is the only behaviour here the base
# gets wrong: the base never created $PREFIX either, so the first half alone
# would pass there.
_case prefixless
_make_stage "$_s"
_run_install "$_s" "$_d" >/dev/null
mkdir -p "$_d/lib/orphan/nested" || exit 1
_absent_prefix="$_out_dir/never-built"
_install_sh "$_absent_prefix" do_uninstall "$_d" >/dev/null 2>&1
if [ ! -e "$_absent_prefix" ] && [ ! -d "$_d/lib/orphan" ]; then
  _pass uninstall-creates-nothing-outside-prefix
else
  _bad uninstall-creates-nothing-outside-prefix
fi

# ─── an install that copies nothing changes nothing ─────────────────────────
# The prune's own boundary. Its input is "everything the previous manifest lists
# that this run did not install", so a run that installs NOTHING — an unbuilt or
# cleaned $PREFIX — makes the entire previous install an orphan and would delete
# it wholesale. The accumulator being empty is the one input for which the diff
# is meaningless rather than merely large, so both the prune and the manifest
# rewrite are refused.
#
# The disk half is true on the base as well (nothing was ever pruned there); the
# manifest half is not, because the base finalizes the empty accumulator over a
# good manifest and thereby forgets an install that is still on disk — a second
# defect of the same overwrite, reachable without any recipe ever dropping a file.
_case empty
_make_stage "$_s"
_run_install "$_s" "$_d" >/dev/null
rm -rf "${_s:?}/bin" "${_s:?}/lib" "${_s:?}/include"
_empty_out=$(_run_install "$_s" "$_d")
if [ -f "$_d/lib/libmediaforge-keep.a" ] \
   && [ -f "$_d/.mediaforge-manifest" ] \
   && grep -q 'libmediaforge-keep\.a' "$_d/.mediaforge-manifest"; then
  _pass no-op-install-changes-nothing
else
  _bad no-op-install-changes-nothing
fi

# Leaving them alone silently is indistinguishable from a successful install of
# zero files, and the exit status stays 0 either way, so the warning IS the
# signal. README.md advertises it; assert the thing it advertises.
if printf '%s\n' "$_empty_out" | grep -q 'Nothing was installed'; then
  _pass no-op-install-reports-itself
else
  _bad no-op-install-reports-itself
fi

# ─── uninstall after an install-over-install is still pristine ──────────────
# The documented invariant (CLAUDE.md, README.md): an isolated prefix removes
# itself. On a tree without the prune the orphan keeps lib/ non-empty, the
# bottom-up rmdir correctly refuses, and the prefix root is left behind with no
# warning — which is exactly how #15 was found.
_case pristine
_make_stage "$_s"
_run_install "$_s" "$_d" >/dev/null
_drop_from_stage "$_s"
_run_install "$_s" "$_d" >/dev/null
_run_uninstall "$_s" "$_d" >/dev/null
if [ ! -d "$_d" ]; then
  _pass isolated-prefix-pristine-after-reinstall-uninstall
else
  _bad isolated-prefix-pristine-after-reinstall-uninstall
fi

printf 'DONE: install-manifest-reconcile\n'
exit "$_fail"
