#!/bin/sh
# LibreSSL compiled-in trust store — regression tests.
#
# Covers crippledgeek/mediaforge#18. #16/#17 coverage lives in
# tests/libressl-pin-asm.sh, which runs in the same suite; duplicating it here
# is what previously made the claim below false.
#
# Every assertion is expected to FAIL against the merge base, and
# tests/oracle-baseline.sh enforces that: it runs this file against a pristine
# base export and fails if any assertion passes there, if none fails there, or
# if the DONE sentinel at the bottom of this file never printed.
#
# No `set -e`: every check reports independently and the script exits with the
# accumulated status, so one early failure does not hide the rest — and the
# baseline gate above depends on that, since a file that aborts early cannot
# prove the assertions after the abort point.
set -u

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
_root=$(CDPATH='' cd -- "$_here/.." && pwd)
cd "$_root" || exit 1

_recipe="recipes/crypto/libressl.sh"
_patch="patches/libressl-no-openssldir-install.patch"
_fail=0

_pass() { printf 'PASS: %s\n' "$1"; }
_bad()  { printf 'FAIL: %s\n' "$1"; _fail=1; }

# ─── #18: the compiled-in trust store ───────────────────────────────────────
# libtls bakes TLS_DEFAULT_CA_FILE at compile time (tls/Makefile.am:53-55) and
# has NO runtime escape: tls/tls_config.c:32 initialises a static const from the
# macro and there is no getenv anywhere in tls/*.c. FFmpeg overrides it only
# when the caller passes -ca_file (libavformat/tls_libtls.c:105). So the recipe
# must CHOOSE the path rather than inherit autotools' sysconfdir default.
if grep -q -- '--with-openssldir=' "$_recipe"; then
  _pass "libressl chooses its openssldir explicitly"
else
  _bad "libressl leaves openssldir to autotools' sysconfdir default (#18)"
fi

# The openssl arm too. --openssldir is advertised for BOTH arms in the help
# text, lib/resolve.sh and README; for a while it reached only libressl, so the
# flag was silently ignored under --tls=openssl — the worst shape for a
# security-relevant knob, since the user gets no signal.
if grep -q 'resolve_openssldir' recipes/crypto/openssl.sh \
   && grep -q -- '--openssldir=' recipes/crypto/openssl.sh \
   && grep -q 'OPENSSLDIR_RESOLVED' recipes/crypto/openssl.sh; then
  _pass "openssl arm honours --openssldir"
else
  _bad "recipes/crypto/openssl.sh ignores --openssldir, which help/README advertise"
fi

# The recipe and the installer each call resolve_openssldir and are handed the
# same inputs explicitly, so they agree by construction rather than through a
# shared recorded value.

# The patch is what makes a host openssldir SAFE. LibreSSL's install-exec-hook
# writes cert.pem/openssl.cnf/x509v3.cnf into $(DESTDIR)@OPENSSLDIR@, ignoring
# --prefix; mediaforge's default_install runs a bare `make install` with no
# DESTDIR. Measured 2026-08-23 against 4.3.2: as a normal user that fails
# outright ("install: cannot remove '/etc/ssl/cert.pem': Permission denied",
# rc=2), and as root it OVERWRITES the host trust store — upstream's
# no-overwrite guard is defeated by a `$i`/`$$i` typo that makes it -f-test a
# directory and always install.
if [ -f "$_patch" ]; then
  _pass "install-exec-hook patch is present"
  # Asserted on the DIFF HEADERS, not on the presence of the string anywhere in
  # the file: the patch's own prose header contains "TARGETS Makefile.in, NOT
  # Makefile.am", so a plain grep passes even when the hunks target Makefile.am
  # — the exact regression this is meant to catch.
  if grep -q '^--- a/Makefile\.in$' "$_patch" && grep -q '^+++ b/Makefile\.in$' "$_patch"; then
    _pass "patch targets Makefile.in (dist tarball ships no regenerated .am)"
  else
    _bad "patch hunks do not target Makefile.in — patching .am is inert without autoreconf"
  fi
else
  _bad "$_patch is missing — a host openssldir would write outside the prefix"
fi

if grep -q 'libressl-no-openssldir-install.patch' "$_recipe"; then
  _pass "recipe applies the install-hook patch"
else
  _bad "recipe never applies the install-hook patch"
fi

# The fallback trust store must SURVIVE. lib/install.sh copies bin/, lib/*.a,
# lib/pkgconfig/, include/ and share/man/man1/ — never etc/ — and `clean` does
# `rm -rf "$PREFIX"`, so without this the installed ffmpeg's baked path points
# into a deleted build tree.
# Asserted by RUNNING do_install/do_uninstall against a synthetic prefix and
# reading the resulting state back, not by grepping lib/install.sh for the path:
# a source grep passes on code that never executes, and the claim here is about
# a file arriving and then being cleaned up.
_stage=$(mktemp -d) || exit 1
_dest=$(mktemp -d) || exit 1
rmdir "$_dest"          # do_install creates it; a pre-existing dir would mask a failure
mkdir -p "$_stage/etc/ssl" "$_stage/.logs"
printf 'not-a-real-bundle\n' > "$_stage/etc/ssl/cert.pem"
# The installer reads the ARM from .mediaforge-choices — the file that already
# persists every resolved choice — and recomputes the path with the same
# resolver the recipe used. So the fixture needs the arm and the explicit
# openssldir, exactly as a real build would have left them.
printf 'STORED_TLS_BACKEND=libressl\n' > "$_stage/.mediaforge-choices"
# NOT "$_dest/etc/ssl": that is exactly where the build-prefix fallback arm
# installs, so an implementation that ignored the stored value would land on the
# same path and score a pass on any host lacking a probed cert.pem. A leaf no
# fallback hardcodes makes the two outcomes distinguishable everywhere.
printf "STORED_OPENSSLDIR='%s'\n" "$_dest/custom/trust" >> "$_stage/.mediaforge-choices"
# Single-quoted exactly as save_stored_choices writes it, because do_install
# parses that shape. No OPENSSLDIR is exported: cmd_install does not set it, and
# injecting it is what previously let both install tests pass while the real
# workflow shipped no bundle at all.

# A separate `sh` process rather than a ( ) subshell: install.sh's do_install
# reads PREFIX/AUTOINSTALL from the environment, and shadowing this script's own
# PREFIX inside a subshell would both confuse the reader and leak install.sh's
# functions into the assertions that follow.
PREFIX="$_stage" INSTALL_MANPAGES=0 AUTOINSTALL=yes SCRIPT_DIR="$_root" VERBOSE=0 \
  sh -c '
    . "$SCRIPT_DIR/lib/utils.sh"
    # resolve.sh too: install.sh calls resolve_openssldir from that file.
    # mediaforge.sh sources it at :23, ahead of every install.sh source site,
    # so this mirrors the real load order.
    . "$SCRIPT_DIR/lib/resolve.sh"
    . "$SCRIPT_DIR/lib/install.sh"
    do_install "$1"
    # `|| true`, not `|| echo 0`: grep -c already PRINTS 0 on no match and then
    # exits 1, so the fallback would append a second line and yield "0\n0".
    printf "MANIFESTED=%s\n" "$(grep -c "custom/trust/cert.pem" "$1/.mediaforge-manifest" 2>/dev/null || true)" >&3
    do_uninstall "$1"
  ' _ "$_dest" 3>"$_stage/probe" >/dev/null 2>&1

# Two independent oracles: the bundle was recorded as installed (read back from
# the manifest while it existed), and nothing survived the uninstall.
if [ "$(cat "$_stage/probe" 2>/dev/null)" = "MANIFESTED=1" ]; then
  _pass "install ships etc/ssl/cert.pem and records it in the manifest"
else
  _bad "etc/ssl/cert.pem was not installed (manifest probe: $(cat "$_stage/probe" 2>/dev/null))"
fi

# Gated on the install having happened: "no residue" is trivially true when
# nothing was ever written, which is exactly the failure mode above.
if [ "$(cat "$_stage/probe" 2>/dev/null)" != "MANIFESTED=1" ]; then
  _bad "residue check skipped — nothing was installed, so it would pass vacuously"
elif [ -e "$_dest" ]; then
  _bad "uninstall left residue at $_dest — etc/ssl is not swept pristinely"
else
  _pass "install/uninstall round-trip leaves no residue"
fi
rm -rf "$_stage" "$_dest"

# ─── a symlinked prefix component must NOT redirect the install ─────────────
# The `case` match on the destination is lexical: '..' is rejected at
# validation, but a SYMLINK is invisible to a string comparison and need not
# exist when --openssldir is validated. _install_file copies under $_priv —
# sudo for a system prefix — so a symlink planted under the install prefix
# during the UNPRIVILEGED build phase would otherwise turn a build-time
# compromise into a root-owned write anywhere on disk.
_sym_stage=$(mktemp -d) || exit 1
_sym_dest=$(mktemp -d) || exit 1
_sym_out=$(mktemp -d) || exit 1
mkdir -p "$_sym_stage/etc/ssl" "$_sym_stage/.logs"
printf 'not-a-real-bundle\n' > "$_sym_stage/etc/ssl/cert.pem"
printf 'STORED_TLS_BACKEND=libressl\n' > "$_sym_stage/.mediaforge-choices"
printf "STORED_OPENSSLDIR='%s'\n" "$_sym_dest/escape/etc/ssl" >> "$_sym_stage/.mediaforge-choices"
# 'escape' looks like it is under the install prefix and resolves outside it.
ln -s "$_sym_out" "$_sym_dest/escape"

_sym_log=$(
  PREFIX="$_sym_stage" INSTALL_MANPAGES=0 AUTOINSTALL=yes SCRIPT_DIR="$_root" VERBOSE=0 \
  sh -c '
    . "$SCRIPT_DIR/lib/utils.sh"
    . "$SCRIPT_DIR/lib/resolve.sh"
    . "$SCRIPT_DIR/lib/install.sh"
    do_install "$1"
  ' _ "$_sym_dest" 2>&1
) || true

if [ -f "$_sym_out/etc/ssl/cert.pem" ]; then
  _bad "the CA bundle was written THROUGH a symlink to $_sym_out — privileged write escaped the prefix"
elif [ -d "$_sym_out/etc/ssl" ] || [ -d "$_sym_out/etc" ]; then
  _bad "mkdir -p created directories THROUGH the symlink at $_sym_out before the guard fired"
elif printf '%s' "$_sym_log" | grep -q 'Refusing a privileged write'; then
  _pass "a symlinked destination is refused before the copy"
else
  _bad "symlinked destination neither refused nor written — unclear outcome: $(printf '%s' "$_sym_log" | tail -2)"
fi
rm -rf "$_sym_stage" "$_sym_dest" "$_sym_out"

# ─── installing into the build prefix must not eat the build tree ───────────
# _install_file unlinks the destination before copying. When the install prefix
# IS the build prefix every destination is its own source, so the unlink deletes
# the file the copy was about to read — binaries, static libs, .pc files and
# headers, gone in place. Before the unlink, `cp` refused a same-file copy
# harmlessly, so this failure mode is newer than the code around it.
_bp=$(mktemp -d) || exit 1
mkdir -p "$_bp/bin" "$_bp/.logs"
printf 'FFMPEG-BINARY\n' > "$_bp/bin/ffmpeg"
_bp_out=$(
  PREFIX="$_bp" INSTALL_MANPAGES=0 AUTOINSTALL=yes SCRIPT_DIR="$_root" VERBOSE=0 \
  sh -c '
    . "$SCRIPT_DIR/lib/utils.sh"
    . "$SCRIPT_DIR/lib/resolve.sh"
    . "$SCRIPT_DIR/lib/install.sh"
    do_install "$1"
  ' _ "$_bp" 2>&1
) || true
if [ "$(cat "$_bp/bin/ffmpeg" 2>/dev/null)" != "FFMPEG-BINARY" ]; then
  _bad "installing into the build prefix destroyed the build tree (bin/ffmpeg is gone or empty)"
elif printf '%s' "$_bp_out" | grep -q 'resolves to the build prefix'; then
  _pass "installing into the build prefix is refused, and the tree survives"
else
  _bad "installing into the build prefix was neither refused nor harmful — unclear: $(printf '%s' "$_bp_out" | tail -1)"
fi
rm -rf "$_bp"

# ...and the same via an ALIAS. A symlink, a bind mount, or a second path into
# the same tree names the build prefix without matching its string, so a lexical
# guard misses it — and then every $_src/$_dest pair is lexically distinct too,
# so the per-file guard misses it as well and the unlink deletes the source
# through the alias. This is the case the first version of the guard could not
# pass; the destination check further down in install.sh already resolved paths
# for exactly this reason.
_ap=$(mktemp -d) || exit 1
mkdir -p "$_ap/real/bin" "$_ap/real/.logs"
printf 'FFMPEG-BINARY\n' > "$_ap/real/bin/ffmpeg"
ln -s "$_ap/real" "$_ap/alias"
_ap_out=$(
  PREFIX="$_ap/real" INSTALL_MANPAGES=0 AUTOINSTALL=yes SCRIPT_DIR="$_root" VERBOSE=0 \
  sh -c '
    . "$SCRIPT_DIR/lib/utils.sh"
    . "$SCRIPT_DIR/lib/resolve.sh"
    . "$SCRIPT_DIR/lib/install.sh"
    do_install "$1"
  ' _ "$_ap/alias" 2>&1
) || true
if [ "$(cat "$_ap/real/bin/ffmpeg" 2>/dev/null)" != "FFMPEG-BINARY" ]; then
  _bad "an aliased --prefix destroyed the build tree through the symlink"
elif printf '%s' "$_ap_out" | grep -q 'resolves to the build prefix'; then
  _pass "an aliased --prefix is resolved, recognised and refused"
else
  _bad "an aliased --prefix was neither refused nor harmful — unclear: $(printf '%s' "$_ap_out" | tail -1)"
fi
rm -rf "$_ap"

# ─── a failed copy must not be recorded as installed ────────────────────────
# _install_file unlinks the destination before copying, so a failed copy now
# leaves NOTHING where the previous file was — for the CA bundle, a prefix whose
# binary reads a path that no longer exists. Recording it in the manifest anyway
# would make `uninstall` report a removal it never performed and hide the
# failure twice.
#
# Skipped as root, where the unwritable directory that provokes the failure is
# not unwritable.
if [ "$(id -u)" = "0" ]; then
  printf 'SKIP: cp-failure assertion (running as root; the fixture cannot fail the copy)\n'
else
  _cf_stage=$(mktemp -d) || exit 1
  _cf_dest=$(mktemp -d) || exit 1
  mkdir -p "$_cf_stage/etc/ssl" "$_cf_stage/.logs"
  printf 'CA-BUNDLE\n' > "$_cf_stage/etc/ssl/cert.pem"
  printf 'STORED_TLS_BACKEND=libressl\n' > "$_cf_stage/.mediaforge-choices"
  printf "STORED_OPENSSLDIR='%s'\n" "$_cf_dest/locked/trust" >> "$_cf_stage/.mediaforge-choices"
  # Destination directory exists but is not writable, so the copy into it fails
  # while every check upstream of it passes.
  mkdir -p "$_cf_dest/locked/trust"
  # The LEAF's directory must be unwritable: locking only its parent still
  # leaves trust/ writable, and the copy succeeds.
  chmod 500 "$_cf_dest/locked/trust"

  _cf_out=$(
    PREFIX="$_cf_stage" INSTALL_MANPAGES=0 AUTOINSTALL=yes SCRIPT_DIR="$_root" VERBOSE=0 \
    sh -c '
      . "$SCRIPT_DIR/lib/utils.sh"
      . "$SCRIPT_DIR/lib/resolve.sh"
      . "$SCRIPT_DIR/lib/install.sh"
      do_install "$1"
    ' _ "$_cf_dest" 2>&1
  ) || true
  chmod 700 "$_cf_dest/locked/trust" 2>/dev/null

  _cf_manifest=$(grep -c 'locked/trust/cert.pem' "$_cf_dest/.mediaforge-manifest" 2>/dev/null || true)
  if [ "${_cf_manifest:-0}" != "0" ]; then
    _bad "a copy that failed was recorded in the manifest — uninstall would claim to remove it"
  elif printf '%s' "$_cf_out" | grep -q 'failed to install'; then
    _pass "a failed copy aborts and is not recorded as installed"
  else
    _bad "a failed copy neither aborted nor was recorded — unclear: $(printf '%s' "$_cf_out" | tail -1)"
  fi
  rm -rf "$_cf_stage" "$_cf_dest"
fi

# ─── a symlinked LEAF must NOT redirect the privileged write ────────────────
# The ancestor walk validates the DIRECTORY chain. It says nothing about the
# leaf: a symlink at $_ca_dest itself sits inside a perfectly legitimate
# directory, so the canonicalization passes — and `cp` follows a destination
# symlink and overwrites what it points at, leaving the link in place. That is a
# privileged write to an attacker-chosen path needing no race at all, only that
# the directory was writable at some earlier point.
_leaf_stage=$(mktemp -d) || exit 1
_leaf_dest=$(mktemp -d) || exit 1
_leaf_sentinel=$(mktemp) || exit 1
printf 'SENTINEL-MUST-SURVIVE\n' > "$_leaf_sentinel"
mkdir -p "$_leaf_stage/etc/ssl" "$_leaf_stage/.logs"
printf 'CA-BUNDLE\n' > "$_leaf_stage/etc/ssl/cert.pem"
printf 'STORED_TLS_BACKEND=libressl\n' > "$_leaf_stage/.mediaforge-choices"
printf "STORED_OPENSSLDIR='%s'\n" "$_leaf_dest/etc/ssl" >> "$_leaf_stage/.mediaforge-choices"
# Directory chain legitimately inside the prefix; only the LEAF is a symlink.
mkdir -p "$_leaf_dest/etc/ssl"
ln -s "$_leaf_sentinel" "$_leaf_dest/etc/ssl/cert.pem"

PREFIX="$_leaf_stage" INSTALL_MANPAGES=0 AUTOINSTALL=yes SCRIPT_DIR="$_root" VERBOSE=0 \
  sh -c '
    . "$SCRIPT_DIR/lib/utils.sh"
    . "$SCRIPT_DIR/lib/resolve.sh"
    . "$SCRIPT_DIR/lib/install.sh"
    do_install "$1"
  ' _ "$_leaf_dest" >/dev/null 2>&1 || true

# BOTH halves, because either alone is satisfiable by doing nothing: an
# untouched sentinel proves only that no write escaped, which is trivially true
# on a tree with no trust-store install at all. The correct behaviour REPLACES
# the symlink with a real file, so require that too.
_leaf_ok=0
if [ "$(cat "$_leaf_sentinel" 2>/dev/null)" != "SENTINEL-MUST-SURVIVE" ]; then
  _bad "the CA bundle was written THROUGH a leaf symlink — sentinel now: $(cat "$_leaf_sentinel" 2>/dev/null)"
elif [ -L "$_leaf_dest/etc/ssl/cert.pem" ]; then
  _bad "the leaf is still a symlink — the bundle was not installed, so the sentinel surviving proves nothing"
elif [ ! -f "$_leaf_dest/etc/ssl/cert.pem" ]; then
  _bad "no bundle at the leaf destination — nothing was installed"
else
  _leaf_ok=1
fi
[ "$_leaf_ok" = 1 ] && _pass "a symlinked leaf is replaced, not followed, by the privileged write"
rm -rf "$_leaf_stage" "$_leaf_dest" "$_leaf_sentinel"

# ─── the probe, unit-tested against a synthetic root ────────────────────────
# curl's shape (acinclude.m4, CURL_CHECK_CA_BUNDLE): try a documented candidate
# list, fall back, and warn on a miss. libtls derives <openssldir>/cert.pem, so
# the candidates are DIRECTORIES whose child is literally cert.pem — a narrower
# list than curl's bundle-file list.
# shellcheck source=lib/utils.sh
. "$_root/lib/utils.sh"
# shellcheck source=lib/resolve.sh
. "$_root/lib/resolve.sh"

if ! command -v resolve_openssldir >/dev/null 2>&1; then
  _bad "resolve_openssldir is not defined — the probe does not exist"
else
  _tmp=$(mktemp -d) || exit 1
  # Trailing "/nope" is a deliberate miss ahead of the hit, proving the probe
  # SELECTS rather than merely returning its first candidate.
  mkdir -p "$_tmp/nope" "$_tmp/hit"
  : > "$_tmp/hit/cert.pem"

  # Candidates are passed as an argument, not exported: the resolver takes them
  # as $3 precisely so a real build cannot have its trust store redirected by a
  # stray environment variable.
  resolve_openssldir "" "/fallback/etc/ssl" "$_tmp/nope $_tmp/hit"
  if [ "$OPENSSLDIR_RESOLVED" = "$_tmp/hit" ] && [ "$OPENSSLDIR_FROM" = "host" ]; then
    _pass "probe selects the first candidate containing cert.pem"
  else
    _bad "probe returned '$OPENSSLDIR_RESOLVED' from '$OPENSSLDIR_FROM', expected '$_tmp/hit' from host"
  fi

  # No candidate holds a cert.pem: the fallback is the staging prefix, backed by
  # LibreSSL's own shipped bundle.
  resolve_openssldir "" "/fallback/etc/ssl" "$_tmp/nope"
  if [ "$OPENSSLDIR_RESOLVED" = "/fallback/etc/ssl" ] && [ "$OPENSSLDIR_FROM" = "fallback" ]; then
    _pass "probe falls back when no candidate has cert.pem"
  else
    _bad "probe returned '$OPENSSLDIR_RESOLVED' from '$OPENSSLDIR_FROM' on a total miss"
  fi

  # A directory that exists but holds no cert.pem must NOT be selected — the
  # boundary between "candidate exists" and "candidate is usable".
  resolve_openssldir "" "/fallback/etc/ssl" "$_tmp"
  if [ "$OPENSSLDIR_RESOLVED" = "/fallback/etc/ssl" ]; then
    _pass "probe rejects a candidate directory with no cert.pem"
  else
    _bad "probe selected '$OPENSSLDIR_RESOLVED', a directory with no cert.pem"
  fi

  # An explicit value outranks a candidate that would otherwise match, and is
  # reported as such. Passed positionally: the resolver no longer reads a global.
  resolve_openssldir "/explicit/etc/ssl" "/fallback/etc/ssl" "$_tmp/hit"
  if [ "$OPENSSLDIR_RESOLVED" = "/explicit/etc/ssl" ] && [ "$OPENSSLDIR_FROM" = "cli" ]; then
    _pass "explicit --openssldir outranks the probe"
  else
    _bad "explicit --openssldir lost to the probe: '$OPENSSLDIR_RESOLVED' from '$OPENSSLDIR_FROM'"
  fi

  rm -rf "$_tmp"
fi

# ─── --openssldir content validation ────────────────────────────────────────
# The value is the FIRST free-form entry in the stored-choices pipeline; every
# other one is enum-constrained. It reaches a file that is sourced as shell on
# the next build, and an install destination written with sudo, so unconstrained
# content is command execution and a privileged arbitrary write respectively.
# Each case below is rejected at the boundary rather than defended against later.
_reject_case() {
  _desc=$1; _value=$2; _expect=$3
  _o=$(./mediaforge.sh build --openssldir="$_value" --dry-run --yes 2>&1) || true
  if printf '%s' "$_o" | grep -q "$_expect"; then
    _pass "--openssldir rejects $_desc"
  else
    _bad "--openssldir ACCEPTED $_desc ('$_value')"
  fi
}

# Command substitution: would be written verbatim into .mediaforge-choices and
# executed by load_stored_choices' `.` on the next run.
# The two metacharacters are assembled via printf (\044 = '$', \140 = '`')
# rather than written literally: a literal '$(' or backtick inside single quotes
# is SC2016, and these payloads must reach the parser UNEXPANDED to be the test
# they claim to be.
_dollar=$(printf '\044')
_backtick=$(printf '\140')
_reject_case "a command substitution" "/tmp/x${_dollar}(id)"               'not allowed'
_reject_case "a backtick"             "/tmp/x${_backtick}id${_backtick}"   'not allowed'
_reject_case "a semicolon"            '/tmp/x;id'                          'not allowed'
# Traversal: satisfies `case "$_install_prefix"/*` yet resolves outside it, and
# the CA-bundle copy runs under sudo for a system prefix.
_reject_case "a .. segment"           '/usr/local/../../etc/ssl' "'..' segment"
_reject_case "a trailing .."          '/usr/local/..'            "'..' segment"

# A legitimate path with the characters real prefixes use must still pass.
_o=$(./mediaforge.sh build --openssldir=/opt/my-prefix_1.0/etc/ssl --dry-run --yes 2>&1) || true
if printf '%s' "$_o" | grep -q 'Choices:.*openssldir=/opt/my-prefix_1.0/etc/ssl' \
   && ! printf '%s' "$_o" | grep -qi 'unknown option'; then
  _pass "--openssldir accepts a realistic path with . _ - digits"
else
  _bad "--openssldir rejected a legitimate path"
fi

# ─── changed openssldir on an existing workspace warns ──────────────────────
# The stamp is keyed on <pkg>-<version> and does not capture the compiled-in
# trust store, so an already-built TLS arm is skipped and keeps the old baked
# path. The previous value is already persisted in .mediaforge-choices, so
# warning off it needs no state of our own and cannot damage a workspace.
# Exercised directly rather than through the CLI: load_stored_choices returns
# early on --dry-run, so the stored value is never read in a dry run and the
# comparison is unreachable that way. A real build is far too slow for a gate.
_w=$(openssldir_warn_if_changed "/previously/etc/ssl" "/now/etc/ssl" 2>&1) || true
if printf '%s' "$_w" | grep -q -- '--openssldir changed'; then
  _pass "a changed --openssldir warns that the stamp will skip the rebuild"
else
  _bad "a changed --openssldir produced no warning about the stale stamp"
fi
# ...and stays quiet when it has not changed, or when there is nothing to compare.
_w=$(openssldir_warn_if_changed "/same/etc/ssl" "/same/etc/ssl" 2>&1) || true
_w2=$(openssldir_warn_if_changed "" "/now/etc/ssl" 2>&1) || true
if [ -z "$_w" ] && [ -z "$_w2" ]; then
  _pass "no warning when the openssldir is unchanged or previously unset"
else
  _bad "spurious openssldir-changed warning: '$_w' '$_w2'"
fi

# ─── CLI surface ────────────────────────────────────────────────────────────
# Absolute is the boundary, asserted on BOTH sides: the value is compiled into
# libtls, so a relative path would be resolved against the working directory of
# whatever process links it — the arm would silently trust nothing.
# Matched against the exact die text, not the word "absolute": the help output
# now contains "absolute" (mediaforge.sh:95), so anything that prints usage —
# including an unrelated parse failure — would satisfy a looser grep.
_out=$(./mediaforge.sh build --openssldir=relative/etc/ssl --dry-run --yes 2>&1) || true
if printf '%s' "$_out" | grep -q 'is not an absolute path'; then
  _pass "--openssldir rejects a relative path"
else
  _bad "--openssldir accepted a relative path (or the option does not exist)"
fi

# Acceptance is asserted POSITIVELY — the run must reach the resolved-choice log,
# which is only printed once option parsing and validation have both succeeded.
# Absence of "unknown option" alone would pass on a crash or an unrelated die.
#
# rc is now part of the oracle too: since #19's --dry-run fix, cmd_build's
# DRY_RUN guard returns 0 unconditionally, so a nonzero exit here can only
# come from something going wrong before that guard (option parsing, path
# validation) — the earlier `|| true` masked exactly that signal by folding
# every nonzero rc into 0 before `_rc=$?` could read it, so it is dropped
# from this assignment; the assertion below captures the real rc instead.
_out=$(./mediaforge.sh build --openssldir=/etc/ssl --dry-run --yes 2>&1)
_rc=$?
if [ "$_rc" -eq 0 ] \
   && printf '%s' "$_out" | grep -q 'tls=' \
   && ! printf '%s' "$_out" | grep -qi 'unknown option' \
   && ! printf '%s' "$_out" | grep -q 'is not an absolute path'; then
  _pass "--openssldir accepts an absolute path"
else
  _bad "--openssldir=/etc/ssl did not survive option parsing (rc=$_rc)"
fi

# --openssldir LAST, with nothing after it: that is the only position in which
# the missing value is detectable. Given trailing flags the parser consumes the
# next one as the value ("--openssldir --dry-run" yields OPENSSLDIR=--dry-run),
# which the absolute-path check above then rejects on different grounds — a
# genuine rejection, but not the one this assertion is about.
_out=$(./mediaforge.sh build --openssldir 2>&1) || true
if printf '%s' "$_out" | grep -q 'requires an argument'; then
  _pass "--openssldir with no value is rejected"
else
  _bad "--openssldir with no value did not error"
fi

# Completion sentinel, read by tests/oracle-baseline.sh. It proves this file ran
# to the END on the baseline tree — the property that distinguishes "asserted
# and failed", which is what the gate wants to see, from "aborted before
# asserting", which is what it exists to catch.
printf 'DONE: libressl trust store\n'
exit "$_fail"
