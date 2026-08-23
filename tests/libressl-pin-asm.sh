#!/bin/sh
# LibreSSL pin, update-checker visibility, assembly and PIC.
#
# Covers crippledgeek/mediaforge#16 and #17. The compiled-in trust store (#18)
# is a separate change with its own CLI surface and gates; nothing here asserts
# on it, and the scope guard at the bottom fails if it arrives.
#
# No `set -e`: every check reports independently and the script exits with the
# accumulated status, so one early failure does not hide the rest.
set -u

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
_root=$(CDPATH='' cd -- "$_here/.." && pwd)
cd "$_root" || exit 1

_recipe="recipes/crypto/libressl.sh"
_fail=0

_pass() { printf 'PASS: %s\n' "$1"; }
_bad()  { printf 'FAIL: %s\n' "$1"; _fail=1; }

# Read a recipe's default version out of its `PKG_VERSION="${PKG_VERSION_X:-N}"`
# line. The pattern deliberately avoids a literal '${' so it needs no
# double-quoting gymnastics to stay ShellCheck-clean.
_recipe_default_version() {
  sed -n 's/^PKG_VERSION=.*:-\(.*\)}".*/\1/p' "$1"
}

# ─── #16: the pin, and the mechanism that let it rot ────────────────────────
# 4.0.0 (2024-10-15) predates the 4.2.0 ChangeLog `* Security fixes` entry for
# the CMS enveloped-data out-of-bounds read/write, so the old default shipped a
# TLS stack missing an upstream-declared security fix.
_want=$(_recipe_default_version "$_recipe")
if [ -z "$_want" ]; then
  _bad "cannot read the libressl default version from $_recipe"
elif [ "$_want" = "4.0.0" ]; then
  _bad "libressl still pins 4.0.0, which misses the 4.2.0 CMS security fix"
else
  _pass "libressl pins $_want"
fi

# The ROOT CAUSE of the staleness, not merely the symptom: lib/updates.sh:72
# takes the no-repo branch and reports "(not on GitHub)" for any recipe without
# PKG_GITHUB_REPO, so `check-updates` never queried this pin at all. Upstream
# tags are v-prefixed, which _strip_tag_prefix already normalises.
if grep -q '^PKG_GITHUB_REPO="libressl/portable"' "$_recipe"; then
  _pass "libressl is visible to check-updates"
else
  _bad "libressl has no PKG_GITHUB_REPO — check-updates skips it (lib/updates.sh:72)"
fi

# Sourced the way lib/updates.sh sources it, and the variable read back. This is
# NOT about comments — the grep above is anchored at start-of-line and cannot
# match one. It catches what a grep structurally cannot: that the recipe is
# sourceable at all, and that the assignment still holds at END of file. A later
# reassignment, or a failure part-way through sourcing, defeats the grep and is
# caught here.
_probe=$(
  PKG_GITHUB_REPO=""
  # shellcheck source=recipes/crypto/libressl.sh
  . "$_root/$_recipe" >/dev/null 2>&1
  printf '%s' "$PKG_GITHUB_REPO"
)
if [ "$_probe" = "libressl/portable" ]; then
  _pass "sourcing the recipe yields PKG_GITHUB_REPO=libressl/portable"
else
  _bad "sourced recipe gave PKG_GITHUB_REPO='$_probe'"
fi

# libressl and mbedtls were the two --tls arms no profile pinned, so a --profile
# build silently fell back to the recipe default for either. openssl and gnutls
# already carry era-appropriate pins.
#
# Compared by VALUE against the recipe default, not merely for presence: a
# profile left behind at an older pin satisfies a presence check while
# reintroducing exactly the defect #16 is about for every --profile build. It
# also stops the version living in five files with nothing checking they agree.
for _pkg in libressl mbedtls; do
  _pkgwant=$(_recipe_default_version "recipes/crypto/$_pkg.sh")
  _var=$(printf 'PKG_VERSION_%s' "$_pkg" | tr '[:lower:]' '[:upper:]')
  if [ -z "$_pkgwant" ]; then
    _bad "cannot read the $_pkg default version from its recipe"
    continue
  fi
  for _prof in profiles/ffmpeg-*.conf; do
    _base=$(basename "$_prof")
    if grep -q "^$_var=\"$_pkgwant\"$" "$_prof"; then
      _pass "$_base pins $_var=$_pkgwant"
    else
      _bad "$_base does not pin $_var=$_pkgwant (the recipe default)"
    fi
  done
done

# ─── #17: assembly, and PIC ─────────────────────────────────────────────────
# Upstream already force-disables asm per-arch where it is unsafe
# (configure.ac:82-84 for i?86/mips/mips64) and gates elf x86_64 on
# enable_asm != no (:126), so a blanket flag only removed it where upstream
# considers it good. Neither FreeBSD's port nor Alpine's APKBUILD passes it.
#
# Comment lines are stripped first: the recipe DOCUMENTS --disable-asm in its
# "NOT passed, deliberately" note, and a whole-file grep would match that prose
# and report a regression that does not exist.
if grep -v '^[[:space:]]*#' "$_recipe" | grep -q -- '--disable-asm'; then
  _bad "libressl still passes --disable-asm (drops AES-NI/SHA/bignum asm)"
else
  _pass "libressl builds with assembly enabled"
fi

# --with-pic is NOT what gives these objects -fPIC — mediaforge.sh:251-257
# exports that for every recipe unconditionally. It adds libtool's own -DPIC,
# which LibreSSL's C and perlasm paths read, and makes the recipe independent of
# a CFLAGS assignment several files away.
if grep -v '^[[:space:]]*#' "$_recipe" | grep -q -- '--with-pic'; then
  _pass "libressl passes --with-pic"
else
  _bad "libressl does not pass --with-pic"
fi

# The #18 scope guard that used to live here has done its job and is retired:
# the trust-store surface it watched for has landed on this branch, and
# tests/libressl-trust-store.sh now asserts that surface directly. Keeping a
# guard that fails on the thing the branch exists to add would be noise.

exit "$_fail"
