PKG_NAME="amf"
PKG_VERSION="${PKG_VERSION_AMF:-1.5.0}"
PKG_GITHUB_REPO="GPUOpen-LibrariesAndSDKs/AMF"
# AMF ships headers as a separate release asset (not in the source tarball)
PKG_URL="https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/download/v${PKG_VERSION}/AMF-headers-v${PKG_VERSION}.tar.gz"
PKG_FILENAME="AMF-headers-v${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-amf"
PKG_LINUX_ONLY=true

pkg_configure() { :; }
pkg_build() { :; }

pkg_install() {
  rm -rf "$PREFIX/include/AMF"
  mkdir -p "$PREFIX/include/AMF" || die "Failed to create AMF include dir"
  execute cp -r AMF/components AMF/core "$PREFIX/include/AMF/"
}
