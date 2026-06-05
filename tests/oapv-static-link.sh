#!/bin/sh
# Regression guard: APV (openapv) is installed where downstream can static-link it.
#
# openapv's CMake installed liboapv.a into <prefix>/lib/oapv (a subdir) and
# pointed oapv.pc's Libs.private at <prefix>/lib/oapv. mediaforge's installer
# only copies lib/*.a (flat), so liboapv.a never reached the prefix and FFmpeg's
# libavcodec.pc inherited a dangling -L<prefix>/lib/oapv — a downstream static
# link failed with "library not found: oapv". patches/oapv-install-libdir.patch
# moves the archive to <prefix>/lib and points the .pc at ${libdir}.
#
# Usage: tests/oapv-static-link.sh [PREFIX]   (default: $TOPDIR/workspace)
# Exit 0 = OK, 1 = regression, 2 = skipped (APV not built).
set -u

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PREFIX=${1:-"$_here/../workspace"}
PREFIX=$(CDPATH='' cd -- "$PREFIX" && pwd)
_pcdir="$PREFIX/lib/pkgconfig"

if [ ! -f "$_pcdir/libavcodec.pc" ]; then
  echo "SKIP: $PREFIX has no libavcodec.pc (FFmpeg not built here)"; exit 2
fi
if ! grep -q -- '-loapv' "$_pcdir/libavcodec.pc"; then
  echo "SKIP: libavcodec.pc does not reference oapv (APV opt-out build)"; exit 2
fi

_fail=0

# 1) The archive is installed flat in lib/, not a lib/oapv subdir.
if [ -f "$PREFIX/lib/liboapv.a" ]; then
  echo "PASS: liboapv.a present in lib/"
else
  echo "FAIL: $PREFIX/lib/liboapv.a missing (still in lib/oapv?)"; _fail=1
fi

# 2) No .pc emits a lib/oapv subdir -L.
if grep -rn -- '/oapv ' "$_pcdir/oapv.pc" "$_pcdir/libavcodec.pc" 2>/dev/null | grep -q -- '-L'; then
  echo "FAIL: a .pc still emits a lib/oapv subdir -L:"
  grep -rn -- '-L[^ ]*/oapv' "$_pcdir/oapv.pc" "$_pcdir/libavcodec.pc" 2>/dev/null | sed 's/^/    /'
  _fail=1
else
  echo "PASS: no lib/oapv subdir -L in oapv.pc / libavcodec.pc"
fi

# 3) The acceptance: a trivial consumer static-links the whole FFmpeg clean.
_out=$(mktemp -d); trap 'rm -rf "$_out"' EXIT INT TERM
printf '#include <libavcodec/avcodec.h>\nint main(void){return (int)avcodec_version();}\n' > "$_out/t.c"
_ld=""
command -v mold >/dev/null 2>&1 && _ld="-fuse-ld=mold"
# shellcheck disable=SC2046
if gcc "$_out/t.c" $(PKG_CONFIG_LIBDIR="$_pcdir" pkg-config --static --cflags --libs \
     libavcodec libavformat libavfilter libavdevice libavutil) $_ld -o "$_out/t" 2>"$_out/err"; then
  echo "PASS: full-FFmpeg static link clean (LINK_OK)${_ld:+ [mold]}"
else
  echo "FAIL: downstream static link failed:"
  grep -iE 'library not found|undefined|cannot find' "$_out/err" | head -10 | sed 's/^/    /'
  _fail=1
fi

exit "$_fail"
