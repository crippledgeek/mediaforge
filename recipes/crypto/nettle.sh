# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="nettle"
PKG_VERSION="${PKG_VERSION_NETTLE:-3.10.2}"
PKG_URL="https://ftpmirror.gnu.org/gnu/nettle/nettle-${PKG_VERSION}.tar.gz"
# Transitive utility — drops nettle.pc and hogweed.pc.
PKG_TRANSITIVE_UTIL=true
PKG_PC_FILES="nettle hogweed"

pkg_configure() {
  run ./configure --prefix="$PREFIX" --disable-shared --enable-static \
    --disable-openssl --disable-documentation --libdir="$PREFIX/lib" \
    CPPFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
}
