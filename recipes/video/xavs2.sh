# shellcheck disable=SC2034
# PKG_* variables are consumed by lib/framework.sh after this recipe is sourced.
# AVS2 — AVS patent pool (devices charged; software free). GPL-2.0.
PKG_NAME="xavs2"
PKG_VERSION="${PKG_VERSION_LIBXAVS2:-1.4}"
PKG_GITHUB_REPO="pkuvcl/xavs2"
PKG_URL="https://github.com/pkuvcl/xavs2/archive/refs/tags/${PKG_VERSION}.tar.gz"
PKG_FILENAME="xavs2-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libxavs2"
PKG_GPL=true

# x264-style build under build/linux. The framework does NOT reset cwd between
# phases, so each phase cds to the absolute build dir (idempotent). The Makefile
# has no plain `install` target — install-lib-static installs libxavs2.a, the
# headers, and xavs2.pc (which FFmpeg's --enable-libxavs2 probes).
# xavs2 1.4 (2019) predates GCC 14, which promoted incompatible-pointer-types
# (and friends) from warnings to hard errors by default. Demote them back via
# --extra-cflags so the old C compiles on GCC 14/15/16.
_xavs2_compat="-Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration -Wno-error=int-conversion -Wno-error=implicit-int"
# xavs2's configure (x264-derived) adds -mpreferred-stack-boundary=5, which also
# makes GCC ASSUME every function is entered on a 32-byte-aligned stack. x264
# guards its public entry points with force_align_arg_pointer; xavs2 does not
# on xavs2_encoder_create -> xavs2_threadpool_init, and FFmpeg calls it with
# the ABI's 16-byte alignment. At -O0 (our --debug builds) GCC spills the
# __m256i local in xavs2_memzero_aligned_c_avx to a 32-byte stack slot with
# vmovdqa, so whether avcodec_open2 SIGSEGVs is a coin flip on the caller's
# frame layout (#102; the "unaligned heap buffer" reading there was wrong —
# dst was aligned in every reproduction, the faulting store is -0x38(%rsp)).
# -mincoming-stack-boundary=4 tells GCC the truth about the entry alignment,
# so it realigns (and $-32,%rsp) where a wider local needs it. Measured
# 2026-09-14: rdlp's recode_new_codecs test went from SIGSEGV to ok with only
# libxavs2.a rebuilt under this flag. configure strips a user-supplied
# -mpreferred-stack-boundary* (build/linux/configure) but passes this through.
# Its own variable: _xavs2_compat is warning demotion, this is an ABI fact.
_xavs2_stack_abi="-mincoming-stack-boundary=4"
pkg_configure() {
  cd "$DISTDIR/xavs2-${PKG_VERSION}/build/linux" || die "Failed to cd to xavs2 build/linux"
  run ./configure --prefix="$PREFIX" --disable-cli \
    --disable-shared --enable-static --enable-pic \
    --extra-cflags="$_xavs2_compat $_xavs2_stack_abi"
}

pkg_build() {
  cd "$DISTDIR/xavs2-${PKG_VERSION}/build/linux" || die "Failed to cd to xavs2 build/linux"
  run make -j "$MJOBS"
}

pkg_install() {
  cd "$DISTDIR/xavs2-${PKG_VERSION}/build/linux" || die "Failed to cd to xavs2 build/linux"
  run make install-lib-static
}
