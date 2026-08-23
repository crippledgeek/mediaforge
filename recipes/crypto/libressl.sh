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

pkg_configure() {
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
  # The compiled-in trust store (--with-openssldir) is deliberately NOT set here:
  # autotools' sysconfdir default bakes $PREFIX/etc/ssl/cert.pem and LibreSSL's
  # own install puts a real CA bundle there. That default is fragile — the path
  # is inside the build prefix, which `clean` removes and `install` does not copy
  # — and fixing it properly needs a CLI surface, an install-hook patch and
  # installer support. Tracked separately as #18; this recipe keeps the existing
  # behaviour rather than half-changing it.
  run ./configure --prefix="$PREFIX" \
    --disable-shared --enable-static \
    --with-pic \
    --disable-tests
}

pkg_post_install() {
  if [ ! -f "$PREFIX/lib/pkgconfig/libtls.pc" ]; then
    warn "libressl: libtls.pc not found at $PREFIX/lib/pkgconfig/libtls.pc"
  fi
}
