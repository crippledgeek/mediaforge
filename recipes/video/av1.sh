PKG_NAME="av1"
PKG_VERSION="d772e334cc724105040382a977ebb10dfd393293"
PKG_URL="https://aomedia.googlesource.com/aom/+archive/${PKG_VERSION}.tar.gz"
PKG_FILENAME="av1.tar.gz"
PKG_DIRNAME="av1"
PKG_FFMPEG_OPT="--enable-libaom"

pkg_configure() {
  make_dir "$PACKAGES/aom_build"
  cd "$PACKAGES/aom_build" || die "Failed to cd to aom_build"
  if [ "$IS_MACOS_SILICON" = true ]; then
    execute cmake -DENABLE_TESTS=0 -DENABLE_EXAMPLES=0 \
      -DCMAKE_INSTALL_PREFIX="$WORKSPACE" -DCMAKE_INSTALL_LIBDIR=lib \
      -DCONFIG_RUNTIME_CPU_DETECT=0 "$PACKAGES/av1"
  else
    execute cmake -DENABLE_TESTS=0 -DENABLE_EXAMPLES=0 \
      -DCMAKE_INSTALL_PREFIX="$WORKSPACE" -DCMAKE_INSTALL_LIBDIR=lib \
      "$PACKAGES/av1"
  fi
}
