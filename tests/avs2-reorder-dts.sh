#!/bin/sh
# AVS2 reorder-DTS regression + decodability test (patches/ffmpeg-avs2-reorder.patch).
#
# Without AV_CODEC_PROP_REORDER on the AVS2 descriptor, libavcodec/encode.c
# clobbers libxavs2's B-frame decode-order DTS with dts=pts. In coding order the
# display PTS is non-monotonic (e.g. 0,8,4,2,1,3,...), so dts=pts is too -> a
# strict muxer rejects it ("non monotonically increasing dts") and the rdlp
# transcode pipeline fails. The patch preserves libxavs2's real DTS, which is
# strictly monotonic (-3,-2,-1,0,1,2,... ) with dts<=pts.
#
# The DTS check reads the encoder's REAL emitted timestamps via -debug_ts
# ("muxer <-" lines). It deliberately does NOT read DTS back from a Matroska
# file: Matroska stores no DTS, so ffprobe synthesises it on read and the values
# are not the encoder's output. The test also round-trips through libdavs2 to
# confirm the stream is decodable (8-bit only; libdavs2 cannot decode 10-bit).
#
# Usage: tests/avs2-reorder-dts.sh [PREFIX]   (default: $TOPDIR/workspace)
# Exit 0 = pass, 1 = regression, 2 = skipped (ffmpeg/libxavs2/libdavs2 absent).
set -u

_here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PREFIX=${1:-"$_here/../workspace"}
[ -x "$PREFIX/bin/ffmpeg" ] || { echo "SKIP: no $PREFIX/bin/ffmpeg (not built)"; exit 2; }
PREFIX=$(CDPATH='' cd -- "$PREFIX" && pwd)
FF="$PREFIX/bin/ffmpeg"; FP="$PREFIX/bin/ffprobe"

"$FF" -hide_banner -encoders 2>/dev/null | grep -q libxavs2 || { echo "SKIP: libxavs2 encoder absent"; exit 2; }
"$FF" -hide_banner -decoders 2>/dev/null | grep -q libdavs2 || { echo "SKIP: libdavs2 decoder absent"; exit 2; }

_out=$(mktemp -d)
trap 'rm -rf "$_out"' EXIT
_mkv="$_out/avs2.mkv"; _ts="$_out/ts.log"
_nframes=50
_src="testsrc=size=320x240:rate=25:duration=2"
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$_here/lib-assert.sh"
# After the source rather than beside the trap above, because the helper is
# defined here: the EXIT trap is registered before this file has one to call.
_cleanup_on_signal

# 1) Encode 50 frames to AVS2/MKV (8-bit, default bf=7 -> B-frame reorder), with
#    -debug_ts so the encoder's real emitted pts/dts are logged ("muxer <-").
if "$FF" -hide_banner -debug_ts -f lavfi -i "$_src" \
     -r 25 -pix_fmt yuv420p -c:v libxavs2 -y "$_mkv" >"$_ts" 2>&1; then
  _pass avs2-bframe-stream-encodes-and-muxes
else
  _bad avs2-bframe-stream-encodes-and-muxes \
    "$(_evidence 5 'monoton|error' < "$_ts")"
  exit 1
fi

# 2) The encoder's REAL emitted DTS must be strictly increasing, with dts<=pts.
#    (Pre-patch this is dts=pts in non-monotonic coding order -> fails here.)
grep 'muxer <-' "$_ts" | sed -nE 's/.*[^_]pts:(-?[0-9]+) .* dts:(-?[0-9]+) .*/\1 \2/p' > "$_out/pd.txt"
_n=$(grep -c . "$_out/pd.txt")
if [ "$_n" -lt 2 ]; then
  _bad emitted-dts-increasing-and-not-past-pts \
    "could not read emitted pts/dts from -debug_ts ($_n lines)"
elif awk 'NR==1{pd=$2-1} {if($2<=pd){print "    dts not increasing: "pd" -> "$2; bad=1}
            if($2>$1){print "    dts>pts: pts="$1" dts="$2; bad=1} pd=$2} END{exit bad+0}' "$_out/pd.txt"; then
  _pass emitted-dts-increasing-and-not-past-pts
else
  _bad emitted-dts-increasing-and-not-past-pts \
    "non-monotonic dts, or dts>pts, across $_n packets (REORDER clobber not fixed)"
fi

# 3) Stored codec really is avs2.
_codec=$("$FP" -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$_mkv" 2>/dev/null)
if [ "$_codec" = "avs2" ]; then
  _pass stored-codec-is-avs2
else
  _bad stored-codec-is-avs2 "codec=$_codec"
fi

# 4) Decode round-trip through libdavs2. Count the frames the decoder ACTUALLY
#    emits (framemd5 = one line per decoded frame), so the count belongs to the
#    explicit libdavs2 decode — not a re-probe of the file via some decoder.
"$FF" -v error -c:v libdavs2 -i "$_mkv" -f framemd5 - >"$_out/dec.md5" 2>"$_out/dec.err"
_dec=$(grep -cE '^[0-9]+,' "$_out/dec.md5")
if grep -qiE 'error|unsupported' "$_out/dec.err"; then
  _bad libdavs2-round-trip-decodes-every-frame \
    "decode error: $(_evidence 5 'error|unsupported' < "$_out/dec.err")"
elif [ "$_dec" = "$_nframes" ]; then
  _pass libdavs2-round-trip-decodes-every-frame
else
  _bad libdavs2-round-trip-decodes-every-frame \
    "libdavs2 emitted $_dec frames, expected $_nframes"
fi

exit "$_fail"
