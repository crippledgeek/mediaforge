PKG_NAME="flite"
PKG_VERSION="${PKG_VERSION_FLITE:-2.2}"
PKG_URL="https://github.com/festvox/flite/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="flite-${PKG_VERSION}.tar.gz"
PKG_GITHUB_REPO="festvox/flite"
PKG_FFMPEG_OPT="--enable-libflite"

# flite has old C code incompatible with C23 (GCC 15+)
pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS
}

pkg_configure() {
  execute ./configure --prefix="$WORKSPACE" --with-pic
}

# Build only libraries (parallel make races on flite_voice_list.c for tools)
pkg_build() {
  execute make -j "$MJOBS" -C include
  execute make -j "$MJOBS" -C src
  execute make -j "$MJOBS" -C lang
}

pkg_install() {
  # flite's build dir uses its own triplet, not gcc's
  _builddir=$(find build -maxdepth 1 -type d ! -name build | head -1)
  if [ -z "$_builddir" ]; then
    die "Cannot find flite build directory"
  fi
  mkdir -p "$WORKSPACE/include/flite" "$WORKSPACE/lib"
  execute cp include/*.h "$WORKSPACE/include/flite/"
  execute cp "$_builddir"/lib/*.a "$WORKSPACE/lib/"
}
