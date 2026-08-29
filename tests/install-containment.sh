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
# Measured 2026-08-23 against pristine exports, with this file as it stands:
# against the PRE-#21 base it was added on (5b3913f) five of its seven
# assertions fail and two pass; against today's develop all seven pass.
#
# The two that pass on 5b3913f are the last pair — a symlinked leaf, and a
# failed copy. Those guards are OLDER than that base: they arrived with #22, so
# they were never what this file was written to catch. They live here because
# they are properties of every installed file and their only other assertion is
# phrased about the CA bundle; see the note above them.
#
# tests/oracle-baseline.sh no longer selects this file at all: it measures ADDED
# files and this one is modified. Were it still selected, those two passing
# assertions would fail the gate — which is the gate working, not a defect in
# them.
#
# Nothing mechanical checks this paragraph; it is only as honest as its last
# reader. It has carried a false sentence in several consecutive revisions, each
# time because someone edited around a claim instead of re-measuring it. Re-run
# the two exports before touching a word of it.
#
# While the gate did apply, it ran this file against a pristine base export and
# failed if any assertion passed there, if none failed there, or if the DONE
# sentinel at the bottom never printed. That constraint is why the happy path is
# not asserted on its own here — "a plain install still places files" passed on
# that base too, so it is folded into the first assertion, which requires a
# legitimate binary to have landed AND the symlinked class to have been refused.
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

# Named for what this file asks of it. The mechanism -- a separate `sh` with
# the install layer sourced -- lives in tests/lib-install-driver.sh.
_run_install() {
  _install_sh "$1" do_install "$2"
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
  _bad symlinked-lib-refused-others-install \
    "a static lib was written THROUGH the symlink at lib/ to $_out"
elif ! printf '%s' "$_log" | grep -q 'Refusing a privileged write'; then
  _bad symlinked-lib-refused-others-install \
    "the symlinked lib/ was not refused: $(printf '%s' "$_log" | tail -2)"
elif [ ! -f "$_d/bin/ffmpeg" ] || [ "$(cat "$_d/bin/ffmpeg" 2>/dev/null)" != "FFMPEG-BINARY" ]; then
  _bad symlinked-lib-refused-others-install \
    "the guard also blocked a legitimate destination — no bin/ffmpeg in $_d"
else
  _pass symlinked-lib-refused-others-install
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
  _bad symlinked-include-refusal-ends-install \
    "a header was written THROUGH the symlink at include/ to $_out"
elif ! printf '%s' "$_log" | grep -q 'Refusing a privileged write'; then
  _bad symlinked-include-refusal-ends-install \
    "the symlinked include/ was not refused: $(printf '%s' "$_log" | tail -2)"
elif [ -f "$_d/.mediaforge-manifest" ]; then
  _bad symlinked-include-refusal-ends-install \
    "the refusal did not end the run — a manifest was finalized and success reported"
else
  _pass symlinked-include-refusal-ends-install
fi
rm -rf "$_s" "$_d" "$_out"

# ─── a symlink at the manifest path must not redirect the manifest write ────
# The manifest is the one destination an attacker can name without knowing
# anything about the build: <prefix>/.mediaforge-manifest is a constant.
#
# It is finalized through _place_file — the same unlink-then-copy path every
# installed file gets — so what this pins is that the guard applies to the
# manifest too, not that the manifest needs one of its own. It used to need one:
# the finalize ran its own `rm -f` + `cp` with a comment saying the guards "have
# to be repeated here", and this paragraph used to say so. Routing it through
# the shared path is what made the special case go away, and the assertions
# below are unchanged by that — they were always about the outcome.
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
  _bad symlinked-manifest-path-replaced \
    "written THROUGH the symlink — sentinel now: $(cat "$_sentinel" 2>/dev/null)"
elif [ -L "$_d/.mediaforge-manifest" ]; then
  _bad symlinked-manifest-path-replaced \
    "the path is still a symlink — nothing was written, so the sentinel proves nothing"
elif ! grep -q '^bin/ffmpeg$' "$_d/.mediaforge-manifest" 2>/dev/null; then
  _bad symlinked-manifest-path-replaced \
    "no real manifest at $_d/.mediaforge-manifest listing the installed files"
else
  _pass symlinked-manifest-path-replaced
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
    _pass failed-manifest-write-aborts
  elif printf '%s' "$_log" | tr '\n' ' ' | grep -q 'Installed .* files'; then
    _bad failed-manifest-write-aborts "a failed manifest write was reported as a successful install"
  else
    _bad failed-manifest-write-aborts \
      "neither aborted nor reported: $(printf '%s' "$_log" | tail -2)"
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
  # Not _install_sh: this probes one function rather than running an entry
  # point, and it deliberately leaves PREFIX unset -- the question is about an
  # ancestor of the DESTINATION, and a build prefix in the environment is one
  # more thing that could be answering.
  _np_answer=$(
    SCRIPT_DIR="$_root" \
    sh -c "$_MF_INSTALL_SOURCES
      if _needs_priv \"\$1\"; then echo NEEDS-PRIV; else echo NO-PRIV; fi
    " _ "$_np_probe/locked/pfx" 2>&1
  ) || true
  chmod 700 "$_np_probe/locked"
  rm -rf "$_np_probe"

  # Skipped where the fixture cannot bite: root ignores 0000, and without sudo
  # _needs_priv legitimately dies instead of answering.
  if [ "$(id -u)" = "0" ] || ! command -v sudo >/dev/null 2>&1; then
    # SKIP alone — see the note on the copy-failure skip below for why no _pass
    # accompanies it. This one predates that note and had the same defect.
    printf 'SKIP: unenterable-ancestor probe (root, or no sudo — the fixture cannot bite)\n'
  elif [ "$_np_answer" = "NEEDS-PRIV" ]; then
    _pass shared-ancestor-walk-escalates-on-unenterable
  else
    _bad shared-ancestor-walk-escalates-on-unenterable \
      "_needs_priv delegates but no longer answers for an unenterable ancestor: '$_np_answer'"
  fi
elif awk '/^_needs_priv\(\)/,/^}/' lib/install.sh | grep -q 'while \[ ! -d'; then
  _bad shared-ancestor-walk-escalates-on-unenterable \
    "_needs_priv still carries its own ancestor walk instead of calling _resolve_existing"
else
  _bad shared-ancestor-walk-escalates-on-unenterable \
    "_needs_priv neither walks nor resolves — the privilege decision has no ancestor"
fi

# ─── a symlinked LEAF is replaced, not followed ─────────────────────────────
# The unlink-before-copy that makes this true is a property of every installed
# file, and until now the only assertion on it lived in
# tests/libressl-trust-store.sh, phrased about the CA bundle. Mutation-removing
# `rm -f` from lib/install-one-file.sh failed that file and nothing else, so
# retiring or reworking the LibreSSL feature would have quietly taken the sole
# coverage of a privileged-write guard with it. The CA-bundle assertion stays
# where it is — it is an end-to-end claim about that feature — and this is the
# generic one, on the class that has no feature of its own.
_s=$(mktemp -d) || exit 1
_d=$(mktemp -d) || exit 1
_sentinel=$(mktemp) || exit 1
_make_stage "$_s"
printf 'SENTINEL-UNTOUCHED\n' > "$_sentinel"
mkdir -p "$_d/lib"
ln -s "$_sentinel" "$_d/lib/libmediaforge-probe.a"

_log=$(_run_install "$_s" "$_d") || true

if [ "$(cat "$_sentinel" 2>/dev/null)" != "SENTINEL-UNTOUCHED" ]; then
  _bad symlinked-leaf-replaced-not-followed \
    "a static lib was written THROUGH a leaf symlink onto $_sentinel"
elif [ -L "$_d/lib/libmediaforge-probe.a" ]; then
  _bad symlinked-leaf-replaced-not-followed \
    "the leaf is still a symlink — nothing was installed, so the sentinel proves nothing"
elif [ "$(cat "$_d/lib/libmediaforge-probe.a" 2>/dev/null)" != "STATIC-LIB" ]; then
  _bad symlinked-leaf-replaced-not-followed \
    "no static lib at the leaf destination under $_d — nothing was installed"
else
  _pass symlinked-leaf-replaced-not-followed
fi
rm -rf "$_s" "$_d" "$_sentinel"

# ─── a copy that fails aborts, and is not recorded as installed ─────────────
# Same reasoning: the checked copy is generic, its only assertion was the
# LibreSSL one. The source is made unreadable to fail the copy without touching
# the destination tree, which is what distinguishes "the copy failed" from "the
# destination was refused".
if [ "$(id -u)" = "0" ]; then
  # SKIP alone, with no _pass beside it: a PASS line for work that did not run
  # tells a human something untrue, and tests/oracle-baseline.sh counts PASS
  # lines — it would read this as an assertion genuinely passing on the base.
  # Under root this file prints one fewer PASS, which is the honest count.
  printf 'SKIP: copy-failure assertion (running as root; 0000 does not stop the read)\n'
else
  _s=$(mktemp -d) || exit 1
  _d=$(mktemp -d) || exit 1
  _make_stage "$_s"
  chmod 000 "$_s/lib/libmediaforge-probe.a"

  _log=$(_run_install "$_s" "$_d") || true
  chmod 644 "$_s/lib/libmediaforge-probe.a" 2>/dev/null

  if ! printf '%s' "$_log" | grep -q 'failed to install'; then
    _bad failed-copy-aborts-unrecorded \
      "an unreadable source did not abort the install: $(printf '%s' "$_log" | tail -2)"
  elif [ -f "$_d/.mediaforge-manifest" ] \
    && grep -q 'libmediaforge-probe.a' "$_d/.mediaforge-manifest" 2>/dev/null; then
    _bad failed-copy-aborts-unrecorded \
      "the failed copy was recorded in the manifest — uninstall would claim to remove it"
  else
    _pass failed-copy-aborts-unrecorded
  fi
  rm -rf "$_s" "$_d"
fi

# Completion sentinel, read by tests/oracle-baseline.sh: it proves this file ran
# to the END on the baseline tree, which is what distinguishes "asserted and
# failed" from "aborted before asserting".
printf 'DONE: install containment\n'
exit "$_fail"
