PKG_NAME="FreeType2-hb"
PKG_VERSION="${PKG_VERSION_FREETYPE2:-2.14.1}"
PKG_URL="https://downloads.sourceforge.net/freetype/freetype-${PKG_VERSION}.tar.xz"

pkg_configure() {
  execute ./configure --prefix="$PREFIX" --disable-shared --enable-static \
    --with-harfbuzz=yes
}
