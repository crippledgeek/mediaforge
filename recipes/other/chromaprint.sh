# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="chromaprint"
PKG_VERSION="${PKG_VERSION_CHROMAPRINT:-1.5.1}"
PKG_GITHUB_REPO="acoustid/chromaprint"
PKG_URL="https://github.com/acoustid/chromaprint/releases/download/v${PKG_VERSION}/chromaprint-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-chromaprint"
PKG_CMAKE=true
PKG_CMAKE_BUILD_TYPE="Release"
PKG_CMAKE_FLAGS="-DBUILD_TOOLS=OFF -DBUILD_TESTS=OFF -DFFT_LIB=kissfft"

# chromaprint is C++ but its pkgconfig omits -lstdc++ for static linking
pkg_post_install() {
  mf_pc_add_stdcxx libchromaprint
}
