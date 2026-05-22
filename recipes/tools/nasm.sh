# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="nasm"
PKG_VERSION="${PKG_VERSION_NASM:-2.16.01}"
PKG_URL="https://www.nasm.us/pub/nasm/releasebuilds/${PKG_VERSION}/nasm-${PKG_VERSION}.tar.xz"
