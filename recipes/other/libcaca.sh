PKG_NAME="libcaca"
PKG_VERSION="${PKG_VERSION_LIBCACA:-0.99.beta20}"
PKG_URL="https://github.com/cacalabs/libcaca/releases/download/v${PKG_VERSION}/libcaca-${PKG_VERSION}.tar.bz2"
PKG_GITHUB_REPO="cacalabs/libcaca"
PKG_FFMPEG_OPT="--enable-libcaca"

# libcaca has old C code incompatible with C23 (GCC 15+)
pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS
}

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" --disable-shared --enable-static \
    --disable-doc --disable-java --disable-csharp --disable-ruby \
    --disable-python --disable-x11 --disable-gl --disable-cocoa \
    --disable-ncurses --disable-slang
}
