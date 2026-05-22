# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="libtiff"
PKG_VERSION="${PKG_VERSION_LIBTIFF:-4.7.1}"
PKG_URL="https://download.osgeo.org/libtiff/tiff-${PKG_VERSION}.tar.xz"
PKG_CONFIGURE_FLAGS="--disable-dependency-tracking --disable-lzma --disable-webp --disable-zstd --without-x"
