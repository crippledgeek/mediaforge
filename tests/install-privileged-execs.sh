#!/bin/sh
# One privileged exec per installed file — #23, and the reason its accepted
# TOCTOU trade no longer exists.
#
# _install_file must resolve every destination under $_priv before it writes, so
# the containment check sees the filesystem the privileged cp will see (#21).
# Done as separate sudo calls that cost five setuid execs per file — a `test -d`
# ancestor walk, an `sh -c` resolve, then mkdir, rm and cp — and a real FFmpeg
# tree installs ~250 files, which is what #23 was opened about.
#
# Memoizing the resolution per directory was the shape #23 suggested. It cut the
# execs and widened the check-to-write window from per-file to per-directory:
# once a directory was vetted, the rest of its files rode on that verdict. This
# file asserts the answer that does not make that trade — ALL the privileged
# work for one file, check and write together, in ONE process running
# lib/install-one-file.sh. Every file is checked on its own, and the window is a
# few microseconds inside that process rather than a gap spanning other files'
# copies.
#
# The count IS the subject, so every assertion pairs a count with the outcome it
# must not have altered: a design that "wins" by refusing everything, or by
# writing files nobody vetted, fails the same assertion it would satisfy.
#
# Instrumented with a counting `sudo` shim on PATH rather than by wrapping the
# code under test: the shim measures what the issue measured (setuid execs),
# needs no test-only hook in production code, and cannot drift from one.
#
# No `set -e`: every check reports independently and the script exits with the
# accumulated status.
#
# While the gate applies — it selects files this branch ADDED — tests/oracle-
# baseline.sh runs this file against the merge base (bff6365) and requires every
# assertion to fail there AND the DONE sentinel to print, so an early abort
# cannot score a free pass. Measured 2026-08-23: eight of eight fail there — a
# count the gate prints on every run, so it never needs re-deriving by hand. Once
# this branch merges the gate stops selecting the file and says so by SKIPping;
# that is the end state, not a hole. Written in this tense deliberately —
# tests/install-containment.sh carries a paragraph correcting exactly this
# sentence after it was left in the present tense and went stale.
set -u

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
_root=$(CDPATH='' cd -- "$_here/.." && pwd)
cd "$_root" || exit 1

_fail=0
# shellcheck source=tests/lib-assert.sh
. "$_root/tests/lib-assert.sh"
# shellcheck source=tests/lib-install-driver.sh
. "$_root/tests/lib-install-driver.sh"

# `exec "$@"` after logging: the shim must be transparent, so the install still
# happens for real and the assertions can look at the tree afterwards.
_shim=$(mktemp -d) || exit 1
cat > "$_shim/sudo" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >> "$SUDO_LOG"
# SUDO_DENY names a command word this sudo refuses, the way a sudoers policy
# that permits only mkdir/cp/rm refuses `sh`. Exit 1 is what real sudo returns
# for that, and it is the status the caller has to recognise.
if [ -n "${SUDO_DENY:-}" ] && [ "$1" = "$SUDO_DENY" ]; then
  printf 'Sorry, user %s is not allowed to execute %s\n' "$(id -un)" "$1" >&2
  exit 1
fi
exec "$@"
EOF
chmod +x "$_shim/sudo"

_log=$(mktemp) || exit 1

# Every setuid exec of the last run, whatever the command word: the claim is
# about the TOTAL privileged cost per file, not about one command's share.
_execs() { wc -l < "$_log" | tr -d ' '; }

# Drive _install_file directly rather than through do_install: do_install picks
# the privilege from the prefix's ownership, and a prefix this user cannot write
# is not something a test can create without being root. Passing $_priv in is
# also what lets the last case mix privileges within one run.
#
# $1 = install prefix, $2 = staging dir, then one 'relative/dest|priv' spec per
# file. The spec list is passed as ARGUMENTS, not spliced into the script text:
# ShellCheck parses the script of an `sh -c` only while the command word and the
# script are literals, and a spliced one is reported as SC2016 instead of being
# checked.
_drive() {
  _pfx=$1
  _stagedir=$2
  shift 2
  : > "$_log"
  PATH="$_shim:$PATH" SUDO_LOG="$_log" MF_PREFIX="$_pfx" MF_SRC="$_stagedir" \
  SCRIPT_DIR="${MF_SCRIPT_DIR:-$_root}" SUDO_DENY="${MF_SUDO_DENY:-}" \
  sh -c "$_MF_INSTALL_SOURCES"'
    _install_prefix="$MF_PREFIX"
    # Unprivileged on purpose: the prefix is ours, the answer is identical, and
    # resolving it under the shim would count an exec _install_file never made.
    _install_prefix_real=$(_resolve_existing "$MF_PREFIX") || exit 1
    _mf="$MF_PREFIX/.manifest"
    for _spec in "$@"; do
      # A SWAP:<dir>:<target> spec replaces an already-written directory with a
      # symlink in the middle of the run, which is how the per-file check is
      # exercised from outside. Still data, not script text.
      #
      # MOVED aside, not deleted: deleting takes the files already installed
      # there with it, so nothing downstream could then prove the first file had
      # landed — and preserving them is what an attacker would do anyway, since a
      # vanished bin/ is noticed and a redirected one is not.
      #
      # The DIR half must not contain a colon (it is cut at the first one); the
      # target half may contain any number, since it is whatever follows.
      case "$_spec" in
        SWAP:*)
          _sw=${_spec#SWAP:}
          mv "$MF_PREFIX/${_sw%%:*}" "$MF_PREFIX/${_sw%%:*}.orig"
          ln -s "${_sw#*:}" "$MF_PREFIX/${_sw%%:*}"
          continue
          ;;
      esac
      _rel=${_spec%|*}
      _pv=${_spec##*|}
      _install_file "$MF_SRC/src-${_rel##*/}" "$MF_PREFIX/$_rel" "$_mf" "$_pv"
    done
  ' _ "$@" 2>&1
}

# One payload file per destination basename used below.
_stage() {
  mkdir -p "$1"
  for _n in a b c; do
    printf 'PAYLOAD-%s\n' "$_n" > "$1/src-$_n"
  done
}

# ─── one privileged exec per file, whatever the directory ───────────────────
# Three files into one directory is where the per-directory memo looked best and
# the per-file resolution looked worst; both are beaten by doing each file's
# check and write in a single privileged process.
_s=$(mktemp -d) || exit 1
_d=$(mktemp -d) || exit 1
_stage "$_s"

_out=$(_drive "$_d" "$_s" 'lib/a|sudo' 'lib/b|sudo' 'lib/c|sudo') || true
_n=$(_execs)

if [ "$_n" != 3 ]; then
  _bad one-privileged-exec-per-file \
    "three files cost $_n privileged execs, want 3 (one each): $(printf '%s' "$_out" | tail -1)"
elif [ "$(cat "$_d/lib/a" 2>/dev/null)" != "PAYLOAD-a" ] \
  || [ "$(cat "$_d/lib/b" 2>/dev/null)" != "PAYLOAD-b" ] \
  || [ "$(cat "$_d/lib/c" 2>/dev/null)" != "PAYLOAD-c" ]; then
  _bad one-privileged-exec-per-file \
    "the one-exec-per-file path did not place all three payloads under $_d/lib"
else
  _pass one-privileged-exec-per-file
fi
rm -rf "$_s" "$_d"

# ─── a directory swapped mid-run is caught for the very next file ───────────
# THE point of the redesign, and the assertion that would fail against the
# memoized shape #23 proposed: file a vets lib/ and lands, lib/ is then replaced
# by a symlink out of the prefix, and file b — the same directory, the next file
# — must be refused rather than inheriting a's verdict. No file may reach the
# escape target, and the run must end there, as every containment refusal does.
_s=$(mktemp -d) || exit 1
_d=$(mktemp -d) || exit 1
_esc=$(mktemp -d) || exit 1
_stage "$_s"

_out=$(_drive "$_d" "$_s" 'lib/a|sudo' "SWAP:lib:$_esc" 'lib/b|sudo') || true
_n=$(_execs)

if [ -e "$_esc/b" ]; then
  _bad swapped-directory-refused-next-file \
    "a file was written THROUGH the symlink swapped in mid-run, to $_esc"
elif ! printf '%s' "$_out" | grep -q 'Refusing a privileged write'; then
  _bad swapped-directory-refused-next-file \
    "the swapped directory was not refused: $(printf '%s' "$_out" | tail -2)"
elif [ "$_n" != 2 ]; then
  _bad swapped-directory-refused-next-file \
    "the swap case cost $_n privileged execs, want 2 (one per file)"
elif [ "$(cat "$_d/lib.orig/a" 2>/dev/null)" != "PAYLOAD-a" ]; then
  _bad swapped-directory-refused-next-file \
    "the file installed before the swap never landed — the refusal proves nothing"
else
  _pass swapped-directory-refused-next-file
fi
rm -rf "$_s" "$_d" "$_esc"

# ─── refused BEFORE mkdir, so not even a directory escapes ──────────────────
# The destination is two levels below the symlink, so the refusal has to happen
# before `mkdir -p` runs: mkdir follows the symlinked include/ and would create
# sub/ at the escape target. No file content escapes that way — the resolution
# after mkdir catches the copy either way — but the DIRECTORY does, and nothing
# manifests it, so `uninstall` cannot sweep it. That is the harm #21 named, and
# it is why the check before mkdir is not redundant with the one after it.
_s=$(mktemp -d) || exit 1
_d=$(mktemp -d) || exit 1
_esc=$(mktemp -d) || exit 1
_stage "$_s"
ln -s "$_esc" "$_d/include"

_out=$(_drive "$_d" "$_s" 'lib/a|sudo' 'include/sub/b|sudo') || true
_n=$(_execs)

if [ -e "$_esc/sub" ]; then
  _bad class-dir-refused-before-mkdir \
    "mkdir created $_esc/sub THROUGH the symlinked include/ before anything refused it"
elif [ -e "$_esc/b" ] || [ -e "$_esc/sub/b" ]; then
  _bad class-dir-refused-before-mkdir "a file was written THROUGH the symlinked include/ to $_esc"
elif ! printf '%s' "$_out" | grep -q 'Refusing a privileged write'; then
  _bad class-dir-refused-before-mkdir \
    "the symlinked include/ was not refused: $(printf '%s' "$_out" | tail -2)"
elif [ "$_n" != 2 ]; then
  _bad class-dir-refused-before-mkdir \
    "one landing plus one refusal cost $_n privileged execs, want 2"
elif [ "$(cat "$_d/lib/a" 2>/dev/null)" != "PAYLOAD-a" ]; then
  _bad class-dir-refused-before-mkdir "the refusal also lost the legitimate lib/a under $_d"
else
  _pass class-dir-refused-before-mkdir
fi
rm -rf "$_s" "$_d" "$_esc"

# ─── an unprivileged install spends no privileged execs at all ──────────────
# The same code path serves both, so the privilege has to come from $_priv and
# nowhere else: a user-owned prefix must not reach sudo, and a privileged file
# in the same run must still cost exactly one.
_s=$(mktemp -d) || exit 1
_d=$(mktemp -d) || exit 1
_stage "$_s"

_out=$(_drive "$_d" "$_s" 'lib/a|' 'lib/b|sudo') || true
_n=$(_execs)

if [ "$_n" != 1 ]; then
  _bad unprivileged-file-spends-no-exec \
    "cost $_n privileged execs, want 1: $(printf '%s' "$_out" | tail -1)"
elif [ "$(cat "$_d/lib/a" 2>/dev/null)" != "PAYLOAD-a" ] \
  || [ "$(cat "$_d/lib/b" 2>/dev/null)" != "PAYLOAD-b" ]; then
  _bad unprivileged-file-spends-no-exec \
    "the mixed-privilege run did not place both payloads under $_d/lib"
else
  _pass unprivileged-file-spends-no-exec
fi
rm -rf "$_s" "$_d"

# ─── a helper that cannot do the work must not report that it did ───────────
# An empty or truncated script exits 0 — POSIX says a script with no commands
# succeeds — so "the helper returned 0" is not evidence that anything was
# checked or copied. Without a guard the caller records a manifest entry for a
# file that was never written, and for the CA bundle that is a prefix whose
# trust store silently is not there.
#
# TWO guards cover this, and they are asserted separately because each shadows
# the other: the emptiness check at read time gives the precise diagnosis, and
# the INSTALLED sentinel is the actual guarantee — it also covers a helper that
# is not empty and still does nothing. Each case below matches the message of
# ONE guard, so removing either is a failure here rather than a silent
# fallthrough to the other.
#
# Both use a COPY of lib/ with a damaged helper, so the real one is untouched:
# this file runs in the same checkout as everything else.
_damaged_lib() {
  _dl=$(mktemp -d) || exit 1
  mkdir -p "$_dl/lib"
  cp "$_root"/lib/*.sh "$_dl/lib/"
  printf '%s' "$1" > "$_dl/lib/install-one-file.sh"
  printf '%s\n' "$_dl"
}

_s=$(mktemp -d) || exit 1
_d=$(mktemp -d) || exit 1
_stage "$_s"
_libcopy=$(_damaged_lib '')

_out=$(MF_SCRIPT_DIR="$_libcopy" _drive "$_d" "$_s" 'lib/a|sudo') || true

if [ -f "$_d/lib/a" ]; then
  _bad empty-helper-caught-at-read \
    "an empty helper still placed $_d/lib/a — it cannot have; something else wrote it"
elif [ -f "$_d/.manifest" ] && grep -q 'lib/a' "$_d/.manifest" 2>/dev/null; then
  _bad empty-helper-caught-at-read \
    "an empty helper produced a manifest entry for a file it never wrote"
elif ! printf '%s' "$_out" | grep -q 'is empty'; then
  _bad empty-helper-caught-at-read \
    "an empty helper was not diagnosed at read time: $(printf '%s' "$_out" | tail -2)"
else
  _pass empty-helper-caught-at-read
fi
rm -rf "$_s" "$_d" "$_libcopy"

# Non-empty and does nothing: the read-time check cannot see this one, so only
# the sentinel stands between it and a manifest full of files nobody wrote.
_s=$(mktemp -d) || exit 1
_d=$(mktemp -d) || exit 1
_stage "$_s"
_libcopy=$(_damaged_lib '#!/bin/sh
# truncated before it did any work
')

_out=$(MF_SCRIPT_DIR="$_libcopy" _drive "$_d" "$_s" 'lib/a|sudo') || true

if [ -f "$_d/lib/a" ]; then
  _bad noop-helper-refused-not-believed \
    "a no-op helper still placed $_d/lib/a — it cannot have; something else wrote it"
elif [ -f "$_d/.manifest" ] && grep -q 'lib/a' "$_d/.manifest" 2>/dev/null; then
  _bad noop-helper-refused-not-believed \
    "a no-op helper produced a manifest entry for a file it never wrote"
elif ! printf '%s' "$_out" | grep -q 'INSTALLED sentinel'; then
  _bad noop-helper-refused-not-believed \
    "a helper that exited 0 without working was believed: $(printf '%s' "$_out" | tail -2)"
else
  _pass noop-helper-refused-not-believed
fi
rm -rf "$_s" "$_d" "$_libcopy"

# ─── a helper damaged mid-construct is not reported as a symlink attack ─────
# The sentinel cannot catch this one: a script truncated inside a `case` or
# `while` never runs far enough to print anything, and `sh` exits 2 for the
# syntax error. 2 is therefore a status the helper itself must never use — if
# the containment refusal also returned 2, this damaged file would arrive
# wearing the message that says a symlink is redirecting a privileged write, and
# the operator would go looking for an attack that is not happening.
_s=$(mktemp -d) || exit 1
_d=$(mktemp -d) || exit 1
_stage "$_s"
# No parameter in the payload: it only has to fail to PARSE, and a $1 inside
# these quotes is an SC2016 finding rather than a clearer fixture.
_libcopy=$(_damaged_lib '#!/bin/sh
case x in
  # truncated inside the case, before esac
')

_out=$(MF_SCRIPT_DIR="$_libcopy" _drive "$_d" "$_s" 'lib/a|sudo') || true

if [ -f "$_d/lib/a" ]; then
  _bad damaged-helper-diagnosed-as-damage "a helper that cannot parse still placed $_d/lib/a"
elif printf '%s' "$_out" | grep -q 'Refusing a privileged write'; then
  _bad damaged-helper-diagnosed-as-damage \
    "a damaged helper was reported as a symlink attack — the operator is sent after nothing"
elif ! printf '%s' "$_out" | grep -q 'failed to parse'; then
  _bad damaged-helper-diagnosed-as-damage \
    "a helper that cannot parse was not diagnosed: $(printf '%s' "$_out" | tail -2)"
else
  _pass damaged-helper-diagnosed-as-damage
fi
rm -rf "$_s" "$_d" "$_libcopy"

# ─── a sudoers policy that refuses `sh` says so ─────────────────────────────
# Every privileged install now runs through `sudo sh -c`. A policy permitting
# only mkdir/cp/rm refuses that, and sudo exits 1 — a status the helper never
# returns, so it means the helper never ran. Before this arm existed the
# operator got "internal: ... exited 1" with nothing to act on, while the
# diagnosis that names sudoers sat on exit 3, which this can never reach.
_s=$(mktemp -d) || exit 1
_d=$(mktemp -d) || exit 1
_stage "$_s"

_out=$(MF_SUDO_DENY='sh' _drive "$_d" "$_s" 'lib/a|sudo') || true

if [ -f "$_d/lib/a" ]; then
  _bad refused-sudo-names-policy-and-way-out \
    "the install proceeded even though sudo refused to run the helper"
elif printf '%s' "$_out" | grep -q 'cannot resolve the install destination'; then
  _bad refused-sudo-names-policy-and-way-out \
    "a refused sudo was diagnosed as an unresolvable destination — the wrong fix entirely"
elif ! printf '%s' "$_out" | grep -q 'could not run the install helper'; then
  _bad refused-sudo-names-policy-and-way-out \
    "a refused sudo was not diagnosed: $(printf '%s' "$_out" | tail -3)"
elif ! printf '%s' "$_out" | grep -q 'sudoers'; then
  _bad refused-sudo-names-policy-and-way-out \
    "the refusal was reported without naming the sudoers policy that causes it"
elif ! printf '%s' "$_out" | grep -q 'as root'; then
  _bad refused-sudo-names-policy-and-way-out \
    "the refusal named the cause but not the way out — installing as root needs no per-file sudo"
else
  _pass refused-sudo-names-policy-and-way-out
fi
rm -rf "$_s" "$_d"

rm -rf "$_shim" "$_log"
printf 'DONE: install-privileged-execs\n'
exit "$_fail"
