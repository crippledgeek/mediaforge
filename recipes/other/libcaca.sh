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

# No hand-copy of caca.pc after this: upstream installs it itself. caca/
# Makefile.am declares `pkgconfig_DATA = caca.pc` unconditionally, and the
# recipe's stamp records lib/pkgconfig/caca.pc as STAGED -- which only
# `make install` can have put there. The `mkdir -p` and `cp` that used to
# follow (predating staging, from the repo flatten in 16ade04) installed the
# same file a second time, into the live prefix where nothing recorded it.
pkg_install() {
  run make -C caca install
}
