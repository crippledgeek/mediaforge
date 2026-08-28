# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# H.266/VVC is patent-pool encumbered (Access Advance + Fraunhofer hold
# separately). Software is BSD-3-Clause-Clear; encode deployment may require
# patent licensing.
PKG_NAME="vvenc"
PKG_VERSION="${PKG_VERSION_LIBVVENC:-1.14.0}"
PKG_GITHUB_REPO="fraunhoferhhi/vvenc"
PKG_URL="https://github.com/fraunhoferhhi/vvenc/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="vvenc-${PKG_VERSION}.tar.gz"
PKG_CMAKE=true

# --enable-libvvenc requires FFmpeg >= 7.1.
if ffmpeg_version_ge 7.1; then
  PKG_FFMPEG_OPT="--enable-libvvenc"
else
  PKG_DISABLED=true
fi

# LTO follows $ENABLE_LTO (default off). vvenc defaults LTO ON upstream, which
# bakes GCC-version-specific GIMPLE into libvvenc.a and breaks downstream links
# after a GCC major bump (same hazard as svtav1). Opt in via --enable-lto.
pkg_configure() {
  _lto=OFF
  [ "$ENABLE_LTO" = true ] && _lto=ON
  PKG_CMAKE_BUILD_TYPE=Release
  mf_cmake -DBUILD_SHARED_LIBS=OFF \
    -DVVENC_LIBRARY_ONLY=ON \
    -DVVENC_ENABLE_LINK_TIME_OPT="$_lto" .
}

# vvenc is C++ but its pkgconfig omits -lstdc++ for static linking.
pkg_post_install() {
  _pc="$PREFIX/lib/pkgconfig/libvvenc.pc"
  awk '/^Libs:/ && !/-lstdc\+\+/ {$0 = $0 " -lstdc++"} {print}' "$_pc" > "$_pc.tmp" && mv "$_pc.tmp" "$_pc"
}
