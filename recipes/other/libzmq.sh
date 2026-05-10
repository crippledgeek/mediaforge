PKG_NAME="libzmq"
PKG_VERSION="${PKG_VERSION_LIBZMQ:-4.3.5}"
PKG_GITHUB_REPO="zeromq/libzmq"
PKG_URL="https://github.com/zeromq/libzmq/releases/download/v${PKG_VERSION}/zeromq-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libzmq"

pkg_prepare() {
  if [ "$OS_MACOS" = true ]; then
    export XML_CATALOG_FILES=/usr/local/etc/xml/catalog
  fi
  # Fix aggregate initialization for GCC 15+ (C23 stricter rules)
  patch -p1 < "$SCRIPT_DIR/patches/libzmq-stats-proxy.patch" 2>/dev/null || true
}

pkg_configure() {
  # In a fully-static build (LDEXEFLAGS set), drop libbsd and libunwind so
  # libzmq.pc's Requires.private doesn't pull -lbsd / -lunwind into FFmpeg's
  # link — neither is available as a system static lib on Arch. libzmq has
  # an internal strlcpy fallback. Dynamic builds keep full optional features.
  _opt_flags=""
  [ -n "$LDEXEFLAGS" ] && _opt_flags="--disable-libbsd --disable-libunwind"
  # shellcheck disable=SC2086
  run ./configure --prefix="$PREFIX" --disable-shared --enable-static $_opt_flags
}
