PKG_NAME="srt"
PKG_VERSION="${PKG_VERSION_SRT:-1.5.4}"
PKG_GITHUB_REPO="Haivision/srt"
PKG_URL="https://github.com/Haivision/srt/archive/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="srt-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libsrt"
PKG_NONFREE=true

pkg_configure() {
  # Match SRT's encryption backend to mediaforge's chosen --tls= so srt.pc's
  # Requires.private references libs that actually exist in $PREFIX/lib.
  # SRT supports openssl/openssl-evp/gnutls/mbedtls/botan (since 1.6.0).
  case "${TLS_BACKEND:-gnutls}" in
    openssl|libressl) _enclib="openssl-evp" ;;
    gnutls)           _enclib="gnutls" ;;
    mbedtls)          _enclib="mbedtls" ;;
    none)             _enclib="" ;;
    *)                _enclib="gnutls" ;;
  esac

  _enc_args="-DENABLE_ENCRYPTION=ON -DUSE_ENCLIB=$_enclib"
  if [ -z "$_enclib" ]; then
    _enc_args="-DENABLE_ENCRYPTION=OFF"
  fi

  # OpenSSL family expects OPENSSL_* vars; gnutls/mbedtls use plain pkg-config.
  case "$_enclib" in
    openssl|openssl-evp)
      export OPENSSL_ROOT_DIR="$PREFIX"
      export OPENSSL_LIB_DIR="$PREFIX/lib"
      export OPENSSL_INCLUDE_DIR="$PREFIX/include/"
      ;;
  esac

  # shellcheck disable=SC2086
  run cmake . -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_BINDIR=bin \
    -DCMAKE_INSTALL_INCLUDEDIR=include -DENABLE_SHARED=OFF \
    -DENABLE_STATIC=ON -DENABLE_APPS=OFF -DUSE_STATIC_LIBSTDCXX=ON \
    $_enc_args
}

pkg_install() {
  run make install
}

pkg_post_install() {
  if [ -n "$LDEXEFLAGS" ]; then
    _pc="$PREFIX/lib/pkgconfig/srt.pc"
    awk '/^Libs/ {gsub(/-lgcc_s/, "-lgcc_eh")} {print}' "$_pc" > "$_pc.tmp" && mv "$_pc.tmp" "$_pc"
  fi
}
