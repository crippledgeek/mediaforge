# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# Transitive utility — gmp.pc not installed (system has it).
PKG_TRANSITIVE_UTIL=true
PKG_NAME="gmp"
PKG_VERSION="${PKG_VERSION_GMP:-6.3.0}"
PKG_URL="https://ftpmirror.gnu.org/gnu/gmp/gmp-${PKG_VERSION}.tar.xz"

# gmp 6.3.0 uses unprototyped functions that break under C23
pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS
}
