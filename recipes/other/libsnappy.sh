PKG_NAME="libsnappy"
PKG_VERSION="${PKG_VERSION_LIBSNAPPY:-1.2.1}"
PKG_GITHUB_REPO="google/snappy"
PKG_URL="https://github.com/google/snappy/archive/refs/tags/${PKG_VERSION}.tar.gz"
PKG_FILENAME="snappy-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libsnappy"
PKG_CMAKE=true
PKG_CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release -DSNAPPY_BUILD_TESTS=OFF -DSNAPPY_BUILD_BENCHMARKS=OFF"
