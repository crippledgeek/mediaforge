#!/bin/sh
# LibreSSL recipe regression tests — pin, assembly, PIC, and the compiled-in
# trust store.
#
# Covers crippledgeek/mediaforge#16, #17 and #18. Each assertion below fails
# against the pre-fix tree; see the per-section comments for what each one is
# guarding and why the evidence says so.
#
# Every assertion here fails against the pre-fix tree. Checks that would also
# pass on develop have been removed rather than kept for reassurance.
#
# No `set -e`: every check reports independently and the script exits with the
# accumulated status, so one early failure does not hide the rest.
set -u

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
_root=$(CDPATH='' cd -- "$_here/.." && pwd)
cd "$_root" || exit 1

_recipe="recipes/crypto/libressl.sh"
_patch="patches/libressl-no-openssldir-install.patch"
_fail=0

_pass() { printf 'PASS: %s\n' "$1"; }
_bad()  { printf 'FAIL: %s\n' "$1"; _fail=1; }

# ─── #16: the pin, and the mechanism that let it rot ────────────────────────
# 4.0.0 (2024-10-15) predates the 4.2.0 ChangeLog `* Security fixes` entry for
# the CMS enveloped-data out-of-bounds read/write, so the old default shipped a
# TLS stack missing an upstream-declared security fix.
if grep -q 'PKG_VERSION_LIBRESSL:-4\.3\.2' "$_recipe"; then
  _pass "libressl pins 4.3.2"
else
  _bad "libressl does not pin 4.3.2 (4.0.0 misses the 4.2.0 CMS security fix)"
fi

# The ROOT CAUSE of the staleness, not merely the symptom: lib/updates.sh:72
# prints "(not on GitHub)" and skips any recipe with no PKG_GITHUB_REPO, so
# `check-updates` has never once reported this pin. Upstream tags are
# v-prefixed, which _strip_tag_prefix already handles.
if grep -q '^PKG_GITHUB_REPO="libressl/portable"' "$_recipe"; then
  _pass "libressl is visible to check-updates"
else
  _bad "libressl has no PKG_GITHUB_REPO — check-updates skips it (lib/updates.sh:72)"
fi

# Every other TLS arm is profile-pinned; libressl was the only one that was not,
# so a --profile build silently fell back to the recipe default.
for _prof in profiles/ffmpeg-*.conf; do
  if grep -q '^PKG_VERSION_LIBRESSL=' "$_prof"; then
    _pass "$(basename "$_prof") pins PKG_VERSION_LIBRESSL"
  else
    _bad "$(basename "$_prof") does not pin PKG_VERSION_LIBRESSL"
  fi
done

# ─── #17: assembly, and PIC ─────────────────────────────────────────────────
# Upstream already force-disables asm per-arch where it is unsafe
# (configure.ac:82-84 for i?86/mips/mips64) and gates elf x86_64 on
# enable_asm != no (:126), so a blanket flag only removed it where upstream
# considers it good. Neither FreeBSD's port nor Alpine's APKBUILD passes it.
# Comment lines are stripped first: the recipe DOCUMENTS --disable-asm in its
# "NOT passed, deliberately" note, and a whole-file grep would match that prose
# and report a regression that does not exist.
if grep -v '^[[:space:]]*#' "$_recipe" | grep -q -- '--disable-asm'; then
  _bad "libressl still passes --disable-asm (drops AES-NI/SHA/bignum asm)"
else
  _pass "libressl builds with assembly enabled"
fi

# With --disable-shared, libtool builds the static objects WITHOUT PIC, and
# these archives are linked into libavcodec/libavformat.
if grep -q -- '--with-pic' "$_recipe"; then
  _pass "libressl builds PIC static objects"
else
  _bad "libressl does not pass --with-pic (static objects land in libav*)"
fi

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

# The state layer that used to keep three consumers agreeing is gone; each now
# calls resolve_openssldir and is handed the same inputs explicitly. There is
# deliberately no assertion that the removed helpers stay removed: those names
# are absent from develop too, so such a check passes on any tree that never had
# them, and it would guard a retired design by NAME while a re-introduction
# under different names walked straight past. The reasoning lives in
# lib/resolve.sh, where it informs rather than merely forbids.

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
printf "STORED_OPENSSLDIR='%s'\n" "$_dest/etc/ssl" >> "$_stage/.mediaforge-choices"
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
    printf "MANIFESTED=%s\n" "$(grep -c "etc/ssl/cert.pem" "$1/.mediaforge-manifest" 2>/dev/null || true)" >&3
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
  # as $2 precisely so a real build cannot have its trust store redirected by a
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
if printf '%s' "$_o" | grep -q 'openssldir=/opt/my-prefix_1.0/etc/ssl'; then
  _pass "--openssldir accepts a realistic path with . _ - digits"
else
  _bad "--openssldir rejected a legitimate path"
fi

# ─── changed openssldir on an existing workspace warns ──────────────────────
# The stamp is keyed on <pkg>-<version> and does not capture the compiled-in
# trust store, so an already-built TLS arm is skipped and keeps the old baked
# path. The earlier design detected this with a per-recipe state file and a
# framework hook, and that machinery produced two Criticals; the value is
# already persisted in .mediaforge-choices, so a warning off the stored value
# costs nothing and cannot damage a workspace.
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
# Exit status is NOT usable as the oracle here, and that is a property of the
# harness rather than of this flag: --dry-run runs FFmpeg's configure for real
# (tests/lcevc-default-off.sh documents the same thing), so on a workspace with
# no built dependencies EVERY dry-run exits 1, including a bare
# `./mediaforge.sh build --dry-run` — measured. Requiring rc=0 would fail
# permanently for a reason unrelated to what is being tested.
_out=$(./mediaforge.sh build --openssldir=/etc/ssl --dry-run --yes 2>&1) || true
if printf '%s' "$_out" | grep -q 'tls=' \
   && ! printf '%s' "$_out" | grep -qi 'unknown option' \
   && ! printf '%s' "$_out" | grep -q 'is not an absolute path'; then
  _pass "--openssldir accepts an absolute path"
else
  _bad "--openssldir=/etc/ssl did not survive option parsing"
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

exit "$_fail"
