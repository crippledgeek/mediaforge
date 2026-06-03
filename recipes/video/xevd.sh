# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# EVC main profile is patent-encumbered; baseline is royalty-free. Software BSD-3-Clause.
PKG_NAME="xevd"
PKG_VERSION="${PKG_VERSION_LIBXEVD:-0.5.0}"
PKG_GITHUB_REPO="mpeg5/xevd"
PKG_URL="https://github.com/mpeg5/xevd/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="xevd-${PKG_VERSION}.tar.gz"
PKG_CMAKE=true

# --enable-libxevd requires FFmpeg >= 7.0.
if ffmpeg_version_ge 7.0; then
  PKG_FFMPEG_OPT="--enable-libxevd"
else
  PKG_DISABLED=true
fi

# xevd requires an out-of-source build/ dir. Default (no SET_PROF) builds the
# MAIN profile, producing libxevd.a + xevd.pc; MAIN-profile libs also support
# baseline operation. xevd exposes no toggle to disable the app/shared lib, so
# those extra artifacts are built and discarded — FFmpeg links the static lib
# via pkg-config.
pkg_configure() {
  _src="$DISTDIR/xevd-${PKG_VERSION}"
  rm -rf "$_src/build"
  mkdir -p "$_src/build"
  cd "$_src/build" || die "Failed to cd to xevd build dir"
  run cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release ..
}

pkg_build() {
  cd "$DISTDIR/xevd-${PKG_VERSION}/build" || die "Failed to cd to xevd build dir"
  default_build
}

pkg_install() {
  cd "$DISTDIR/xevd-${PKG_VERSION}/build" || die "Failed to cd to xevd build dir"
  default_install
}

# xevd is C++ but its pkgconfig omits -lstdc++ for static linking.
pkg_post_install() {
  _pc="$PREFIX/lib/pkgconfig/xevd.pc"
  awk '/^Libs:/ && !/-lstdc\+\+/ {$0 = $0 " -lstdc++"} {print}' "$_pc" > "$_pc.tmp" && mv "$_pc.tmp" "$_pc"
}
