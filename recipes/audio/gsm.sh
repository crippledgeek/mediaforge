PKG_NAME="gsm"
PKG_VERSION="${PKG_VERSION_GSM:-1.0.22}"
PKG_URL="https://www.quut.com/gsm/gsm-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libgsm"

# gsm has old C code incompatible with C23 (GCC 15+ defaults to -std=gnu23)
pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS
}

pkg_configure() {
  :
}

pkg_build() {
  execute make -j "$MJOBS" INSTALL_ROOT="$WORKSPACE" \
    CC="gcc" CCFLAGS="$CFLAGS -c -DNeedFunctionPrototypes=1 -Wall -fPIC"
}

pkg_install() {
  mkdir -p "$WORKSPACE/include/gsm" "$WORKSPACE/lib"
  cp inc/gsm.h "$WORKSPACE/include/gsm/"
  cp lib/libgsm.a "$WORKSPACE/lib/"
}
