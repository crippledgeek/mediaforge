#!/bin/sh
# Pins the refusal to build into RAM, and the warning that is deliberately NOT
# a refusal.
#
# The asymmetry is the whole subject. Exhausting a disk fails the build;
# exhausting a tmpfs exhausts memory, the OOM killer starts picking processes,
# and the SIGKILL it sends cannot be trapped -- so the half-written tree stays
# in RAM and the next run starts with less (GH-64). One is recoverable, the
# other takes the machine with it, so one warns and one refuses.
#
# A REAL tmpfs cannot be mounted from a test without privileges, so the
# filesystem is stubbed: df and stat are shims on a sandbox PATH, which is what
# mf_fs_type and mf_free_kb resolve through. That makes the fixture the
# interesting part, and it is why each stub echoes the SHAPE of real output --
# the -PT header line included -- rather than just the field the code reads. A
# stub that answers a question the real tool would not is a test of nothing.
#
# lib/storage.sh is sourced conditionally for the reason tests/ccache.sh gives:
# on the merge base the file does not exist, and an unguarded source under
# `set -e` aborts before the DONE sentinel, which tests/oracle-baseline.sh
# reports as a crashed test rather than as the absent feature.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

# --- the CLI surface --------------------------------------------------------
_wired flag-parsed     mediaforge.sh '--allow-tmpfs)'
# The HELP LINE, not the flag token. `_wired` is a fixed-string grep, so a
# needle of '--allow-tmpfs' matched the case arm the assertion above had already
# found: deleting both printf lines from the help text left all thirteen
# assertions green (mutation-verified). A flag in the parser and in no document
# is the shape tests/debug-levels.sh exists to catch.
_wired flag-documented mediaforge.sh '--allow-tmpfs         Build even when'
_wired guard-called    mediaforge.sh 'mf_storage_guard'
# Position, not merely presence. The guard's whole claim is that it refuses
# BEFORE anything is written, and $PREFIX is created by save_stored_choices; a
# grep for the call cannot tell the two orders apart.
_gline=$(grep -n 'mf_storage_guard' mediaforge.sh | grep -v '^[0-9]*: *#' | head -1 | cut -d: -f1)
_sline=$(grep -n '^  save_stored_choices' mediaforge.sh | head -1 | cut -d: -f1)
if [ -z "$_gline" ] || [ -z "$_sline" ]; then
  _bad guard-precedes-first-write "could not locate both the guard call and save_stored_choices"
elif [ "$_gline" -lt "$_sline" ]; then
  _pass guard-precedes-first-write
else
  _bad guard-precedes-first-write "the guard is called at line $_gline, after save_stored_choices creates \$PREFIX at line $_sline"
fi

if [ ! -f lib/storage.sh ]; then
  for _a in refuses-ram-disk names-the-override allows-ram-disk-when-asked \
            refuses-ramfs warns-below-the-floor silent-at-the-floor \
            warns-one-block-below-the-floor unknown-type-does-not-refuse \
            unreadable-free-space-does-not-refuse refuses-devtmpfs \
            dry-run-is-exempt; do
    _bad "$_a" "lib/storage.sh absent — claim would be vacuous"
  done
printf 'DONE: storage-guard\n'
  exit "$_fail"
fi

# Sourced into THIS shell as well as the sandbox below, because the exemption
# probe at the end needs mf_fs_type to decide whether this host can measure the
# claim at all. Reusing the detection rather than inlining a second copy of it:
# a probe that decides "is this tmpfs" by its own rule can disagree with the
# guard's, and then the assertion is about the probe.
# shellcheck source=lib/storage.sh
. "$ROOT/lib/storage.sh"
# shellcheck source=tests/lib-scratch.sh
. "$ROOT/tests/lib-scratch.sh"

_tmp=$(mktemp -d) || { printf 'FAIL [tmpdir]\n' >&2; exit 1; }
trap 'rm -rf "$_tmp"; _scratch_cleanup' EXIT
# The explicit form because this branch is cut from develop, where
# _cleanup_on_signal does not exist yet -- it arrives with GH-64/PR#65, whose
# static assertion then requires the call. Whichever of the two lands second
# converges this to `_cleanup_on_signal`; the semantic is identical either way.
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$_tmp/bin"

# The floor, read from the source rather than restated here. A second copy of
# the number is a second thing to update, and the boundary assertions below are
# only meaningful if they sit on the SAME value the code uses.
_floor=$(awk -F= '/^MF_MIN_FREE_KB=/ {print $2; exit}' lib/storage.sh)
# No fallback value. A second copy of the number is the duplication the comment
# above declines, and running the boundary assertions against a guessed floor
# would report a boundary the code does not have.
_floor_ok=true
case "$_floor" in
  '' | *[!0-9]*)
    _bad floor-is-readable "MF_MIN_FREE_KB is not a plain number in lib/storage.sh"
    _floor_ok=false
    ;;
esac

# df and stat, stubbed. TYPE and FREE come from the environment so one pair of
# shims serves every case; TYPE="" makes df -T fail the way a df without -T
# does, which is the macOS shape.
cat > "$_tmp/bin/df" <<'DF'
#!/bin/sh
_want_type=no
_want_k=no
for _a in "$@"; do
  case "$_a" in
    -*T*) _want_type=yes ;;
  esac
  case "$_a" in
    -*k*) _want_k=yes ;;
  esac
done
# An UNSET FREE means "df could not say", and the shim has to answer that the
# way df does -- by failing -- rather than by printing a default. It printed
# ${FREE:-0} at first, so the unreadable-free-space assertion was silently
# exercising "zero bytes free", which is a perfectly readable number: the
# assertion passed against a mutant that turned unmeasurable into a refusal.
[ -n "${FREE:-}" ] || exit 1
# A size query without -k is answered the way a POSIX df answers it: in 512-byte
# blocks, i.e. twice the number. The caller asked for 1K blocks and must say so,
# or the shim is agreeing to a question the real tool would have answered
# differently -- which is exactly how the FREE default above went unnoticed.
if [ "$_want_type" = no ] && [ "$_want_k" = no ]; then
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
  printf 'stub 100 100 %s 50%% /stub\n' "$((FREE * 2))"
  exit 0
fi
if [ "$_want_type" = yes ]; then
  [ -n "${TYPE:-}" ] || exit 1
  printf 'Filesystem     Type 1024-blocks Used Available Capacity Mounted on\n'
  printf 'stub %s 100 100 %s 50%% /stub\n' "$TYPE" "$FREE"
else
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
  printf 'stub 100 100 %s 50%% /stub\n' "$FREE"
fi
DF
cat > "$_tmp/bin/stat" <<'STAT'
#!/bin/sh
[ -n "${STAT_TYPE:-}" ] || exit 1
printf '%s\n' "$STAT_TYPE"
STAT
chmod +x "$_tmp/bin/df" "$_tmp/bin/stat"

# One case, one recording: the guard's exit status and everything it said.
# Written as a helper because eight assertions below differ only in the stubbed
# filesystem and the flag, and because what has to be read back is not a return
# value alone -- a refusal that does not say what to do about it is half a
# refusal, so the message is evidence too.
_guard() { # tag  allow_ram(true|false)
  set +e
  (
    PATH="$_tmp/bin:$PATH"; export PATH
    # shellcheck source=lib/utils.sh
    . "$ROOT/lib/utils.sh"
    # shellcheck source=lib/storage.sh
    . "$ROOT/lib/storage.sh"
    command -v mf_storage_guard >/dev/null 2>&1 || { echo "no mf_storage_guard"; exit 127; }
    mf_storage_guard /stub "$2"
  ) > "$_tmp/log-$1" 2>&1
  _g_rc=$?
  set -e
}

_said() { # tag
  tr '\n' ' ' < "$_tmp/log-$1"
}

# --- the RAM case: refuse ---------------------------------------------------
TYPE=tmpfs FREE=$_floor _guard tmpfs false
if [ "$_g_rc" -eq 0 ]; then
  _bad refuses-ram-disk "built into tmpfs without complaint"
else
  _pass refuses-ram-disk
fi
# Refusing is not enough on its own: an operator who is right about their tmpfs
# needs to be told how to proceed, or the guard is something to work around
# rather than answer.
case "$(_said tmpfs)" in
  *--allow-tmpfs*) _pass names-the-override ;;
  *) _bad names-the-override "refused without naming the override: $(_said tmpfs)" ;;
esac

# Free space is not the question here. A tmpfs with room to spare is still RAM,
# so this must refuse on a filesystem that passes the floor -- which is what
# FREE=$_floor above sets up, and this assertion is what says the type is doing
# the work rather than the size.
TYPE=ramfs FREE=$((_floor * 4)) _guard ramfs false
if [ "$_g_rc" -eq 0 ]; then
  _bad refuses-ramfs "a ramfs four times the floor was accepted — the refusal is keyed on size, not on RAM"
else
  _pass refuses-ramfs
fi

# devtmpfs completes the list the guard matches on. Named individually rather
# than trusted to the pattern: the three are one `case` arm today, and a future
# edit that splits or narrows it should have to break an assertion per type.
TYPE=devtmpfs FREE=$_floor _guard devtmpfs false
if [ "$_g_rc" -eq 0 ]; then
  _bad refuses-devtmpfs "built into devtmpfs without complaint"
else
  _pass refuses-devtmpfs
fi

TYPE=tmpfs FREE=$_floor _guard allowed true
if [ "$_g_rc" -eq 0 ]; then
  _pass allows-ram-disk-when-asked
else
  _bad allows-ram-disk-when-asked "--allow-tmpfs did not get past the refusal: $(_said allowed)"
fi

# --- the tight-disk case: warn, never refuse --------------------------------
# The boundary, both sides, on the same value the code reads. A >= that should
# have been > moves exactly one block, and only this pair can see it.
if [ "$_floor_ok" = false ]; then
  _bad silent-at-the-floor "the floor could not be read, so the boundary was not measured"
  _bad warns-one-block-below-the-floor "the floor could not be read, so the boundary was not measured"
else
TYPE=ext4 FREE=$_floor _guard at-floor false
if [ "$_g_rc" -ne 0 ]; then
  _bad silent-at-the-floor "refused at exactly the floor: $(_said at-floor)"
elif [ -n "$(_said at-floor)" ]; then
  _bad silent-at-the-floor "warned at exactly the floor, which is enough space: $(_said at-floor)"
else
  _pass silent-at-the-floor
fi

TYPE=ext4 FREE=$((_floor - 1)) _guard below false
if [ "$_g_rc" -ne 0 ]; then
  _bad warns-one-block-below-the-floor "refused rather than warned — a small build legitimately fits: $(_said below)"
elif [ -z "$(_said below)" ]; then
  _bad warns-one-block-below-the-floor "one block below the floor and it said nothing"
else
  _pass warns-one-block-below-the-floor
fi
fi

# Far below, not just off by one: the message has to carry the numbers an
# operator would act on, and a boundary case cannot show that.
TYPE=ext4 FREE=1048576 _guard tight false
case "$(_said tight)" in
  *WARNING*free*) _pass warns-below-the-floor ;;
  *) _bad warns-below-the-floor "said nothing useful about space: $(_said tight)" ;;
esac

# --- what the guard must NOT do ---------------------------------------------
# macOS: df has no -T and stat -f means something else, so the type is unknown.
# Unknown is not evidence of RAM, and a guard that refuses whenever it cannot
# measure is a guard that gets switched off.
TYPE='' STAT_TYPE='' FREE=$_floor _guard unknown false
if [ "$_g_rc" -eq 0 ]; then
  _pass unknown-type-does-not-refuse
else
  _bad unknown-type-does-not-refuse "refused a filesystem it could not identify: $(_said unknown)"
fi

# df present but saying nothing parseable -- a container with a stubbed df, a
# filesystem it does not know. Same rule.
TYPE='' STAT_TYPE='' FREE='' _guard nofree false
if [ "$_g_rc" -eq 0 ]; then
  _pass unreadable-free-space-does-not-refuse
else
  _bad unreadable-free-space-does-not-refuse "refused when df gave no number: $(_said nofree)"
fi

# --- the exemption, end to end ----------------------------------------------
# A dry run writes nothing, so guarding it would refuse an operation that cannot
# cause the problem. That is not a corner: tests/lib-scratch.sh gives every
# parser test a mktemp -d TOPDIR, and mktemp answers under /tmp, so a guard
# without this exemption fails the suite rather than the machine -- which is how
# the exemption was found.
#
# Run against the REAL mediaforge rather than the stubbed filesystem: the claim
# is about the wiring in cmd_build, which the shims above cannot see. Asserted
# only where mktemp actually lands on a RAM-backed filesystem -- on a host whose
# /tmp is disk, the run proves nothing and the assertion is not emitted.
# tests/lib-scratch.sh already owns "a scratch TOPDIR to run mediaforge from",
# which is exactly what this needs -- and its directory is covered by a cleanup
# rather than by nothing, which the hand-rolled mktemp here was not.
_scratch_init "$ROOT"
case "$(mf_fs_type "$_MF_SCRATCH")" in
  tmpfs | ramfs | devtmpfs)
    _dry=$( _mf build --dry-run --yes 2>&1 ); _dry_rc=$?
    # The STATUS as well as the text. "did not say RAM-backed" is satisfied by a
    # dry run that died of something else entirely before ever reaching the
    # guard -- mutation-verified: a die() planted at the top of cmd_build left
    # this assertion green. A dry run that cannot complete measures nothing.
    case "$_dry_rc:$_dry" in
      0:*RAM-backed*) _bad dry-run-is-exempt "a dry run was refused, and it writes nothing" ;;
      0:*) _pass dry-run-is-exempt ;;
      *) _bad dry-run-is-exempt "the dry run exited $_dry_rc, so the exemption was never exercised: $(printf '%s' "$_dry" | tr '\n' ' ')" ;;
    esac
    ;;
  *)
    printf 'NOTE: mktemp -d is not on a RAM-backed filesystem here — the dry-run exemption was not measured\n'
    ;;
esac

printf 'DONE: storage-guard\n'
exit "$_fail"
