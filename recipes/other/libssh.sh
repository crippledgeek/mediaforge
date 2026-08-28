# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="libssh"
PKG_VERSION="${PKG_VERSION_LIBSSH:-0.11.4}"
# libssh.org/files/<MAJ.MIN>/libssh-<ver>.tar.xz  (${PKG_VERSION%.*} = 0.11 from 0.11.4)
PKG_URL="https://www.libssh.org/files/${PKG_VERSION%.*}/libssh-${PKG_VERSION}.tar.xz"
PKG_FILENAME="libssh-${PKG_VERSION}.tar.xz"
PKG_CMAKE=true
# libssh has no gnutls backend; its OpenSSL backend + --enable-gpl FFmpeg = a
# nonfree (unredistributable) binary. Build against mediaforge's mbedtls, which
# exists only under --tls=mbedtls and is built earlier (recipes/crypto/mbedtls.sh)
# than other/. Probe for its static crypto lib at source-time like vaapi probes
# libva; skip cleanly (logged, not silent) otherwise.
# libssh's crypto backend is exclusive: if(WITH_GCRYPT) elseif(WITH_MBEDTLS)
# else(OpenSSL). With WITH_MBEDTLS=ON + WITH_GCRYPT=OFF, OpenSSL is never probed,
# so no WITH_OPENSSL flag is needed (libssh defines none). MBEDTLS_ROOT_DIR is
# the HINT consumed by libssh's FindMbedTLS.cmake to locate libmbedcrypto.a.
if [ -f "$PREFIX/lib/libmbedcrypto.a" ]; then
  PKG_FFMPEG_OPT="--enable-libssh"
  PKG_CMAKE_BUILD_TYPE="Release"
  PKG_CMAKE_FLAGS="-DBUILD_SHARED_LIBS=OFF -DWITH_MBEDTLS=ON -DWITH_GCRYPT=OFF -DWITH_SERVER=OFF -DWITH_EXAMPLES=OFF -DUNIT_TESTING=OFF -DMBEDTLS_ROOT_DIR=$PREFIX"
else
  PKG_DISABLED=true
  PKG_FFMPEG_OPT=""
  log "Skipping libssh (needs mbedtls for a GPL-clean build; use --tls=mbedtls for SFTP)"
fi
