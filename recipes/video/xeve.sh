# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# EVC main profile is patent-encumbered; baseline is royalty-free. Software BSD-3-Clause.
PKG_NAME="xeve"
PKG_VERSION="${PKG_VERSION_LIBXEVE:-0.5.1}"
PKG_GITHUB_REPO="mpeg5/xeve"
PKG_URL="https://github.com/mpeg5/xeve/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="xeve-${PKG_VERSION}.tar.gz"
PKG_CMAKE=true

# --enable-libxeve requires FFmpeg >= 7.0.
if ffmpeg_version_ge 7.0; then
  PKG_FFMPEG_OPT="--enable-libxeve"
else
  PKG_DISABLED=true
fi

# Built from a tarball (no .git), xeve's CMakeLists can't `git describe` its
# version and aborts unless version.txt exists in the source root, in the
# format v[MAJOR].[MINOR].[PATCH]. Write it before configure.
pkg_prepare() {
  printf 'v%s\n' "$PKG_VERSION" > "$DISTDIR/xeve-${PKG_VERSION}/version.txt"
}

# xeve requires an out-of-source build/ dir. Default (no SET_PROF) builds the
# MAIN profile (which also supports baseline). xeve ignores BUILD_SHARED_LIBS and
# unconditionally builds BOTH a static (src_main/libxeve.a) and a shared lib;
# its install rules ship only the shared one. pkg_install corrects that.
pkg_configure() {
  _src="$DISTDIR/xeve-${PKG_VERSION}"
  rm -rf "$_src/build"
  mkdir -p "$_src/build"
  cd "$_src/build" || die "Failed to cd to xeve build dir"
  run cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release ..
}

pkg_build() {
  cd "$DISTDIR/xeve-${PKG_VERSION}/build" || die "Failed to cd to xeve build dir"
  default_build
}

pkg_install() {
  cd "$DISTDIR/xeve-${PKG_VERSION}/build" || die "Failed to cd to xeve build dir"
  default_install
  # Upstream installs only the shared lib; this is a static build. Install the
  # static archive xeve also built and drop the shared lib so FFmpeg's --static
  # link of -lxeve resolves to libxeve.a (otherwise: "cannot find -lxeve").
  cp src_main/libxeve.a "$PREFIX/lib/libxeve.a" \
    || die "xeve static lib (src_main/libxeve.a) not found"
  rm -f "$PREFIX"/lib/libxeve.so "$PREFIX"/lib/libxeve.so.*
}

# xeve is C++ but its pkgconfig omits -lstdc++ for static linking.
pkg_post_install() {
  _pc="$PREFIX/lib/pkgconfig/xeve.pc"
  awk '/^Libs:/ && !/-lstdc\+\+/ {$0 = $0 " -lstdc++"} {print}' "$_pc" > "$_pc.tmp" && mv "$_pc.tmp" "$_pc"
}
