#!/bin/sh
# Dry-run matrix: assert FFMPEG_CONFIGURE_OPTS and Skipping logs match
# expected per-group resolution outputs.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

_fail=0
_run() {
  _desc=$1; shift
  _expect=$1; shift
  _output=$("$@" --dry-run --yes 2>&1) || true
  if ! printf '%s' "$_output" | grep -qF -- "$_expect"; then
    printf 'FAIL [%s]: missing "%s"\n' "$_desc" "$_expect" >&2
    _fail=1
    return
  fi
  printf 'PASS [%s]\n' "$_desc"
}

_run_no() {
  _desc=$1; shift
  _forbidden=$1; shift
  _output=$("$@" --dry-run --yes 2>&1) || true
  if printf '%s' "$_output" | grep -qF -- "$_forbidden"; then
    printf 'FAIL [%s]: contained forbidden "%s"\n' "$_desc" "$_forbidden" >&2
    _fail=1
    return
  fi
  printf 'PASS [%s]\n' "$_desc"
}

# Default choices logged
_run "default tls=gnutls"   "tls=gnutls"   ./mediaforge.sh build
_run "default aac=native"   "aac=native"   ./mediaforge.sh build
_run "default h264=x264"    "h264=x264"    ./mediaforge.sh build
_run "default h265=x265"    "h265=x265"    ./mediaforge.sh build
_run "default av1-enc=svtav1" "av1-enc=svtav1" ./mediaforge.sh build

# Explicit TLS backends are accepted and logged
_run "tls=openssl logged"   "tls=openssl"  ./mediaforge.sh build --tls=openssl
_run "tls=mbedtls logged"   "tls=mbedtls"  ./mediaforge.sh build --tls=mbedtls
_run "tls=libressl logged"  "tls=libressl" ./mediaforge.sh build --tls=libressl
_run "tls=none logged"      "tls=none"     ./mediaforge.sh build --tls=none

# Mutex companions disabled
_run "openssl disables gnutls" "Skipping gnutls (disabled via CLI)" \
  ./mediaforge.sh build --tls=openssl
_run "gnutls disables openssl" "Skipping openssl (disabled via CLI)" \
  ./mediaforge.sh build --tls=gnutls

# AAC default (native) skips fdk_aac in free builds
_run "aac=native skips fdk_aac" "Skipping fdk_aac (disabled via CLI)" \
  ./mediaforge.sh build

# --enable-nonfree implies aac=fdk_aac when user didn't pick (historical UX)
_run "nonfree implies aac=fdk_aac"  "aac=fdk_aac"  ./mediaforge.sh build --enable-nonfree

# Invalid enum is rejected
_output=$(./mediaforge.sh build --tls=bogus --dry-run --yes 2>&1) || true
if printf '%s' "$_output" | grep -q "Invalid --tls: bogus"; then
  printf 'PASS [tls=bogus rejected]\n'
else
  printf 'FAIL [tls=bogus rejected]: %s\n' "$_output" >&2
  _fail=1
fi

# Self-contradiction: --tls=gnutls --disable=gnutls
_output=$(./mediaforge.sh build --tls=gnutls --disable=gnutls --dry-run --yes 2>&1) || true
if printf '%s' "$_output" | grep -q "Contradiction"; then
  printf 'PASS [self-contradiction detected]\n'
else
  printf 'FAIL [self-contradiction detected]: %s\n' "$_output" >&2
  _fail=1
fi

# H264 mutex
_run "h264=openh264 disables x264" "Skipping x264 (disabled via CLI)" \
  ./mediaforge.sh build --h264=openh264
_run_no "h264=openh264 keeps openh264" "Skipping openh264 (disabled via CLI)" \
  ./mediaforge.sh build --h264=openh264

# H265 mutex
_run "h265=kvazaar disables x265" "Skipping x265 (disabled via CLI)" \
  ./mediaforge.sh build --h265=kvazaar

# AV1-enc mutex
_run "av1-enc=rav1e disables svtav1" "Skipping svtav1 (disabled via CLI)" \
  ./mediaforge.sh build --av1-enc=rav1e
_run "av1-enc=rav1e disables av1 (libaom)" "Skipping av1 (disabled via CLI)" \
  ./mediaforge.sh build --av1-enc=rav1e

# SPIR-V compiler mutex (glslang vs shaderc — interchangeable, FFmpeg forbids both)
_run "spirv default glslang"            "spirv=glslang"                        ./mediaforge.sh build
_run "spirv=shaderc disables glslang"   "Skipping glslang (disabled via CLI)"  ./mediaforge.sh build --spirv=shaderc
_run "spirv=glslang disables shaderc"   "Skipping shaderc (disabled via CLI)"  ./mediaforge.sh build --spirv=glslang
_run_no "spirv=shaderc no libglslang flag" "enable-libglslang"                 ./mediaforge.sh build --spirv=shaderc
_run_no "spirv=glslang no libshaderc flag" "enable-libshaderc"                 ./mediaforge.sh build

# libplacebo (Vulkan GPU post-processing). On by default; follows --spirv=;
# skipped under --enable-static (LDEXEFLAGS → no static libvulkan on Arch).
_run "libplacebo default on"            "--enable-libplacebo" ./mediaforge.sh build
_run_no "libplacebo off on static"      "--enable-libplacebo" ./mediaforge.sh build --enable-static
_run "libplacebo follows spirv=shaderc" "--enable-libplacebo" ./mediaforge.sh build --spirv=shaderc

# Additional video codecs — version-gated. Default no-profile build == 8.0.1,
# so all five flags appear; older profiles gate some out.
_run "uavs3d default on"        "--enable-libuavs3d" ./mediaforge.sh build
_run "vvenc on (default 8.x)"   "--enable-libvvenc"  ./mediaforge.sh build
_run "oapv on (default 8.x)"    "--enable-liboapv"   ./mediaforge.sh build
_run "xeve on (default 8.x)"    "--enable-libxeve"   ./mediaforge.sh build
_run_no "oapv OFF on 7.1"       "--enable-liboapv"   ./mediaforge.sh build --profile=7.1
_run_no "vvenc OFF on 7.0"      "--enable-libvvenc"  ./mediaforge.sh build --profile=7.0
_run_no "xeve OFF on 6.1"       "--enable-libxeve"   ./mediaforge.sh build --profile=6.1

# Free codec coverage — lcms2/aribcaption/vmaf ungated; qrencode >=7.0; lc3 >=7.1.
_run "lcms2 default on"        "--enable-lcms2"          ./mediaforge.sh build
_run "aribcaption default on"  "--enable-libaribcaption" ./mediaforge.sh build
_run "vmaf default on"         "--enable-libvmaf"        ./mediaforge.sh build
_run "qrencode on (8.x)"       "--enable-libqrencode"    ./mediaforge.sh build
_run "lc3 on (8.x)"            "--enable-liblc3"         ./mediaforge.sh build
_run_no "lc3 OFF on 7.0"       "--enable-liblc3"         ./mediaforge.sh build --profile=7.0
_run_no "qrencode OFF on 6.1"  "--enable-libqrencode"    ./mediaforge.sh build --profile=6.1

# harfbuzz drawtext shaping (ungated, all profiles) + quirc QR decode (>=7.0).
_run "harfbuzz flag on"     "--enable-libharfbuzz" ./mediaforge.sh build
_run "quirc on (8.x)"       "--enable-libquirc"    ./mediaforge.sh build
_run_no "quirc OFF on 6.1"  "--enable-libquirc"    ./mediaforge.sh build --profile=6.1

# GPL codec coverage — xavs2/davs2/libcdio are GPL (only with --enable-gpl).
#
# lcevc carries TWO gates, and this block used to account for only one of them.
# It is FFmpeg-version-gated (>=7.1, recipes/other/lcevc.sh:28) AND opt-in
# (PKG_DISABLED=true, :19 — V-Nova patent encumbrance, decode-only, and eight
# circular static archives that break a downstream single-pass link unless
# merged). The row below asserted that a DEFAULT 8.x build emits
# --enable-liblcevc-dec, which the version gate alone would imply but the
# opt-in gate forbids. Both were introduced in the same commit (beba26c), so
# the assertion never once passed — it contradicted the recipe it tested from
# the day it was written, and tests/lcevc-default-off.sh asserts the opposite.
_run "xavs2 on (gpl)"       "--enable-libxavs2"     ./mediaforge.sh build --enable-gpl
_run "davs2 on (gpl)"       "--enable-libdavs2"     ./mediaforge.sh build --enable-gpl
_run_no "xavs2 off (free)"  "--enable-libxavs2"     ./mediaforge.sh build
_run "libcdio on (gpl)"     "--enable-libcdio"      ./mediaforge.sh build --enable-gpl
# Only the OFF-by-default half lives here, paired with the 7.0 row below it.
# The opt-in half (--enable=lcevc emits the flag) belongs to
# tests/lcevc-default-off.sh, which owns that contract with a better oracle: it
# greps the assembled `$ ./configure` line specifically, where _run/_run_no grep
# the whole log — and that log mentions lcevc for other reasons. Asserting it
# here as well would also make this matrix Linux-only, since lcevc.sh sets
# PKG_LINUX_ONLY=true and check_guards (lib/framework.sh:140) skips it on macOS
# regardless of --enable=.
_run_no "lcevc off by default (8.x)" "--enable-liblcevc-dec" ./mediaforge.sh build
_run_no "lcevc OFF on 7.0"  "--enable-liblcevc-dec" ./mediaforge.sh build --profile=7.0

# DVD inputs — libdvdread/libdvdnav are GPL and FFmpeg-version-gated (>=7.0).
_run "dvdread on (gpl)"      "--enable-libdvdread" ./mediaforge.sh build --enable-gpl
_run "dvdnav on (gpl)"       "--enable-libdvdnav"  ./mediaforge.sh build --enable-gpl
_run_no "dvdnav off (free)"  "--enable-libdvdnav"  ./mediaforge.sh build
_run_no "dvdnav OFF on 6.1"  "--enable-libdvdnav"  ./mediaforge.sh build --enable-gpl --profile=6.1

# Protocol inputs — librabbitmq (AMQP, ungated) + libssh (SFTP, mbedtls-gated).
# In dry-run mbedtls isn't actually built, so $PREFIX/lib/libmbedcrypto.a never
# exists → libssh logs the skip in BOTH the default and --tls=mbedtls cases.
# The skip-log assertion is the meaningful one; --enable-libssh can't appear
# without a real mbedtls build. The --tls=mbedtls case just confirms acceptance.
_run "rabbitmq default on"        "--enable-librabbitmq" ./mediaforge.sh build
_run "libssh skipped w/o mbedtls" "Skipping libssh"      ./mediaforge.sh build
_run_no "no libssh flag in default dry-run" "--enable-libssh" ./mediaforge.sh build
_run "libssh selectable w/ mbedtls tls" "tls=mbedtls" ./mediaforge.sh build --tls=mbedtls

exit "$_fail"
