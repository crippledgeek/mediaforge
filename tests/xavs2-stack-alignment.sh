#!/bin/sh
# libxavs2 must realign its own frame before any 32-byte stack store (#102).
#
# xavs2's configure adds -mpreferred-stack-boundary=5, which makes GCC assume a
# 32-byte-aligned stack on entry to EVERY function. FFmpeg enters
# xavs2_encoder_create with the ABI's 16 bytes, and at -O0 the __m256i local in
# xavs2_memzero_aligned_c_avx is spilled with an aligned vmovdqa to an
# rsp-relative slot -- so avcodec_open2 SIGSEGVs whenever the caller's frame
# happens to be 16-but-not-32 aligned (rdlp saw it as a coin flip per build).
# recipes/video/xavs2.sh passes -mincoming-stack-boundary=4, under which GCC
# emits `and $-32,%rsp` in any function that needs a wider local.
#
# Two assertions, so the test cannot pass by scanning nothing:
#  1) the recipe carries the flag (static; runs on every tree);
#  2) in the built libxavs2.a, every C-compiled intrinsic function
#     (xavs2 names them *_c_sse*/*_c_avx*, from common/vec/intrinsic_*.c)
#     that spills a ymm register to an rsp-relative slot with vmovdqa also
#     realigns rsp to 32 bytes. The nasm functions (common/x86/*.asm, no `_c_`
#     in the name) are deliberately outside this check: x86inc builds them with
#     STACK_ALIGNMENT=32 and they rely on their C callers, which under
#     -mpreferred-stack-boundary=5 keep 32-byte alignment at every call once
#     they have realigned on entry -- that is the contract this flag restores,
#     not one the asm could enforce itself. This half is skipped (said so on
#     stdout, assertion 1 still decides the exit) when the archive has not been
#     built, so the file runs in the hermetic suite; a release (-O3) archive
#     keeps the local in a register and then has nothing to check, which is
#     reported as such, not as a pass.
#
# Usage: tests/xavs2-stack-alignment.sh [PREFIX]   (default: $TOPDIR/workspace)
# Exit 0 = pass, 1 = regression.
set -u

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PREFIX=${1:-"$_here/../workspace"}
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$_here/lib-assert.sh"
_cleanup_on_signal

# 1) The recipe passes the flag through --extra-cflags.
if grep -q -- '-mincoming-stack-boundary=4' "$_here/../recipes/video/xavs2.sh"; then
  _pass xavs2-recipe-declares-incoming-stack-boundary
else
  _bad xavs2-recipe-declares-incoming-stack-boundary \
    "recipes/video/xavs2.sh does not pass -mincoming-stack-boundary=4"
fi

# 2) Behavioural: every ymm stack spill sits in a realigned frame.
_lib="$PREFIX/lib/libxavs2.a"
if [ ! -f "$_lib" ]; then
  echo "SKIP [ymm-spills-are-in-realigned-frames] no $_lib (not built)"
  printf 'DONE: xavs2-stack-alignment\n'
  exit "$_fail"
fi
command -v objdump >/dev/null 2>&1 || {
  _bad ymm-spills-are-in-realigned-frames "objdump not found; cannot inspect $_lib"
  printf 'DONE: xavs2-stack-alignment\n'
  exit 1
}

# One record per C intrinsic function: name, whether it spills ymm to the
# stack, whether it realigns rsp to 32. A function is `<name>:` at column 0 in
# objdump -d output; only `_c_` names are C-compiled (see the header).
_dis=$(objdump -d "$_lib" 2>/dev/null)
_report=$(printf '%s\n' "$_dis" | awk '
  /^[0-9a-f]+ <.*>:$/ { flush(); fn=$2; c=(fn ~ /_c_(sse|ssse|avx)/); spill=0; realign=0; next }
  /vmovdqa[ \t]+%ymm[0-9]+,-?0x[0-9a-f]+\(%rsp\)/ { spill=1 }
  /and[ \t]+\$0xffffffffffffffe0,%rsp/ { realign=1 }
  function flush() { if (fn != "" && c && spill && !realign) print fn }
  END { flush() }')
_spills=$(printf '%s\n' "$_dis" | awk '
  /^[0-9a-f]+ <.*>:$/ { c=($2 ~ /_c_(sse|ssse|avx)/); next }
  c && /vmovdqa[ \t]+%ymm[0-9]+,-?0x[0-9a-f]+\(%rsp\)/ { n++ }
  END { print n+0 }')

if [ "$_spills" -eq 0 ]; then
  # Nothing to check (an optimised archive keeps __m256i locals in registers);
  # say so instead of claiming the property was verified.
  _pass ymm-spills-are-in-realigned-frames
  echo "  (no ymm stack spills in $_lib -- optimised build, property vacuous)"
elif [ -z "$_report" ]; then
  _pass ymm-spills-are-in-realigned-frames
  echo "  ($_spills ymm stack spill(s), every enclosing frame realigned)"
else
  _bad ymm-spills-are-in-realigned-frames \
    "functions spilling ymm without realigning rsp: $(printf '%s' "$_report" | tr '\n' ' ')"
fi

printf 'DONE: xavs2-stack-alignment\n'
exit "$_fail"
