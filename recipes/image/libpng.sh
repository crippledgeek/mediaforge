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
  # Passed on the configure line rather than exported, which is the shape
  # nettle and gnutls already used for the same two variables. The exports were
  # why lib/framework.sh has to save and restore CPPFLAGS around every recipe:
  # an exported value outlives the recipe that set it.
  run ./configure --prefix="$PREFIX" --disable-shared --enable-static \
    CPPFLAGS="$(mf_cppflags)" LDFLAGS="$LDFLAGS"
}
