PKG_NAME="giflib"
PKG_VERSION="${PKG_VERSION_GIFLIB:-5.2.2}"
PKG_URL="https://sources.voidlinux.org/giflib-${PKG_VERSION}/giflib-${PKG_VERSION}.tar.gz"

pkg_configure() {
  cd "$DISTDIR/giflib-${PKG_VERSION}" || die "Failed to cd to giflib"
  sed 's/$(MAKE) -C doc//g' Makefile > Makefile.tmp && mv Makefile.tmp Makefile
  sed 's/install: all install-bin install-include install-lib install-man/install: all install-bin install-include install-lib/g' Makefile > Makefile.tmp && mv Makefile.tmp Makefile
}

pkg_build() {
  run make
}

pkg_install() {
  run make PREFIX="$PREFIX" install
}
