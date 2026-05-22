# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="cmake"
PKG_VERSION="${PKG_VERSION_CMAKE:-3.31.7}"
PKG_GITHUB_REPO="Kitware/CMake"
PKG_URL="https://github.com/Kitware/CMake/releases/download/v${PKG_VERSION}/cmake-${PKG_VERSION}.tar.gz"

pkg_configure() {
  CXXFLAGS="$CXXFLAGS -std=c++11"
  export CXXFLAGS
  run ./configure --prefix="$PREFIX" --parallel="$MJOBS" -- -DCMAKE_USE_OPENSSL=OFF
}
