# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# ICC color management. MIT.
PKG_NAME="lcms2"
PKG_VERSION="${PKG_VERSION_LCMS2:-2.19.1}"
PKG_GITHUB_REPO="mm2/Little-CMS"
# Release tag is "lcms<version>" while the tarball is "lcms2-<version>.tar.gz"
# (e.g. lcms2.19.1/lcms2-2.19.1.tar.gz).
PKG_URL="https://github.com/mm2/Little-CMS/releases/download/lcms${PKG_VERSION}/lcms2-${PKG_VERSION}.tar.gz"
PKG_FILENAME="lcms2-${PKG_VERSION}.tar.gz"
# FFmpeg flag has no "lib" prefix.
PKG_FFMPEG_OPT="--enable-lcms2"
# Drop optional JPEG/TIFF integration; FFmpeg only needs the core library.
PKG_CONFIGURE_FLAGS="--without-jpeg --without-tiff"
