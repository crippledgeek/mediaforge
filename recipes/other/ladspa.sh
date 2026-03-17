PKG_NAME="ladspa"
PKG_VERSION="${PKG_VERSION_LADSPA:-1.17}"
PKG_URL="https://www.ladspa.org/download/ladspa_sdk_${PKG_VERSION}.tgz"
PKG_FILENAME="ladspa_sdk_${PKG_VERSION}.tgz"
PKG_FFMPEG_OPT="--enable-ladspa"

pkg_configure() { :; }
pkg_build() { :; }

pkg_install() {
  execute cp src/ladspa.h "$WORKSPACE/include/"
}
