# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# EVC main profile is patent-encumbered; baseline is royalty-free. Software BSD-3-Clause.
PKG_NAME="xevd"
PKG_VERSION="${PKG_VERSION_LIBXEVD:-0.5.0}"
PKG_GITHUB_REPO="mpeg5/xevd"
PKG_URL="https://github.com/mpeg5/xevd/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="xevd-${PKG_VERSION}.tar.gz"
PKG_CMAKE=true
PKG_CMAKE_BUILD_TYPE="Release"

# --enable-libxevd requires FFmpeg >= 7.0.
if ffmpeg_version_ge 7.0; then
  PKG_FFMPEG_OPT="--enable-libxevd"
else
  PKG_DISABLED=true
fi

# Built from a tarball (no .git), xevd's CMakeLists can't `git describe` its
# version and aborts unless version.txt exists in the source root, in the
# format v[MAJOR].[MINOR].[PATCH]. Write it before configure.
pkg_prepare() {
  printf 'v%s\n' "$PKG_VERSION" > "$DISTDIR/xevd-${PKG_VERSION}/version.txt"
}

# xevd requires an out-of-source build/ dir. Default (no SET_PROF) builds the
# MAIN profile (which also supports baseline). xevd ignores BUILD_SHARED_LIBS and
# unconditionally builds BOTH a static (src_main/libxevd.a) and a shared lib;
# its install rules put the shared lib flat in lib/ but the static archive in a
# nested lib/xevd/ subdir. pkg_install corrects that (see below).
pkg_configure() {
  _src="$DISTDIR/xevd-${PKG_VERSION}"
  mf_reset_dir "$_src/build"
  cd "$_src/build" || die "Failed to cd to xevd build dir"
  mf_cmake -DBUILD_SHARED_LIBS=OFF ..
}

pkg_build() {
  cd "$DISTDIR/xevd-${PKG_VERSION}/build" || die "Failed to cd to xevd build dir"
  default_build
}

pkg_install() {
  cd "$DISTDIR/xevd-${PKG_VERSION}/build" || die "Failed to cd to xevd build dir"
  default_install
  # This is a static build, but upstream's install ships the shared lib and
  # puts the static archive in a nested lib/xevd/ subdir that mediaforge's
  # installer (flat lib/*.a glob) never copies. Install a flat libxevd.a so
  # FFmpeg's --static link of -lxevd resolves it, drop the shared lib, and
  # remove the redundant nested archive so it doesn't linger in the workspace.
  #
  # The copy goes to the STAGE and the two rm to the LIVE prefix, and the split
  # is not cosmetic: default_install above has already merged and reset, so the
  # rm act on files that are in the prefix, while a copy written there too would
  # be past the stage and absent from the manifest -- which is what left
  # lib/libxevd.a unrecorded while its stamp read `verified` (GH-68).
  _dest=$(mf_dest_prefix)
  mf_dest_mkdir lib
  cp src_main/libxevd.a "$_dest/lib/libxevd.a" \
    || die "xevd static lib (src_main/libxevd.a) not found"
  rm -f "$PREFIX/lib/libxevd.so" "$PREFIX/lib/libxevd.so".*
  rm -rf "$PREFIX/lib/xevd"
}

# xevd is C++ but its pkgconfig omits -lstdc++ for static linking.
pkg_post_install() {
  mf_pc_add_stdcxx xevd
}
