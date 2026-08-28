# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="libtool"
PKG_VERSION="${PKG_VERSION_LIBTOOL:-2.4.7}"
PKG_URL="https://ftpmirror.gnu.org/libtool/libtool-${PKG_VERSION}.tar.gz"

# libtool 2.4.7 bundles gnulib/autoconf macros incompatible with C23
PKG_C_STD="gnu11"
