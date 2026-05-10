PKG_NAME="gnutls"
PKG_VERSION="${PKG_VERSION_GNUTLS:-3.8.11}"
PKG_URL="https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-${PKG_VERSION}.tar.xz"
PKG_FFMPEG_OPT="--enable-gnutls"
PKG_MUTEX_GROUP="tls"
PKG_SKIP_ON_ARCH="arm64"

pkg_configure() {
  # In a fully-static build (LDEXEFLAGS set), drop libidn2 to avoid pulling
  # -lidn2 -lunistring into FFmpeg's link via gnutls.pc Requires.private —
  # neither has a static system lib on Arch. Dynamic builds keep full IDN
  # (Punycode) support since the system .so files are available.
  _idn_flag=""
  [ -n "$LDEXEFLAGS" ] && _idn_flag="--without-idn"
  # shellcheck disable=SC2086
  run ./configure --prefix="$PREFIX" --disable-shared --enable-static \
    --disable-doc --disable-tools --disable-cxx --disable-tests \
    --disable-gtk-doc-html --disable-libdane --disable-nls \
    --enable-local-libopts --disable-guile --with-included-libtasn1 \
    --with-included-unistring --without-p11-kit $_idn_flag \
    CPPFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
}
