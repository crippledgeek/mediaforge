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
  # --disable-libbsd / --disable-libunwind drop optional system deps so
  # libzmq.pc's Requires.private doesn't pull in -lbsd / -lunwind, neither
  # of which is reliably available as a system static lib (Arch ships .so
  # only). libzmq has internal fallbacks for strlcpy and stack tracing.
  run ./configure --prefix="$PREFIX" --disable-shared --enable-static \
    --disable-libbsd --disable-libunwind
}
