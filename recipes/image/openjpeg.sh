PKG_NAME="openjpeg"
PKG_VERSION="${PKG_VERSION_OPENJPEG:-2.5.3}"
PKG_GITHUB_REPO="uclouvain/openjpeg"
PKG_URL="https://github.com/uclouvain/openjpeg/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="openjpeg-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libopenjpeg"
PKG_CMAKE=true
PKG_CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release -DBUILD_CODEC=OFF"
