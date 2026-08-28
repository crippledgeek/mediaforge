# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="m4"
PKG_VERSION="${PKG_VERSION_M4:-1.4.19}"
PKG_URL="https://ftpmirror.gnu.org/gnu/m4/m4-${PKG_VERSION}.tar.gz"

# m4 1.4.19 bundles gnulib with _GL_ATTRIBUTE_NODISCARD that breaks under C23
PKG_C_STD="gnu11"
