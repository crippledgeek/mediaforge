# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# SPIR-V compiler (alt to glslang via --spirv=shaderc). Apache-2.0. Fetches glslang/SPIRV-Tools via git-sync-deps.
PKG_NAME="shaderc"
PKG_VERSION="${PKG_VERSION_LIBSHADERC:-2025.5}"
PKG_GITHUB_REPO="google/shaderc"
PKG_URL="https://github.com/google/shaderc/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="shaderc-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libshaderc"
PKG_MUTEX_GROUP="spirv"
PKG_REQUIRES_CMD="python3 git"
PKG_CMAKE=true
PKG_CMAKE_BUILD_TYPE="Release"

pkg_prepare() {
  if ! patch -p1 -f < "$SCRIPT_DIR/patches/shaderc-util-install.patch"; then
    patch -p1 -R --dry-run < "$SCRIPT_DIR/patches/shaderc-util-install.patch" >/dev/null 2>&1 \
      || die "shaderc-util-install.patch failed to apply and is not already applied"
  fi
  run python3 utils/git-sync-deps
}
pkg_configure() {
  mf_cmake \
    -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON -DSHADERC_SKIP_EXECUTABLES=ON \
    -DSHADERC_ENABLE_WERROR_COMPILE=OFF -DSKIP_GLSLANG_INSTALL=ON \
    -DSKIP_SPIRV_TOOLS_INSTALL=ON -DSPIRV_HEADERS_SKIP_INSTALL=ON \
    -DBUILD_SHARED_LIBS=OFF .
}
# FFmpeg probes pkg-config name "shaderc" but shaderc.pc -> -lshaderc_shared.
# shaderc_static.pc -> -lshaderc -lshaderc_util (static). Make it the one FFmpeg
# finds.
#
# Written as a staged copy plus a live delete rather than as an `mv` in the
# prefix, because a plain rename loses the file from the manifest entirely
# (GH-68): the stamp records what was STAGED, so it would name shaderc_static.pc
# -- which no longer exists, so the existence filter drops it -- while
# shaderc.pc, never staged, is never recorded. The delete is correct against the
# live prefix for the same reason it always was: default_install has already
# merged the file being replaced.
pkg_post_install() {
  _src="$PREFIX/lib/pkgconfig/shaderc_static.pc"
  [ -f "$_src" ] || die "shaderc: expected $_src after install (upstream .pc layout changed?)"
  _dest=$(mf_dest_prefix)
  mf_dest_mkdir lib/pkgconfig
  cp "$_src" "$_dest/lib/pkgconfig/shaderc.pc" \
    || die "shaderc: failed to stage shaderc.pc"
  mf_remove_file "$_src"
}
