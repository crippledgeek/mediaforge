PKG_NAME="chromaprint"
PKG_VERSION="${PKG_VERSION_CHROMAPRINT:-1.5.1}"
PKG_GITHUB_REPO="acoustid/chromaprint"
PKG_URL="https://github.com/acoustid/chromaprint/releases/download/v${PKG_VERSION}/chromaprint-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-chromaprint"
PKG_CMAKE=true
PKG_CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release -DBUILD_TOOLS=OFF -DBUILD_TESTS=OFF -DFFT_LIB=kissfft"

# chromaprint is C++ but its pkgconfig omits -lstdc++ for static linking
pkg_post_install() {
  _pc="$PREFIX/lib/pkgconfig/libchromaprint.pc"
  awk '/^Libs:/ && !/-lstdc\+\+/ {$0 = $0 " -lstdc++"} {print}' "$_pc" > "$_pc.tmp" && mv "$_pc.tmp" "$_pc"
}
