PKG_NAME="frei0r"
PKG_VERSION="${PKG_VERSION_FREI0R:-2.3.3}"
PKG_GITHUB_REPO="dyne/frei0r"
PKG_URL="https://github.com/dyne/frei0r/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="frei0r-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-frei0r"
PKG_GPL=true
PKG_CMAKE=true
PKG_CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release -DWITHOUT_OPENCV=ON"
