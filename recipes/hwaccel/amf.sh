# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="amf"
PKG_VERSION="${PKG_VERSION_AMF:-1.5.0}"
PKG_GITHUB_REPO="GPUOpen-LibrariesAndSDKs/AMF"
# AMF ships headers as a separate release asset, but the asset's own naming
# has no derivable rule -- checked per pinned version via
# `gh api repos/GPUOpen-LibrariesAndSDKs/AMF/releases/tags/<v> --jq
# '.assets[].name'` on 2026-08-25:
#   1.4.32 published no headers asset at all -- only source is the
#     auto-generated `archive/refs/tags/v1.4.32.tar.gz`. GitHub's byte-
#     stability commitment for those archives expired Feb 2024 and was never
#     renewed, so this is the one digest in amf.hash pinned against an
#     artifact upstream does not guarantee won't change; it is the only
#     option since no asset was ever published for this version.
#   1.4.33 -> AMF-headers-v1.4.33.tar.gz
#   1.4.34 -> AMF-headers.tar.gz (unversioned)
#   1.5.0  -> AMF-headers-v1.5.0.tar.gz
case "$PKG_VERSION" in
  1.4.32)
    PKG_URL="https://github.com/GPUOpen-LibrariesAndSDKs/AMF/archive/refs/tags/v${PKG_VERSION}.tar.gz"
    PKG_FILENAME="AMF-src-v${PKG_VERSION}.tar.gz"
    ;;
  1.4.34)
    PKG_URL="https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/download/v${PKG_VERSION}/AMF-headers.tar.gz"
    PKG_FILENAME="AMF-headers-v${PKG_VERSION}.tar.gz"
    ;;
  *)
    PKG_URL="https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/download/v${PKG_VERSION}/AMF-headers-v${PKG_VERSION}.tar.gz"
    PKG_FILENAME="AMF-headers-v${PKG_VERSION}.tar.gz"
    ;;
esac
PKG_FFMPEG_OPT="--enable-amf"
PKG_LINUX_ONLY=true

pkg_configure() { :; }
pkg_build() { :; }

# The header tree's root, post fetch()'s --strip-components 1, differs by
# version (see the PKG_URL case above for what each ships): 1.5.0 nests under
# AMF/, 1.4.33 and 1.4.34 land bare at the root despite different asset
# names, and 1.4.32's source-archive fallback nests under amf/public/include/.
# Probed against each of the four pinned versions' real tarballs during task
# 7b rather than assumed.
#
# The copies go to mf_dest_prefix, not $PREFIX: a shell cp writes past the
# stage (GH-68). The rm still aims at the LIVE prefix, and has to -- it is
# there to drop headers a previous version installed and this one does not,
# and the merge only ever adds.
pkg_install() {
  _dest=$(mf_dest_prefix)
  mf_remove_tree "$PREFIX/include/AMF"
  mf_dest_mkdir include/AMF
  if [ -d AMF/components ] && [ -d AMF/core ]; then
    run cp -r AMF/components AMF/core "$_dest/include/AMF/"
  elif [ -d components ] && [ -d core ]; then
    run cp -r components core "$_dest/include/AMF/"
  elif [ -d amf/public/include/components ] && [ -d amf/public/include/core ]; then
    run cp -r amf/public/include/components amf/public/include/core "$_dest/include/AMF/"
  else
    die "amf: none of the known header layouts found in $(pwd) — upstream changed the archive shape again"
  fi
}
