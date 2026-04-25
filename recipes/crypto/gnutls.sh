PKG_NAME="gnutls"
PKG_VERSION="${PKG_VERSION_GNUTLS:-3.8.11}"
PKG_URL="https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-${PKG_VERSION}.tar.xz"
PKG_MUTEX_GROUP="tls"
PKG_SKIP_ON_ARCH="arm64"

pkg_configure() {
  # --without-idn drops the libidn2 dep (which would otherwise propagate via
  # gnutls.pc's Requires.private into FFmpeg's static link as -lidn2 -lunistring,
  # neither of which is reliably available as a system static lib). Cost:
  # gnutls won't accept HTTPS URLs with non-ASCII (Punycode) domain names —
  # not a real concern for FFmpeg streaming use.
  run ./configure --prefix="$PREFIX" --disable-shared --enable-static \
    --disable-doc --disable-tools --disable-cxx --disable-tests \
    --disable-gtk-doc-html --disable-libdane --disable-nls \
    --enable-local-libopts --disable-guile --with-included-libtasn1 \
    --with-included-unistring --without-p11-kit --without-idn \
    CPPFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
}
