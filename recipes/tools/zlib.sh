PKG_NAME="zlib"
PKG_VERSION="1.3.1"
PKG_URL="https://github.com/madler/zlib/releases/download/v${PKG_VERSION}/zlib-${PKG_VERSION}.tar.gz"

pkg_configure() {
  execute ./configure --static --prefix="$WORKSPACE"
}
