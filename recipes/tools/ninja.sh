# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# ninja — small build backend invoked by meson. Built from source (via the
# bundled cmake, ordered before this recipe) so the host's ninja is never used.
# Apache-2.0. ninja's CMakeLists `install(TARGETS ninja)` drops the binary into
# $PREFIX/bin; building it via cmake (not configure.py) avoids a python
# dependency for ninja itself.
PKG_NAME="ninja"
PKG_VERSION="${PKG_VERSION_NINJA:-v1.13.2}"
PKG_GITHUB_REPO="ninja-build/ninja"
PKG_URL="https://github.com/ninja-build/ninja/archive/refs/tags/${PKG_VERSION}.tar.gz"
PKG_FILENAME="ninja-${PKG_VERSION}.tar.gz"
PKG_CMAKE=true
PKG_CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF"
