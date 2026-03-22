PKG_NAME="libpng"
PKG_VERSION="${PKG_VERSION_LIBPNG:-1.6.53}"
PKG_URL="https://sourceforge.net/projects/libpng/files/libpng16/${PKG_VERSION}/libpng-${PKG_VERSION}.tar.gz"
PKG_FILENAME="libpng-${PKG_VERSION}.tar.gz"

pkg_configure() {
  export LDFLAGS="$LDFLAGS"
  export CPPFLAGS="$CFLAGS"
  execute ./configure --prefix="$PREFIX" --disable-shared --enable-static
}
