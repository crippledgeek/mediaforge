# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="openssl"
PKG_VERSION="${PKG_VERSION_OPENSSL:-3.5.4}"
PKG_GITHUB_REPO="openssl/openssl"
PKG_URL="https://github.com/openssl/openssl/archive/refs/tags/openssl-${PKG_VERSION}.tar.gz"
PKG_FILENAME="openssl-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-openssl"
PKG_MUTEX_GROUP="tls"

pkg_configure() {
  # --openssldir is the compiled-in trust store: OpenSSL resolves
  # SSL_CTX_set_default_verify_paths() (which FFmpeg's backend calls,
  # libavformat/tls_openssl.c:740) through X509_CERT_FILE/X509_CERT_DIR derived
  # from it.
  #
  # NOTE this is a behaviour change: resolve_openssldir probes the host FIRST,
  # so on a host with a cert.pem (Arch, Fedora/RHEL, Homebrew) this arm now
  # bakes the HOST directory where it previously always baked $PREFIX. That is
  # deliberate — two TLS arms defaulting differently is the inconsistency
  # issue #18 was about — but it is not "as before".
  #
  # When the probe MISSES (Debian/Ubuntu ship no cert.pem) this falls back to
  # $PREFIX, which ships no certificates — so that case still means "-ca_file or
  # SSL_CERT_FILE required", unlike the libressl arm which stages a real bundle
  # into its own fallback. This arm gets away without one because OpenSSL
  # honours SSL_CERT_FILE at runtime; libtls has no environment override at all.
  #
  # Resolved here rather than recorded for other phases to read. The fallback is
  # $PREFIX, not $PREFIX/etc/ssl, because that is where OpenSSL expects its own
  # tree beneath the value.
  resolve_openssldir "$OPENSSLDIR" "$PREFIX"

  run ./Configure --prefix="$PREFIX" --openssldir="$OPENSSLDIR_RESOLVED" --libdir="lib" \
    --with-zlib-include="$PREFIX/include/" --with-zlib-lib="$PREFIX/lib" \
    no-shared zlib
}

pkg_install() {
  # install_sw, NOT install, and that is now load-bearing rather than merely
  # lean. Plain `make install` also runs install_ssldirs, which writes certs/,
  # private/ and openssl.cnf.dist into $(DESTDIR)$(OPENSSLDIR) — and mediaforge
  # sets no DESTDIR. Now that OPENSSLDIR can resolve to a HOST directory, that
  # would write into the host's /etc/ssl: exactly the hazard
  # patches/libressl-no-openssldir-install.patch removes on the libressl arm.
  # install_sw installs only the software, never the ssl dirs.
  run make install_sw
}
