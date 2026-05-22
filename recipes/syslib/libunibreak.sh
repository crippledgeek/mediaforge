# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="libunibreak"
PKG_VERSION="${PKG_VERSION_LIBUNIBREAK:-7.0}"
PKG_GITHUB_REPO="adah1972/libunibreak"
PKG_URL="https://github.com/adah1972/libunibreak/releases/download/libunibreak_$(printf '%s' "$PKG_VERSION" | tr '.' '_')/libunibreak-${PKG_VERSION}.tar.gz"
PKG_FILENAME="libunibreak-${PKG_VERSION}.tar.gz"
PKG_CONFIGURE_FLAGS="--disable-doxygen-doc"
