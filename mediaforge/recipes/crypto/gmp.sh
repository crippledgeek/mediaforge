PKG_NAME="gmp"
PKG_VERSION="${PKG_VERSION_GMP:-6.3.0}"
PKG_URL="https://ftpmirror.gnu.org/gnu/gmp/gmp-${PKG_VERSION}.tar.xz"
PKG_SKIP_IF_NONFREE=true

# gmp 6.3.0 uses unprototyped functions that break under C23
pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS
}
