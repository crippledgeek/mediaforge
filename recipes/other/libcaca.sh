# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="libcaca"
PKG_VERSION="${PKG_VERSION_LIBCACA:-0.99.beta20}"
PKG_URL="https://github.com/cacalabs/libcaca/releases/download/v${PKG_VERSION}/libcaca-${PKG_VERSION}.tar.bz2"
PKG_GITHUB_REPO="cacalabs/libcaca"
PKG_FFMPEG_OPT="--enable-libcaca"

# libcaca has old C code incompatible with C23 (GCC 15+)
PKG_C_STD="gnu11"

pkg_configure() {
  run ./configure --prefix="$PREFIX" --disable-shared --enable-static \
    --disable-doc --disable-java --disable-csharp --disable-ruby \
    --disable-python --disable-x11 --disable-gl --disable-cocoa \
    --disable-ncurses --disable-slang --disable-imlib2
}

# Only build the library, not the broken example tools in src/
pkg_build() {
  run make -j "$MJOBS" -C caca
}

pkg_install() {
  run make -C caca install
  # `make install` creates lib/pkgconfig in the STAGE since GH-59, not in the
  # live prefix, so this cp no longer inherits the directory from the line above
  # it. It happens to succeed anyway because an earlier recipe has always made
  # the directory by the time libcaca builds -- an invisible ordering
  # dependency, and one nothing in the tree would report if it broke.
  mkdir -p "$PREFIX/lib/pkgconfig"
  run cp caca/caca.pc "$PREFIX/lib/pkgconfig/"
}
