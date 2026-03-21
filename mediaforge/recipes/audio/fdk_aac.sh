PKG_NAME="fdk_aac"
PKG_VERSION="${PKG_VERSION_FDK_AAC:-2.0.3}"
PKG_URL="https://sourceforge.net/projects/opencore-amr/files/fdk-aac/fdk-aac-${PKG_VERSION}.tar.gz/download?use_mirror=gigenet"
PKG_FILENAME="fdk-aac-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libfdk-aac"
PKG_NONFREE=true
PKG_CONFIGURE_FLAGS="--enable-pic"
