#!/bin/sh
# Install-path containment — regression tests for crippledgeek/mediaforge#21.
#
# _install_file places six classes of file (binaries, static libs, pkgconfig,
# headers, man pages, the CA bundle) and composes every destination lexically
# from $_install_prefix. A lexical composition says nothing about where the path
# leads, so a symlink planted at a class root — while the prefix was still
# writable, no race needed — redirects a copy that runs under sudo for a system
# prefix. Until #21 the containment check that refuses this lived only on the
# CA-bundle path.
#
# Every assertion below is expected to FAIL against the merge base, and
# tests/oracle-baseline.sh enforces that: it runs this file against a pristine
# base export and fails if any assertion passes there, if none fails there, or
# if the DONE sentinel at the bottom never printed. That constraint is why the
# happy path is not asserted on its own here — "a plain install still places
# files" passes on the base too, so it is folded into the first assertion, which
# requires a legitimate binary to have landed AND the symlinked class to have
# been refused.
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
_pass() { printf 'PASS: %s\n' "$1"; }
_bad()  { printf 'FAIL: %s\n' "$1"; _fail=1; }

# Drive do_install in a separate `sh` rather than a ( ) subshell: it reads
# PREFIX/AUTOINSTALL from the environment, and shadowing this script's own
# PREFIX inside a subshell would both confuse the reader and leak install.sh's
# functions into the assertions that follow.
_run_install() {
  PREFIX="$1" INSTALL_MANPAGES=0 AUTOINSTALL=yes SCRIPT_DIR="$_root" VERBOSE=0 \
  sh -c '
    . "$SCRIPT_DIR/lib/utils.sh"
    . "$SCRIPT_DIR/lib/resolve.sh"
    . "$SCRIPT_DIR/lib/install.sh"
    do_install "$1"
  ' _ "$2" 2>&1
}

# A staging prefix holding one file of each class this file exercises.
_make_stage() {
  mkdir -p "$1/bin" "$1/lib" "$1/include" "$1/.logs"
  printf 'FFMPEG-BINARY\n' > "$1/bin/ffmpeg"
  printf 'STATIC-LIB\n'    > "$1/lib/libmediaforge-probe.a"
  printf 'HEADER\n'        > "$1/include/mediaforge-probe.h"
}

# ─── a symlinked lib/ must not redirect the static-library copy ─────────────
# Static libs, not the CA bundle: the guard has to be a property of
# _install_file, and asserting it on the one class that already had its own copy
# of the check would pass on the base.
_s=$(mktemp -d) || exit 1
_d=$(mktemp -d) || exit 1
_out=$(mktemp -d) || exit 1
_make_stage "$_s"
ln -s "$_out" "$_d/lib"

_log=$(_run_install "$_s" "$_d") || true

# Three halves, and the third is the positive one: an install that refuses
# EVERYTHING would satisfy the first two, so the binary — a legitimate
# destination reached before the symlinked class — must still have been placed.
if [ -f "$_out/libmediaforge-probe.a" ]; then
  _bad "a static lib was written THROUGH the symlink at lib/ to $_out"
elif ! printf '%s' "$_log" | grep -q 'Refusing a privileged write'; then
  _bad "the symlinked lib/ was not refused — unclear outcome: $(printf '%s' "$_log" | tail -2)"
elif [ ! -f "$_d/bin/ffmpeg" ] || [ "$(cat "$_d/bin/ffmpeg" 2>/dev/null)" != "FFMPEG-BINARY" ]; then
  _bad "the guard also blocked a legitimate destination — bin/ffmpeg is missing from $_d"
else
  _pass "a symlinked lib/ is refused while legitimate destinations still install"
fi
rm -rf "$_s" "$_d" "$_out"

# ─── a symlinked include/ must not redirect headers, and must END the run ───
# Headers are installed from a `find` list. That list used to be piped into the
# `while` loop, which puts the body in a subshell where `die` exits only the
# subshell: the refusal fired, the loop ended, and do_install carried on to
# finalize a manifest and report success. So the absence of the manifest is the
# oracle for "the refusal ended the run", not merely "the copy was blocked".
_s=$(mktemp -d) || exit 1
_d=$(mktemp -d) || exit 1
_out=$(mktemp -d) || exit 1
_make_stage "$_s"
# bin/ and lib/ install normally; only the header class escapes.
mkdir -p "$_d/bin" "$_d/lib"
ln -s "$_out" "$_d/include"

_log=$(_run_install "$_s" "$_d") || true

if [ -f "$_out/mediaforge-probe.h" ]; then
  _bad "a header was written THROUGH the symlink at include/ to $_out"
elif ! printf '%s' "$_log" | grep -q 'Refusing a privileged write'; then
  _bad "the symlinked include/ was not refused — unclear: $(printf '%s' "$_log" | tail -2)"
elif [ -f "$_d/.mediaforge-manifest" ]; then
  _bad "the header refusal did not end the run — a manifest was finalized and install reported success"
else
  _pass "a symlinked include/ is refused and the refusal ends the install"
fi
rm -rf "$_s" "$_d" "$_out"

# ─── a symlink at the manifest path must not redirect the manifest write ────
# The manifest is finalized by its own `cp`, outside _install_file, so it never
# had the unlink that function does. It is also the one destination an attacker
# can name without knowing anything about the build: <prefix>/.mediaforge-manifest
# is a constant.
_s=$(mktemp -d) || exit 1
_d=$(mktemp -d) || exit 1
_sentinel=$(mktemp) || exit 1
printf 'SENTINEL-MUST-SURVIVE\n' > "$_sentinel"
_make_stage "$_s"
ln -s "$_sentinel" "$_d/.mediaforge-manifest"

_run_install "$_s" "$_d" >/dev/null 2>&1 || true

# Both halves: an untouched sentinel is trivially true of an install that wrote
# nothing at all, so the manifest must also have been written as a real file.
if [ "$(cat "$_sentinel" 2>/dev/null)" != "SENTINEL-MUST-SURVIVE" ]; then
  _bad "the manifest was written THROUGH the symlink — sentinel now: $(cat "$_sentinel" 2>/dev/null)"
elif [ -L "$_d/.mediaforge-manifest" ]; then
  _bad "the manifest path is still a symlink — nothing was written, so the sentinel surviving proves nothing"
elif ! grep -q '^bin/ffmpeg$' "$_d/.mediaforge-manifest" 2>/dev/null; then
  _bad "no real manifest at $_d/.mediaforge-manifest listing the installed files"
else
  _pass "a symlinked manifest path is replaced, not followed"
fi
rm -rf "$_s" "$_d" "$_sentinel"

# ─── a manifest write that fails must abort, not report success ─────────────
# Every file is already installed by the time the manifest is written, so losing
# it silently leaves a tree that `uninstall` cannot touch while install prints
# the count it would have removed.
#
# Provoked with a non-empty, non-writable DIRECTORY at the manifest path: `cp`
# into a directory succeeds, so an empty one would not fail the copy, and a
# read-only one refuses the write inside it. Skipped as root, for whom 0500 is
# not a restriction.
if [ "$(id -u)" = "0" ]; then
  printf 'SKIP: manifest-failure assertion (running as root; 0500 does not stop the copy)\n'
else
  _s=$(mktemp -d) || exit 1
  _d=$(mktemp -d) || exit 1
  _make_stage "$_s"
  mkdir -p "$_d/.mediaforge-manifest/occupied"
  chmod 500 "$_d/.mediaforge-manifest"

  _log=$(_run_install "$_s" "$_d") || true
  chmod 700 "$_d/.mediaforge-manifest" 2>/dev/null

  # Newlines flattened before the second match: on a tree without the fix,
  # `wc -l < <a directory>` prints its own error between the count and the word
  # "files", so 'Installed .* files' spans two lines and the branch that names
  # the real failure mode would be skipped for the vaguer one below it.
  if printf '%s' "$_log" | grep -q 'failed to write the manifest'; then
    _pass "a manifest write that fails aborts with the files it could not record"
  elif printf '%s' "$_log" | tr '\n' ' ' | grep -q 'Installed .* files'; then
    _bad "a failed manifest write was reported as a successful install"
  else
    _bad "a failed manifest write neither aborted nor reported — unclear: $(printf '%s' "$_log" | tail -2)"
  fi
  rm -rf "$_s" "$_d"
fi

# ─── one ancestor walk, and it still answers for a prefix we cannot enter ───
# Two claims in one assertion, because either alone is satisfiable by the wrong
# code:
#
#  * STRUCTURAL, and labelled as one — _needs_priv used to carry its own copy of
#    the walk, answering on the LEXICAL ancestor while the containment check
#    resolved the physical one. No input distinguishes those behaviourally
#    (`test -w` follows symlinks, and '..' is rejected upstream), so "the second
#    copy is gone" is the only thing left to assert about the dedup itself.
#  * BEHAVIOURAL, and it is the regression guard for the dedup: _resolve_existing
#    answers with `cd`, which fails for an ancestor this user cannot enter.
#    _needs_priv is the one caller that cannot pass a privilege — it is what
#    decides the privilege — so an empty answer there must mean "needs
#    privilege", not "abort". Delegating without that fallthrough turns every
#    install into a root-owned 0700 prefix into a fatal error.
#
# The structural half is scoped to _needs_priv's BODY rather than matched
# line-for-line: an exact-line grep turns a reformat (adding quotes around the
# substitution) into a loud false failure.
if awk '/^_needs_priv\(\)/,/^}/' lib/install.sh | grep -q '_resolve_existing'; then
  _np_probe=$(mktemp -d) || exit 1
  mkdir -p "$_np_probe/locked"
  chmod 000 "$_np_probe/locked"
  _np_answer=$(
    SCRIPT_DIR="$_root" sh -c '
      . "$SCRIPT_DIR/lib/utils.sh"
      . "$SCRIPT_DIR/lib/resolve.sh"
      . "$SCRIPT_DIR/lib/install.sh"
      if _needs_priv "$1"; then echo NEEDS-PRIV; else echo NO-PRIV; fi
    ' _ "$_np_probe/locked/pfx" 2>&1
  ) || true
  chmod 700 "$_np_probe/locked"
  rm -rf "$_np_probe"

  # Skipped where the fixture cannot bite: root ignores 0000, and without sudo
  # _needs_priv legitimately dies instead of answering.
  if [ "$(id -u)" = "0" ] || ! command -v sudo >/dev/null 2>&1; then
    printf 'SKIP: unenterable-ancestor probe (root, or no sudo — the fixture cannot bite)\n'
    _pass "_needs_priv and the containment guard share one ancestor walk"
  elif [ "$_np_answer" = "NEEDS-PRIV" ]; then
    _pass "one shared ancestor walk, and an unenterable prefix still escalates"
  else
    _bad "_needs_priv delegates but no longer answers for an unenterable ancestor: '$_np_answer'"
  fi
elif awk '/^_needs_priv\(\)/,/^}/' lib/install.sh | grep -q 'while \[ ! -d'; then
  _bad "_needs_priv still carries its own ancestor walk instead of calling _resolve_existing"
else
  _bad "_needs_priv neither walks nor resolves — the privilege decision has no ancestor at all"
fi

# Completion sentinel, read by tests/oracle-baseline.sh: it proves this file ran
# to the END on the baseline tree, which is what distinguishes "asserted and
# failed" from "aborted before asserting".
printf 'DONE: install containment\n'
exit "$_fail"
