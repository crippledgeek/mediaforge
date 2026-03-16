PKG_NAME="nettle"
PKG_VERSION="${PKG_VERSION_NETTLE:-3.10.2}"
PKG_URL="https://ftpmirror.gnu.org/gnu/nettle/nettle-${PKG_VERSION}.tar.gz"
PKG_SKIP_IF_NONFREE=true

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static \
    --disable-openssl --disable-documentation --libdir="$WORKSPACE/lib" \
    CPPFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
}
