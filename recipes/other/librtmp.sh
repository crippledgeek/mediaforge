PKG_NAME="librtmp"
PKG_VERSION="${PKG_VERSION_LIBRTMP:-2.6}"
PKG_URL=""
PKG_SKIP_EXTRACT=true
PKG_FFMPEG_OPT="--enable-librtmp"

# librtmp has old C code incompatible with C23 (GCC 15+)
pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS

  # No tarball available — clone from official git repo
  if [ ! -d "$DISTDIR/rtmpdump" ]; then
    run git clone --depth 1 --branch "v${PKG_VERSION}" \
      https://git.ffmpeg.org/rtmpdump.git "$DISTDIR/rtmpdump"
  fi
  cd "$DISTDIR/rtmpdump" || die "Failed to cd to rtmpdump"
}

pkg_configure() {
  :
}

pkg_build() {
  cd librtmp || die "Failed to cd to librtmp"
  # librtmp's Makefile accepts CRYPTO=OPENSSL|GNUTLS|POLARSSL or empty for none.
  # Match mediaforge's --tls= so librtmp.pc's Requires matches what's in $PREFIX.
  case "${TLS_BACKEND:-gnutls}" in
    openssl|libressl) _crypto=OPENSSL; _libs="-lssl -lcrypto -lz -ldl -lpthread" ;;
    gnutls)           _crypto=GNUTLS;  _libs="" ;;
    *)                _crypto="";      _libs="" ;;  # mbedtls/none → no encryption
  esac
  if [ "$_crypto" = "OPENSSL" ]; then
    run make SYS=posix prefix="$PREFIX" \
      SHARED= CRYPTO="$_crypto" \
      XCFLAGS="$CFLAGS -I$PREFIX/include" \
      XLDFLAGS="-L$PREFIX/lib" \
      LIB_OPENSSL="$_libs"
  elif [ "$_crypto" = "GNUTLS" ]; then
    run make SYS=posix prefix="$PREFIX" \
      SHARED= CRYPTO="$_crypto" \
      XCFLAGS="$CFLAGS -I$PREFIX/include" \
      XLDFLAGS="-L$PREFIX/lib"
  else
    # No supported crypto for this TLS backend — build without encryption
    run make SYS=posix prefix="$PREFIX" \
      SHARED= CRYPTO= \
      XCFLAGS="$CFLAGS -I$PREFIX/include" \
      XLDFLAGS="-L$PREFIX/lib"
  fi
}

pkg_install() {
  run make SYS=posix prefix="$PREFIX" SHARED= install
}
