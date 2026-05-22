# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="libpng"
PKG_VERSION="${PKG_VERSION_LIBPNG:-1.6.53}"
PKG_URL="https://sourceforge.net/projects/libpng/files/libpng16/${PKG_VERSION}/libpng-${PKG_VERSION}.tar.gz"
PKG_FILENAME="libpng-${PKG_VERSION}.tar.gz"
# Transitive utility — drops both libpng.pc and libpng16.pc.
PKG_TRANSITIVE_UTIL=true
PKG_PC_FILES="libpng libpng16"

pkg_configure() {
  export LDFLAGS="$LDFLAGS"
  # SC2153 false positive: $CFLAGS is set globally in mediaforge.sh before
  # recipes are sourced; the static analyzer cannot see the cross-file
  # assignment.
  # shellcheck disable=SC2153
  export CPPFLAGS="$CFLAGS"
  run ./configure --prefix="$PREFIX" --disable-shared --enable-static
}
