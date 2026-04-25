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
  if ! printf '%s' "$_output" | grep -q "$_expect"; then
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
  if printf '%s' "$_output" | grep -q "$_forbidden"; then
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

exit "$_fail"
