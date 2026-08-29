#!/bin/sh
# Dry-run matrix: assert FFMPEG_CONFIGURE_OPTS and Skipping logs match
# expected per-group resolution outputs.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"
# shellcheck source=tests/lib-scratch.sh
. "$ROOT/tests/lib-scratch.sh"
_scratch_init "$ROOT"
trap '_scratch_cleanup' EXIT

# _run <assertion-name> <expected-text> <command...> asserts the dry-run says
# it; _run_no asserts it does not. Both append --dry-run --yes themselves.
_run() {
  _name=$1; shift
  _expect=$1; shift
  _output=$("$@" --dry-run --yes 2>&1) || true
  if ! printf '%s' "$_output" | grep -qF -- "$_expect"; then
    _bad "$_name" "missing \"$_expect\""
    return
  fi
  _pass "$_name"
}

_run_no() {
  _name=$1; shift
  _forbidden=$1; shift
  _output=$("$@" --dry-run --yes 2>&1) || true
  if printf '%s' "$_output" | grep -qF -- "$_forbidden"; then
    _bad "$_name" "contained forbidden \"$_forbidden\""
    return
  fi
  _pass "$_name"
}

# Default choices logged
_run default-tls-is-gnutls   "tls=gnutls"   _mf build
_run default-aac-is-native   "aac=native"   _mf build
_run default-h264-is-x264    "h264=x264"    _mf build
_run default-h265-is-x265    "h265=x265"    _mf build
_run default-av1-enc-is-svtav1 "av1-enc=svtav1" _mf build

# Explicit TLS backends are accepted and logged
_run tls-openssl-is-logged   "tls=openssl"  _mf build --tls=openssl
_run tls-mbedtls-is-logged   "tls=mbedtls"  _mf build --tls=mbedtls
_run tls-libressl-is-logged  "tls=libressl" _mf build --tls=libressl
_run tls-none-is-logged      "tls=none"     _mf build --tls=none

# Mutex companions disabled
_run tls-openssl-disables-gnutls "Skipping gnutls (disabled via CLI)" \
  _mf build --tls=openssl
_run tls-gnutls-disables-openssl "Skipping openssl (disabled via CLI)" \
  _mf build --tls=gnutls

# AAC default (native) skips fdk_aac in free builds
_run aac-native-skips-fdk-aac "Skipping fdk_aac (disabled via CLI)" \
  _mf build

# --enable-nonfree implies aac=fdk_aac when user didn't pick (historical UX)
_run nonfree-implies-aac-fdk  "aac=fdk_aac"  _mf build --enable-nonfree

# Invalid enum is rejected
_output=$(_mf build --tls=bogus --dry-run --yes 2>&1) || true
if printf '%s' "$_output" | grep -q "Invalid --tls: bogus"; then
  _pass tls-bogus-value-rejected
else
  _bad tls-bogus-value-rejected "$_output"
fi

# Self-contradiction: --tls=gnutls --disable=gnutls
_output=$(_mf build --tls=gnutls --disable=gnutls --dry-run --yes 2>&1) || true
if printf '%s' "$_output" | grep -q "Contradiction"; then
  _pass self-contradicting-tls-and-disable-detected
else
  _bad self-contradicting-tls-and-disable-detected "$_output"
fi

# Invalid --flite-audio is rejected (#19: was validated only inside two
# recipes, neither reachable under --dry-run, so this used to exit 0).
_output=$(_mf build --flite-audio=bogus --dry-run --yes 2>&1) || true
if printf '%s' "$_output" | grep -q "Invalid --flite-audio: bogus"; then
  _pass flite-audio-bogus-value-rejected
else
  _bad flite-audio-bogus-value-rejected "$_output"
fi

# Valid non-default --flite-audio is accepted: reaches the dry-run summary
# rather than dying in resolve_choices.
_run flite-audio-alsa-reaches-the-summary       "Would build FFmpeg" _mf build --flite-audio=alsa
_run_no flite-audio-alsa-not-rejected "Invalid --flite-audio" _mf build --flite-audio=alsa

# Default --flite-audio=none is accepted -- the value every ordinary build
# uses, so a regression here would break every build, not a rare invocation.
_run default-flite-audio-reaches-the-summary       "Would build FFmpeg" _mf build
_run_no default-flite-audio-not-rejected "Invalid --flite-audio" _mf build

# H264 mutex
_run h264-openh264-disables-x264 "Skipping x264 (disabled via CLI)" \
  _mf build --h264=openh264
_run_no h264-openh264-keeps-itself "Skipping openh264 (disabled via CLI)" \
  _mf build --h264=openh264

# H265 mutex
_run h265-kvazaar-disables-x265 "Skipping x265 (disabled via CLI)" \
  _mf build --h265=kvazaar

# AV1-enc mutex
_run av1-enc-rav1e-disables-svtav1 "Skipping svtav1 (disabled via CLI)" \
  _mf build --av1-enc=rav1e
_run av1-enc-rav1e-disables-libaom "Skipping av1 (disabled via CLI)" \
  _mf build --av1-enc=rav1e

# SPIR-V compiler mutex (glslang vs shaderc — interchangeable, FFmpeg forbids both)
_run default-spirv-is-glslang            "spirv=glslang"                        _mf build
_run spirv-shaderc-disables-glslang   "Skipping glslang (disabled via CLI)"  _mf build --spirv=shaderc
_run spirv-glslang-disables-shaderc   "Skipping shaderc (disabled via CLI)"  _mf build --spirv=glslang
_run_no spirv-shaderc-emits-no-glslang-flag "enable-libglslang"                 _mf build --spirv=shaderc
_run_no spirv-glslang-emits-no-shaderc-flag "enable-libshaderc"                 _mf build

# libplacebo (Vulkan GPU post-processing). On by default; follows --spirv=;
# skipped under --enable-static (LDEXEFLAGS → no static libvulkan on Arch).
_run libplacebo-on-by-default            "--enable-libplacebo" _mf build
_run_no libplacebo-off-under-enable-static      "--enable-libplacebo" _mf build --enable-static
_run libplacebo-follows-spirv-shaderc "--enable-libplacebo" _mf build --spirv=shaderc

# Additional video codecs — version-gated. Default no-profile build == 8.0.1,
# so all five flags appear; older profiles gate some out.
_run uavs3d-on-by-default        "--enable-libuavs3d" _mf build
_run vvenc-on-for-8x   "--enable-libvvenc"  _mf build
_run oapv-on-for-8x    "--enable-liboapv"   _mf build
_run xeve-on-for-8x    "--enable-libxeve"   _mf build
_run_no oapv-off-for-7.1       "--enable-liboapv"   _mf build --profile=7.1
_run_no vvenc-off-for-7.0      "--enable-libvvenc"  _mf build --profile=7.0
_run_no xeve-off-for-6.1       "--enable-libxeve"   _mf build --profile=6.1

# Free codec coverage — lcms2/aribcaption/vmaf ungated; qrencode >=7.0; lc3 >=7.1.
_run lcms2-on-by-default        "--enable-lcms2"          _mf build
_run aribcaption-on-by-default  "--enable-libaribcaption" _mf build
_run vmaf-on-by-default         "--enable-libvmaf"        _mf build
_run qrencode-on-for-8x       "--enable-libqrencode"    _mf build
_run lc3-on-for-8x            "--enable-liblc3"         _mf build
_run_no lc3-off-for-7.0       "--enable-liblc3"         _mf build --profile=7.0
_run_no qrencode-off-for-6.1  "--enable-libqrencode"    _mf build --profile=6.1

# harfbuzz drawtext shaping (ungated, all profiles) + quirc QR decode (>=7.0).
_run harfbuzz-on-by-default     "--enable-libharfbuzz" _mf build
_run quirc-on-for-8x       "--enable-libquirc"    _mf build
_run_no quirc-off-for-6.1  "--enable-libquirc"    _mf build --profile=6.1

# GPL codec coverage — xavs2/davs2/libcdio are GPL (only with --enable-gpl).
#
# lcevc carries TWO gates, and this block used to account for only one of them.
# It is FFmpeg-version-gated (recipes/other/lcevc.sh guards PKG_FFMPEG_OPT with
# `ffmpeg_version_ge 7.1`) AND opt-in (the same file's PKG_DISABLED=true —
# V-Nova patent encumbrance, decode-only, and circular static archives that
# break a downstream single-pass link unless
# merged). The row below asserted that a DEFAULT 8.x build emits
# --enable-liblcevc-dec, which the version gate alone would imply but the
# opt-in gate forbids. Both were introduced in the same commit (beba26c), so
# the assertion never once passed — it contradicted the recipe it tested from
# the day it was written, and tests/lcevc-default-off.sh asserts the opposite.
_run xavs2-on-under-gpl       "--enable-libxavs2"     _mf build --enable-gpl
_run davs2-on-under-gpl       "--enable-libdavs2"     _mf build --enable-gpl
_run_no xavs2-off-in-a-free-build  "--enable-libxavs2"     _mf build
_run libcdio-on-under-gpl     "--enable-libcdio"      _mf build --enable-gpl
# Only the OFF-by-default half lives here, paired with the 7.0 row below it.
# The opt-in half (--enable=lcevc emits the flag) belongs to
# tests/lcevc-default-off.sh, which owns that contract with a better oracle: it
# greps the `Would configure FFmpeg with:` line specifically, where _run/_run_no grep
# the whole log — and that log mentions lcevc for other reasons. Asserting it
# here as well would also make this matrix Linux-only, since lcevc.sh sets
# PKG_LINUX_ONLY=true and check_guards (lib/framework.sh) skips it on macOS
# regardless of --enable=.
_run_no lcevc-off-by-default-on-8x "--enable-liblcevc-dec" _mf build
_run_no lcevc-off-for-7.0  "--enable-liblcevc-dec" _mf build --profile=7.0

# DVD inputs — libdvdread/libdvdnav are GPL and FFmpeg-version-gated (>=7.0).
_run dvdread-on-under-gpl      "--enable-libdvdread" _mf build --enable-gpl
_run dvdnav-on-under-gpl       "--enable-libdvdnav"  _mf build --enable-gpl
_run_no dvdnav-off-in-a-free-build  "--enable-libdvdnav"  _mf build
_run_no dvdnav-off-for-6.1  "--enable-libdvdnav"  _mf build --enable-gpl --profile=6.1

# Protocol inputs — librabbitmq (AMQP, ungated) + libssh (SFTP, mbedtls-gated).
# In dry-run mbedtls isn't actually built, so $PREFIX/lib/libmbedcrypto.a never
# exists → libssh logs the skip in BOTH the default and --tls=mbedtls cases.
# The skip-log assertion is the meaningful one; --enable-libssh can't appear
# without a real mbedtls build. There is no --tls=mbedtls row here: it would be
# byte-identical to tls-mbedtls-is-logged above, and naming that duplicate for
# libssh would claim an observation the row does not make.
_run rabbitmq-on-by-default        "--enable-librabbitmq" _mf build
_run libssh-skipped-without-mbedtls "Skipping libssh"      _mf build
_run_no default-build-emits-no-libssh-flag "--enable-libssh" _mf build

# --dry-run must not fetch, extract, build or install FFmpeg.
# recipes/ffmpeg.sh is sourced directly by cmd_build rather than through
# run_recipe(), so run_recipe's own DRY_RUN short-circuit never reached it:
# a dry run downloaded and re-extracted the FFmpeg tarball, then fell through
# toward do_install, which has no dry-run guard of its own.
#
# fetch() logs "Extracted " only after a real tar-extract succeeds, so its
# presence is proof the recipe ran despite --dry-run.
_run    dry-run-logs-would-build-ffmpeg "Would build FFmpeg" _mf build
_run_no dry-run-extracts-nothing        "Extracted "         _mf build

exit "$_fail"
