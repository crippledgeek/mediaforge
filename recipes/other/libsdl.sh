# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="libsdl"
PKG_VERSION="${PKG_VERSION_LIBSDL:-2.32.10}"
PKG_GITHUB_REPO="libsdl-org/SDL"
PKG_URL="https://github.com/libsdl-org/SDL/releases/download/release-${PKG_VERSION}/SDL2-${PKG_VERSION}.tar.gz"
