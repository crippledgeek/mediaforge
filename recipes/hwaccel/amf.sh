PKG_NAME="amf"
PKG_VERSION="${PKG_VERSION_AMF:-1.5.0}"
PKG_GITHUB_REPO="GPUOpen-LibrariesAndSDKs/AMF"
PKG_URL="https://github.com/GPUOpen-LibrariesAndSDKs/AMF/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="AMF-${PKG_VERSION}.tar.gz"
PKG_DIRNAME="AMF-${PKG_VERSION}"
PKG_FFMPEG_OPT="--enable-amf"
PKG_LINUX_ONLY=true

pkg_configure() { :; }
pkg_build() { :; }

pkg_install() {
  rm -rf "$WORKSPACE/include/AMF"
  mkdir -p "$WORKSPACE/include/AMF" || die "Failed to create AMF include dir"
  cp -r "$PACKAGES/AMF-${PKG_VERSION}/AMF-${PKG_VERSION}/amf/public/include/"* \
    "$WORKSPACE/include/AMF/"
}
