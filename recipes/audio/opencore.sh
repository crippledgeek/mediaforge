# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="opencore"
PKG_VERSION="${PKG_VERSION_OPENCORE:-0.1.6}"
PKG_URL="https://sourceforge.net/projects/opencore-amr/files/opencore-amr/opencore-amr-${PKG_VERSION}.tar.gz/download"
PKG_FILENAME="opencore-amr-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libopencore_amrnb --enable-libopencore_amrwb"
