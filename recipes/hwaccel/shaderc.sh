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

pkg_prepare() {
  patch -p1 < "$SCRIPT_DIR/patches/shaderc-util-install.patch" 2>/dev/null || true
  run python3 utils/git-sync-deps
}
pkg_configure() {
  run cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON -DSHADERC_SKIP_EXECUTABLES=ON \
    -DSHADERC_ENABLE_WERROR_COMPILE=OFF -DSKIP_GLSLANG_INSTALL=ON \
    -DSKIP_SPIRV_TOOLS_INSTALL=ON -DSPIRV_HEADERS_SKIP_INSTALL=ON \
    -DBUILD_SHARED_LIBS=OFF .
}
pkg_post_install() {
  # FFmpeg probes pkg-config name "shaderc" but shaderc.pc -> -lshaderc_shared.
  # shaderc_static.pc -> -lshaderc -lshaderc_util (static). Make it the one FFmpeg finds.
  _src="$PREFIX/lib/pkgconfig/shaderc_static.pc"
  [ -f "$_src" ] || die "shaderc: expected $_src after install (upstream .pc layout changed?)"
  mv "$_src" "$PREFIX/lib/pkgconfig/shaderc.pc"
}
