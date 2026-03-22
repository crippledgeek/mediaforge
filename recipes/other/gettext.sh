PKG_NAME="gettext"
PKG_VERSION="${PKG_VERSION_GETTEXT:-0.22.5}"
PKG_URL="https://ftpmirror.gnu.org/gettext/gettext-${PKG_VERSION}.tar.gz"
PKG_NONFREE=true

# gettext 0.22.5 bundles gnulib with C23-incompatible code
pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS
}
