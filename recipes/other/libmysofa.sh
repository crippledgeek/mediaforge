PKG_NAME="libmysofa"
PKG_VERSION="${PKG_VERSION_LIBMYSOFA:-1.3.4}"
PKG_GITHUB_REPO="hoene/libmysofa"
PKG_URL="https://github.com/hoene/libmysofa/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="libmysofa-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libmysofa"
PKG_CMAKE=true
PKG_CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF"
