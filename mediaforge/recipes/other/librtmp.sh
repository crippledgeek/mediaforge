PKG_NAME="librtmp"
PKG_VERSION="${PKG_VERSION_LIBRTMP:-2.6}"
PKG_URL=""
PKG_SKIP_EXTRACT=true
PKG_FFMPEG_OPT=""

# librtmp has old C code incompatible with C23 (GCC 15+)
pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS

  # No tarball available — clone from official git repo
  if [ ! -d "$DISTDIR/rtmpdump" ]; then
    execute git clone --depth 1 --branch "v${PKG_VERSION}" \
      https://git.ffmpeg.org/rtmpdump.git "$DISTDIR/rtmpdump"
  fi
  cd "$DISTDIR/rtmpdump" || die "Failed to cd to rtmpdump"
}

pkg_configure() {
  :
}

pkg_build() {
  cd librtmp || die "Failed to cd to librtmp"
  execute make SYS=posix prefix="$PREFIX" \
    SHARED= CRYPTO=OPENSSL \
    XCFLAGS="$CFLAGS -I$PREFIX/include" \
    XLDFLAGS="-L$PREFIX/lib" \
    LIB_OPENSSL="-lssl -lcrypto -lz -ldl -lpthread"
}

pkg_install() {
  execute make SYS=posix prefix="$PREFIX" SHARED= install
}

pkg_post_install() {
  FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS --enable-librtmp"
}
