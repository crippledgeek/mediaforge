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

# Resolve CRYPTO once and reuse in both build and install (same Makefile var
# must be set in both invocations or `make install` regenerates librtmp.pc
# with the default CRYPTO=OPENSSL).
_librtmp_crypto() {
  case "${TLS_BACKEND:-gnutls}" in
    openssl|libressl) printf 'OPENSSL\n' ;;
    gnutls)           printf 'GNUTLS\n'  ;;
    *)                printf '\n'        ;;  # mbedtls/none → no encryption
  esac
}

pkg_build() {
  cd librtmp || die "Failed to cd to librtmp"
  # Wipe any stale .o/.a/.pc from a previous CRYPTO= setting so the .pc gets
  # regenerated from librtmp.pc.in with the current REQ_$(CRYPTO).
  run make clean

  _crypto=$(_librtmp_crypto)
  case "$_crypto" in
    OPENSSL)
      run make SYS=posix prefix="$PREFIX" SHARED= CRYPTO="$_crypto" \
        XCFLAGS="$CFLAGS -I$PREFIX/include" XLDFLAGS="-L$PREFIX/lib" \
        LIB_OPENSSL="-lssl -lcrypto -lz -ldl -lpthread"
      ;;
    GNUTLS)
      run make SYS=posix prefix="$PREFIX" SHARED= CRYPTO="$_crypto" \
        XCFLAGS="$CFLAGS -I$PREFIX/include" XLDFLAGS="-L$PREFIX/lib"
      ;;
    *)
      run make SYS=posix prefix="$PREFIX" SHARED= CRYPTO= \
        XCFLAGS="$CFLAGS -I$PREFIX/include" XLDFLAGS="-L$PREFIX/lib"
      ;;
  esac
}

pkg_install() {
  # Pass the same CRYPTO so `install_base`'s librtmp.pc target substitutes
  # the matching REQ_$(CRYPTO) into Requires.
  _crypto=$(_librtmp_crypto)
  run make SYS=posix prefix="$PREFIX" SHARED= CRYPTO="$_crypto" install
}
