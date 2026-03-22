PKG_NAME="av1"
PKG_VERSION="${PKG_VERSION_AV1:-d772e334cc724105040382a977ebb10dfd393293}"
PKG_URL="https://aomedia.googlesource.com/aom/+archive/${PKG_VERSION}.tar.gz"
PKG_FILENAME="av1.tar.gz"
PKG_DIRNAME="av1"
PKG_FFMPEG_OPT="--enable-libaom"

pkg_configure() {
  rm -rf "$DISTDIR/aom_build" && mkdir -p "$DISTDIR/aom_build"
  cd "$DISTDIR/aom_build" || die "Failed to cd to aom_build"
  if [ "$OS_MACOS_ARM" = true ]; then
    run cmake -DENABLE_TESTS=0 -DENABLE_EXAMPLES=0 \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
      -DCONFIG_RUNTIME_CPU_DETECT=0 "$DISTDIR/av1"
  else
    run cmake -DENABLE_TESTS=0 -DENABLE_EXAMPLES=0 \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
      "$DISTDIR/av1"
  fi
}
