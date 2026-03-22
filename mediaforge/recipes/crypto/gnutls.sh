PKG_NAME="gnutls"
PKG_VERSION="${PKG_VERSION_GNUTLS:-3.8.11}"
PKG_URL="https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-${PKG_VERSION}.tar.xz"
PKG_SKIP_IF_NONFREE=true
PKG_SKIP_ON_ARCH="arm64"

pkg_configure() {
  execute ./configure --prefix="$PREFIX" --disable-shared --enable-static \
    --disable-doc --disable-tools --disable-cxx --disable-tests \
    --disable-gtk-doc-html --disable-libdane --disable-nls \
    --enable-local-libopts --disable-guile --with-included-libtasn1 \
    --with-included-unistring --without-p11-kit \
    CPPFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
}
