#!/bin/sh
# Pins that an INTERRUPTED test run leaves nothing behind.
#
# WHICH SHELL decides whether that is true, and the answer was measured rather
# than assumed (2026-08-29, this host):
#
#     dash   SIGTERM -> temporary directory SURVIVED, EXIT trap did not run
#     bash   SIGTERM -> temporary directory gone, EXIT trap RAN
#     /bin/sh here is bash, so the leak is invisible on this machine
#
# So cleanup registered on EXIT alone is cleanup that happens only when nothing
# goes wrong AND the interpreter is generous. Eight files were written that way,
# and mediaforge is POSIX sh precisely so it runs where /bin/sh is dash --
# Debian and Ubuntu, where the leak is real.
#
# What this does NOT claim: that paired traps would have prevented the tmpfs
# exhaustion in GH-64. A 5.9GB tree was found in /tmp on a box with 7.8GB of
# tmpfs and the machine went down, but under memory pressure the process that
# dies is SIGKILLed, and no trap in any shell survives that. This pins a
# portability defect, not that incident.
#
# The completed run was never the problem and is not what this measures -- a
# full suite peaks at 464KB of TMPDIR and leaves nothing.
#
# TWO ASSERTIONS, because either alone rots:
#
#   * the behavioural one signals a real test and looks at what survives, which
#     is the only way to know the traps do what the grep thinks they do;
#   * the static one is what catches the NINTH file, written next year by
#     someone who copied the EXIT-only line from one of the eight. A behavioural
#     check cannot see a file it does not run.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

# --- static: every EXIT cleanup is paired with a signal handler --------------
# ONE spelling, now that there is one. This began tolerant -- any of three forms
# counted, since all three end with the temporary directory gone -- and the
# combined form turned out not to end the RUN, which is a second property and the
# one a person pressing Ctrl-C is asking for. Measured, both shells:
#
#     trap '...' EXIT INT TERM, SIGINT -> cleaned up and KEPT RUNNING (dash, bash)
#
# So a file using it deletes its own fixtures and carries on against them. All 23
# now call the helper, which exits; asserting the exact call is therefore both
# possible and stronger than asserting the property loosely.
#
# Only files that REGISTER an EXIT trap are examined: a test with no temporary
# state has nothing to clean up and is not an offender for saying so.
_unpaired=""
_examined=0
for _f in tests/*.sh .githooks/*; do
  [ -f "$_f" ] || continue
  grep -qE '^[[:space:]]*trap .*[[:space:]]EXIT' "$_f" || continue
  _examined=$((_examined + 1))
  # The helper as a CALL, anchored. An earlier, looser pattern matched `INT` and
  # `TERM` as bare substrings anywhere on a trap line -- so a handler removing
  # "$_PRINT_TMP" reported itself paired on the letters inside a variable name --
  # and matched the helper unanchored, so a COMMENT naming it was enough. Both
  # were demonstrated against synthetic files. It matters more here than in most
  # greps: this assertion's whole job is to catch a file nobody has written yet,
  # which the behavioural half structurally cannot see.
  grep -qE "^[[:space:]]*_cleanup_on_signal([[:space:]]|\$)" "$_f" ||
    _unpaired="$_unpaired ${_f##*/}"
done
# The floor. Every clause above is "grep found nothing", which an empty tests/
# satisfies having checked nothing -- the vacuity tests/meson-single-entry.sh
# guards the same way. Twenty-odd files register one today; ten is a floor that
# a real deletion would have to cross before this stops meaning anything.
if [ "$_examined" -lt 10 ]; then
  _bad exit-cleanup-is-paired-with-signals "only $_examined files register an EXIT trap — too few to be measuring anything"
elif [ -n "$_unpaired" ]; then
  _bad exit-cleanup-is-paired-with-signals "cleanup runs only when nothing goes wrong in:$_unpaired"
else
  _pass exit-cleanup-is-paired-with-signals
fi

# The combined form, forbidden rather than merely not-preferred. `trap '...' EXIT
# INT TERM` looks like it covers the signals and does clean up, but POSIX resumes
# execution after a signal handler rather than exiting -- measured on this host
# under both dash and bash: a subject sent SIGINT ran on for the rest of its loop
# with its temporary directory already deleted. Twelve files here used it, so
# Ctrl-C on the suite removed their fixtures and kept going against them.
#
# Separate from the assertion above rather than folded into it, because they fail
# for different reasons and a reader of the failure should not have to guess
# which: one says cleanup is unguarded, this one says the run does not stop.
_combined=$(grep -lE "^[[:space:]]*trap .*[[:space:]]EXIT[[:space:]]+(INT|TERM)" tests/*.sh 2>/dev/null || true)
if [ -n "$_combined" ]; then
  _bad signal-ends-the-run "cleans up but keeps running, so Ctrl-C leaves the run going without its fixtures:$(printf '%s' "$_combined" | tr '\n' ' ')"
else
  _pass signal-ends-the-run
fi

# How many entries a directory holds. find rather than ls, because ls's output
# is not parseable for names carrying newlines (SC2012) -- and a temporary tree
# is exactly where an odd name can appear.
_entries() { # dir
  find "$1" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l
}

# --- behavioural: signal a real test, look at what survives ------------------
# tests/workspace-independence.sh is the subject because it is the sharp case.
# Others point DISTDIR at a temporary tree too (tests/fetch-fail-no-cache.sh,
# tests/checksum-verification.sh), but they put a fixture there and know its
# size; this one's farms grow a DISTDIR only when a coupled test runs mediaforge
# inside them, which is the unbounded case it exists to catch -- so it is the
# one whose leak is measured in gigabytes rather than kilobytes.
# Run under dash, not $SHELL or /bin/sh: bash cleans up on SIGTERM by itself
# (measured above), so on a host whose /bin/sh is bash this assertion would pass
# against the unfixed tree -- it did, on the first draft, which is how the shell
# difference was found. dash is where the claim has teeth.
#
# When dash is absent the assertion is NOT emitted at all. A pass would be a
# free one, and a failure would blame the host for a defect it cannot exhibit;
# the static assertion above carries the file on such a machine, and
# tests/oracle-baseline.sh counts assertions rather than expecting a fixed set.
_tmp=$(mktemp -d) || { printf 'FAIL [tmpdir]\n' >&2; exit 1; }
trap 'rm -rf "$_tmp"' EXIT
_cleanup_on_signal

# Its own TMPDIR, so what the subject creates is separable from everything else
# on the host. mktemp(1) reads TMPDIR, which is how the subject's temporary
# trees are made to land somewhere countable.
_sub="$_tmp/subject-tmp"
if ! command -v dash >/dev/null 2>&1; then
  printf 'NOTE: no dash on this host — the interrupted-run assertion was not measured\n'
  printf 'DONE: signal-cleanup\n'
  exit "$_fail"
fi
mkdir -p "$_sub"
TMPDIR="$_sub" dash tests/workspace-independence.sh >"$_tmp/out" 2>&1 &
_pid=$!

# Wait for the subject to have CREATED something before signalling it: a kill
# that lands before mktemp -d runs proves nothing, and would pass against the
# unfixed tree for the wrong reason. Bounded, so a subject that never creates
# anything fails the wait rather than hanging the suite. `kill -0` on the pid we
# hold, never a pgrep -f -- a pattern matching this shell's own command line
# would match the waiter itself.
_waited=0
while [ "$(_entries "$_sub")" -eq 0 ]; do
  kill -0 "$_pid" 2>/dev/null || break
  _waited=$((_waited + 1))
  [ "$_waited" -gt 200 ] && break
  sleep 0.05
done

if [ "$(_entries "$_sub")" -eq 0 ]; then
  # Not a pass. The subject finished, or never created a temporary tree, so the
  # kill below would be signalling nothing and the emptiness afterwards would be
  # the emptiness of a test that never ran.
  _bad interrupted-run-leaves-nothing "the subject created no temporary tree to interrupt"
  kill "$_pid" 2>/dev/null || true
  wait "$_pid" 2>/dev/null || true
else
  kill -TERM "$_pid" 2>/dev/null || true
  # The EXIT STATUS is the discriminator, and it is free. An empty directory on
  # its own does not say the signal did anything: a subject that catches TERM
  # and RESUMES -- which is what `trap ... EXIT INT TERM` does, per POSIX, in
  # twelve other files here -- runs to completion and cleans up through its own
  # EXIT trap, and so does one that simply finished before the kill landed. Both
  # exit 0 and both leave nothing, which is indistinguishable from the fix. 143
  # is 128+SIGTERM: the subject was ended BY the signal.
  _status=0; wait "$_pid" || _status=$?
  # A signalled shell does not stop instantly: the handler has to run, and the
  # rm -rf inside it takes as long as the tree is large. Poll for the directory
  # to empty rather than reading it once, so the assertion measures whether
  # cleanup HAPPENS rather than how fast this host is.
  _drain=0
  while [ "$(_entries "$_sub")" -ne 0 ]; do
    _drain=$((_drain + 1))
    [ "$_drain" -gt 100 ] && break
    sleep 0.05
  done
  _left=$(find "$_sub" -mindepth 1 -maxdepth 1 2>/dev/null | tr '\n' ' ')
  if [ "$_status" -ne 143 ]; then
    _bad interrupted-run-leaves-nothing "the subject exited $_status rather than by the signal — nothing was measured"
  elif [ -z "$_left" ]; then
    _pass interrupted-run-leaves-nothing
  else
    _bad interrupted-run-leaves-nothing "a SIGTERM left behind:$_left"
  fi
fi

printf 'DONE: signal-cleanup\n'
exit "$_fail"
