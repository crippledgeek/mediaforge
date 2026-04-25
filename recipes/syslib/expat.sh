PKG_NAME="expat"
PKG_VERSION="${PKG_VERSION_EXPAT:-2.8.0}"
PKG_GITHUB_REPO="libexpat/libexpat"
# Upstream tag is R_X_Y_Z but tarball is expat-X.Y.Z
_expat_tag=$(printf 'R_%s' "$PKG_VERSION" | tr '.' '_')
PKG_URL="https://github.com/libexpat/libexpat/releases/download/${_expat_tag}/expat-${PKG_VERSION}.tar.bz2"
PKG_FILENAME="expat-${PKG_VERSION}.tar.bz2"
PKG_CMAKE=true
PKG_CMAKE_FLAGS="\
  -DEXPAT_SHARED_LIBS=Off \
  -DEXPAT_BUILD_TOOLS=Off \
  -DEXPAT_BUILD_EXAMPLES=Off \
  -DEXPAT_BUILD_TESTS=Off \
  -DEXPAT_BUILD_DOCS=Off"
