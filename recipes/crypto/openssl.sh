# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="openssl"
PKG_VERSION="${PKG_VERSION_OPENSSL:-3.5.4}"
PKG_GITHUB_REPO="openssl/openssl"
PKG_URL="https://github.com/openssl/openssl/archive/refs/tags/openssl-${PKG_VERSION}.tar.gz"
PKG_FILENAME="openssl-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-openssl"
PKG_MUTEX_GROUP="tls"

pkg_configure() {
  run ./Configure --prefix="$PREFIX" --openssldir="$PREFIX" --libdir="lib" \
    --with-zlib-include="$PREFIX/include/" --with-zlib-lib="$PREFIX/lib" \
    no-shared zlib
}

pkg_install() {
  run make install_sw
}
