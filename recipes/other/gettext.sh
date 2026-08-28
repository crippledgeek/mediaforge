# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="gettext"
PKG_VERSION="${PKG_VERSION_GETTEXT:-0.22.5}"
PKG_URL="https://ftpmirror.gnu.org/gettext/gettext-${PKG_VERSION}.tar.gz"
PKG_NONFREE=true

# gettext 0.22.5 bundles gnulib with C23-incompatible code
PKG_C_STD="gnu11"
