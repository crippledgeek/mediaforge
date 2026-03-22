PKG_NAME="yasm"
PKG_VERSION="${PKG_VERSION_YASM:-1.3.0}"
PKG_GITHUB_REPO="yasm/yasm"
PKG_URL="https://github.com/yasm/yasm/releases/download/v${PKG_VERSION}/yasm-${PKG_VERSION}.tar.gz"

# yasm 1.3.0 uses "false"/"true" as enum constants in bitvect.h,
# which conflicts with C23 reserved keywords (GCC 15+ defaults to -std=gnu23)
pkg_prepare() {
  CFLAGS="$CFLAGS -std=gnu11"
  export CFLAGS
}
