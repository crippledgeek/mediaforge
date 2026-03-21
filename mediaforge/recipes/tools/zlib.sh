PKG_NAME="zlib"
PKG_VERSION="${PKG_VERSION_ZLIB:-1.3.1}"
PKG_GITHUB_REPO="madler/zlib"
PKG_URL="https://github.com/madler/zlib/releases/download/v${PKG_VERSION}/zlib-${PKG_VERSION}.tar.gz"

pkg_configure() {
  execute ./configure --static --prefix="$WORKSPACE"
}
