PKG_NAME="cmake"
PKG_VERSION="${PKG_VERSION_CMAKE:-3.31.7}"
PKG_GITHUB_REPO="Kitware/CMake"
PKG_URL="https://github.com/Kitware/CMake/releases/download/v${PKG_VERSION}/cmake-${PKG_VERSION}.tar.gz"

pkg_configure() {
  CXXFLAGS="$CXXFLAGS -std=c++11"
  export CXXFLAGS
  execute ./configure --prefix="$WORKSPACE" --parallel="$MJOBS" -- -DCMAKE_USE_OPENSSL=OFF
}
