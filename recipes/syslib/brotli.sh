# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="brotli"
PKG_VERSION="${PKG_VERSION_BROTLI:-1.2.0}"
PKG_GITHUB_REPO="google/brotli"
PKG_URL="https://github.com/google/brotli/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_FILENAME="brotli-${PKG_VERSION}.tar.gz"
PKG_CMAKE=true
PKG_CMAKE_FLAGS="\
  -DBROTLI_DISABLE_TESTS=On \
  -DBROTLI_BUNDLED_MODE=Off \
  -DCMAKE_POSITION_INDEPENDENT_CODE=On"
# Transitive utility — drops all three brotli .pc files.
PKG_TRANSITIVE_UTIL=true
PKG_PC_FILES="libbrotlicommon libbrotlidec libbrotlienc"

# brotli's cmake config builds both shared and static. We only want static —
# remove the .so files post-install so consumers' static probes pick the .a.
pkg_post_install() {
  # The 2>/dev/null this replaces was the strongest form of the defect: the
  # status dropped AND the reason for the failure discarded. An unmatched glob is
  # not a failure -- rm -f ignores an absent path -- so nothing is lost by
  # letting the errors through.
  mf_remove_file "$PREFIX/lib/libbrotlicommon.so"* \
        "$PREFIX/lib/libbrotlidec.so"* \
        "$PREFIX/lib/libbrotlienc.so"*
}
