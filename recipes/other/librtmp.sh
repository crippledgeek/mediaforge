# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
PKG_NAME="librtmp"
PKG_VERSION="${PKG_VERSION_LIBRTMP:-2.6}"
# Pinned by COMMIT, not by the v2.6 tag. Two reasons, and the first is a bug
# this recipe used to have: every profile set PKG_VERSION_LIBRTMP to a commit
# SHA, which the old `--branch "v${PKG_VERSION}"` turned into the unresolvable
# ref `v<sha>`, so every `--profile=` build died here. The second is integrity:
# rtmpdump's v2.6 tag is a mutable server-side pointer, and this commit is the
# object it named on 2026-08-24.
PKG_COMMIT="${PKG_COMMIT_LIBRTMP:-138fdb258d9fc26f1843fd1b891180416c9dc575}"
PKG_URL=""
PKG_SKIP_EXTRACT=true
# Declared because pkg_prepare shells out to git; check_guards then reports a
# missing git against this package rather than letting the clone fail mid-phase.
PKG_REQUIRES_CMD="git"
PKG_FFMPEG_OPT="--enable-librtmp"

# librtmp has old C code incompatible with C23 (GCC 15+)
PKG_C_STD="gnu11"

pkg_prepare() {
  # No tarball available — fetch the pinned commit from the official git repo.
  fetch_git https://git.ffmpeg.org/rtmpdump.git "$DISTDIR/rtmpdump" "$PKG_COMMIT"
  cd "$DISTDIR/rtmpdump" || die "Failed to cd to rtmpdump"
}

pkg_configure() {
  :
}

# Resolve CRYPTO once and reuse in both build and install (same Makefile var
# must be set in both invocations or `make install` regenerates librtmp.pc
# with the default CRYPTO=OPENSSL).
_librtmp_crypto() {
  case "${TLS_BACKEND:-gnutls}" in
    openssl|libressl) printf 'OPENSSL\n' ;;
    gnutls)           printf 'GNUTLS\n'  ;;
    *)                printf '\n'        ;;  # mbedtls/none → no encryption
  esac
}

pkg_build() {
  cd librtmp || die "Failed to cd to librtmp"
  # Wipe any stale .o/.a/.pc from a previous CRYPTO= setting so the .pc gets
  # regenerated from librtmp.pc.in with the current REQ_$(CRYPTO).
  run make clean

  _crypto=$(_librtmp_crypto)
  case "$_crypto" in
    OPENSSL)
      run make SYS=posix prefix="$PREFIX" SHARED= CRYPTO="$_crypto" \
        XCFLAGS="$CFLAGS -I$PREFIX/include" XLDFLAGS="-L$PREFIX/lib" \
        LIB_OPENSSL="-lssl -lcrypto -lz -ldl -lpthread"
      ;;
    GNUTLS)
      run make SYS=posix prefix="$PREFIX" SHARED= CRYPTO="$_crypto" \
        XCFLAGS="$CFLAGS -I$PREFIX/include" XLDFLAGS="-L$PREFIX/lib"
      ;;
    *)
      run make SYS=posix prefix="$PREFIX" SHARED= CRYPTO= \
        XCFLAGS="$CFLAGS -I$PREFIX/include" XLDFLAGS="-L$PREFIX/lib"
      ;;
  esac
}

pkg_install() {
  # Pass the same CRYPTO so `install_base`'s librtmp.pc target substitutes
  # the matching REQ_$(CRYPTO) into Requires.
  # XCFLAGS on this run too: `install` depends on install_base, which depends on
  # librtmp.a, so the install target has a compilable prerequisite. It is
  # up to date by the time this runs and rebuilds nothing today -- but that is a
  # property of build order, not of the command, and the two invocations
  # disagreeing on flags is the shape giflib was just fixed for.
  _crypto=$(_librtmp_crypto)
  run make SYS=posix prefix="$PREFIX" SHARED= CRYPTO="$_crypto" \
    XCFLAGS="$CFLAGS -I$PREFIX/include" XLDFLAGS="-L$PREFIX/lib" install
}
