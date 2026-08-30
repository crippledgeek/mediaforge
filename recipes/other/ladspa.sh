# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="ladspa"
PKG_VERSION="${PKG_VERSION_LADSPA:-1.17}"
PKG_URL="https://www.ladspa.org/download/ladspa_sdk_${PKG_VERSION}.tgz"
PKG_FILENAME="ladspa_sdk_${PKG_VERSION}.tgz"
PKG_FFMPEG_OPT="--enable-ladspa"

pkg_configure() { :; }
pkg_build() { :; }

# mf_dest_prefix, not $PREFIX: a shell cp writes past the stage, and an
# unstaged install records nothing (GH-68; see lib/stage.sh). The mkdir comes
# with it: the copy used to land in an include/ some earlier recipe had already
# created, and a freshly reset stage has nothing in it at all.
pkg_install() {
  _dest=$(mf_dest_prefix)
  mkdir -p "$_dest/include" || die "Failed to create $_dest/include"
  run cp src/ladspa.h "$_dest/include/"
}
