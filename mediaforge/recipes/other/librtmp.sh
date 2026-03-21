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
  if [ ! -d "$PACKAGES/rtmpdump" ]; then
    execute git clone --depth 1 --branch "v${PKG_VERSION}" \
      https://git.ffmpeg.org/rtmpdump.git "$PACKAGES/rtmpdump"
  fi
  cd "$PACKAGES/rtmpdump" || die "Failed to cd to rtmpdump"
}

pkg_configure() {
  :
}

pkg_build() {
  cd librtmp || die "Failed to cd to librtmp"
  execute make SYS=posix prefix="$WORKSPACE" \
    SHARED= CRYPTO=OPENSSL \
    XCFLAGS="$CFLAGS -I$WORKSPACE/include" \
    XLDFLAGS="-L$WORKSPACE/lib" \
    LIB_OPENSSL="-lssl -lcrypto -lz -ldl -lpthread"
}

pkg_install() {
  execute make SYS=posix prefix="$WORKSPACE" SHARED= install
}

pkg_post_install() {
  CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --enable-librtmp"
}
