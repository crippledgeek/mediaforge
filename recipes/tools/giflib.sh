PKG_NAME="giflib"
PKG_VERSION="${PKG_VERSION_GIFLIB:-5.2.2}"
PKG_URL="https://sourceforge.net/projects/giflib/files/giflib-${PKG_VERSION}.tar.gz/download"
PKG_FILENAME="giflib-${PKG_VERSION}.tar.gz"

pkg_configure() {
  cd "$DISTDIR/giflib-${PKG_VERSION}" || die "Failed to cd to giflib"
  patch -p1 < "$SCRIPT_DIR/patches/giflib-makefile.patch" 2>/dev/null || true
}

pkg_build() {
  run make
}

pkg_install() {
  run make PREFIX="$PREFIX" install
}
