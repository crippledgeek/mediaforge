# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="libressl"
PKG_VERSION="${PKG_VERSION_LIBRESSL:-4.3.2}"
# Upstream publishes GitHub releases with v-prefixed tags, which
# _strip_tag_prefix already normalises. Without this, lib/updates.sh:72 takes the
# no-repo branch and reports "(not on GitHub)" instead of querying — which is how
# the previous 4.0.0 pin went 22 months and five releases stale without
# check-updates ever saying so. The tarball still comes from cdn.openbsd.org;
# this is for version discovery only.
PKG_GITHUB_REPO="libressl/portable"
PKG_URL="https://cdn.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${PKG_VERSION}.tar.gz"
PKG_FILENAME="libressl-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libtls"
PKG_MUTEX_GROUP="tls"

pkg_prepare() {
  # LibreSSL's install-exec-hook writes cert.pem/openssl.cnf/x509v3.cnf into
  # @OPENSSLDIR@, ignoring --prefix, and default_install runs a bare
  # `make install` with no DESTDIR to redirect it. With a host openssldir that
  # fails outright as a user and overwrites the host trust store as root — the
  # upstream no-overwrite guard is defeated by a `$i`/`$$i` typo. Removing the
  # hook is what makes --openssldir safe to point anywhere.
  # --fuzz=0 so a future tarball that drifts fails loudly instead of mis-applying.
  if ! patch -p1 -f --fuzz=0 < "$SCRIPT_DIR/patches/libressl-no-openssldir-install.patch"; then
    patch -p1 -R --fuzz=0 --dry-run < "$SCRIPT_DIR/patches/libressl-no-openssldir-install.patch" >/dev/null 2>&1 \
      || die "libressl-no-openssldir-install.patch failed to apply and is not already applied"
  fi
}

pkg_configure() {
  # Resolved here, in the phase that uses it. resolve_openssldir is a pure
  # function of --openssldir, the candidate list and this fallback, so every
  # caller that asks the same question gets the same answer without a recorded
  # value to keep in sync — which is what the earlier state-file design existed
  # to do, and where all of its defects came from.
  resolve_openssldir "$PREFIX/etc/ssl"

  # --with-pic: NOT because the objects would otherwise lack -fPIC. mediaforge.sh
  # exports `CFLAGS="$CFLAGS -fPIC"` for every recipe unconditionally
  # (mediaforge.sh:251-257), so they already get it and these archives already
  # linked into libavcodec/libavformat correctly on develop.
  #
  # What the flag adds is libtool's own -DPIC on the objects it compiles, which
  # LibreSSL's C and perlasm paths read to select position-independent
  # constructs. Passing it makes that explicit and independent of the global
  # export, rather than leaving this recipe silently reliant on a CFLAGS
  # assignment several files away.
  #
  # NOT passed, deliberately:
  #   --disable-asm  upstream already force-disables asm per-arch where it is
  #                  unsafe (configure.ac:82-84, i?86/mips/mips64) and gates elf
  #                  x86_64 on enable_asm != no (:126). Neither FreeBSD's port
  #                  nor Alpine's APKBUILD passes it. Measured on 4.3.2: static
  #                  -fPIC builds clean with asm on and libcrypto.a carries
  #                  aesni_encrypt / sha256_block_data_order.
  #   --enable-libtls-only  it would stop installing libssl/libcrypto, which
  #                  recipes/other/srt.sh:16 and librtmp.sh:31 consume through
  #                  the OpenSSL API rather than through libtls.
  #
  run ./configure --prefix="$PREFIX" \
    --with-openssldir="$OPENSSLDIR_RESOLVED" \
    --disable-shared --enable-static \
    --with-pic \
    --disable-tests
}

pkg_post_install() {
  if [ ! -f "$PREFIX/lib/pkgconfig/libtls.pc" ]; then
    warn "libressl: libtls.pc not found at $PREFIX/lib/pkgconfig/libtls.pc"
  fi

  resolve_openssldir "$PREFIX/etc/ssl"
  _libressl_openssldir="$OPENSSLDIR_RESOLVED"

  # The install hook that used to place this bundle is patched out, so mediaforge
  # stages it here instead — same file, chosen location.
  #
  # UNCONDITIONALLY, and always at $PREFIX/etc/ssl rather than at the baked path.
  # Two reasons. It is this package's own file and $PREFIX is the tree the build
  # already owns, so there is no guard to get wrong and no way to write outside
  # the prefix — the earlier form tested the baked path against "$PREFIX"/* with
  # a glob, which answered a filesystem question with a lexical one and would
  # have followed a symlink out of the prefix. And lib/install.sh cannot deliver
  # a bundle it does not have: when the baked path is under the INSTALL prefix
  # (the documented way to get verification working after install) nothing exists
  # at that path yet at build time, so staging must not be conditional on it.
  run mkdir -p "$PREFIX/etc/ssl"
  run cp cert.pem "$PREFIX/etc/ssl/cert.pem"

  # A baked path with nothing behind it fails CLOSED at handshake time with no
  # useful diagnostic — libtls has no SSL_CERT_FILE to fall back on — so say so
  # here rather than leaving it to be discovered at runtime. Not an error: the
  # installer places the bundle when the baked path lies under the install
  # prefix, which is the recommended workflow.
  if [ ! -f "$_libressl_openssldir/cert.pem" ]; then
    log "libressl: baked trust store is $_libressl_openssldir/cert.pem, which does"
    log "  not exist yet. 'install' places it there if that path is inside the"
    log "  install prefix; otherwise https:// needs -ca_file."
  fi
}
