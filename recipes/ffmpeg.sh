#!/bin/sh
# Final FFmpeg build — consumes FFMPEG_CONFIGURE_OPTS from all recipes

# If flite was built with an audio backend, FFmpeg's static link needs the
# matching system library on the link line. Default --flite-audio=none skips
# this entirely (no au_*.o in libflite.a → no unresolved symbols).
if [ "$OS_LINUX" = true ] && [ -f "$PREFIX/lib/libflite.a" ]; then
  case "$FLITE_AUDIO" in
    alsa)        EXTRALIBS="$EXTRALIBS -lasound" ;;
    pulseaudio)  EXTRALIBS="$EXTRALIBS -lpulse-simple -lpulse" ;;
    oss)         ;; # OSS uses kernel ioctl, no -l flag
    sun)         ;; # Sun audio is in libc on Solaris-likes
    none)        ;;
  esac
fi

EXTRA_VERSION="mediaforge"

log ""
log "Building FFmpeg $FFMPEG_VERSION"
log "======================="

# Sourced directly by mediaforge.sh rather than through run_recipe(), so
# unlike every other recipe it must set its own identity. Nothing resets the
# PKG_* globals before this file is sourced, so without the PKG_NAME line it
# reports whichever name the last recipe in _order.conf left behind. Both are
# read by fetch()/makesum in lib/download.sh, a cross-file consumer shellcheck
# can't see.
# shellcheck disable=SC2034
PKG_NAME="ffmpeg"
# shellcheck disable=SC2034
PKG_HASH_FILE="$(ffmpeg_hash_file)"

fetch "$(ffmpeg_tarball_url)" "$(ffmpeg_tarball_filename)"

# Local patch: mark AVS2 as AV_CODEC_PROP_REORDER so libavcodec/encode.c does
# NOT clobber libxavs2's B-frame decode-order DTS with dts=pts (which yields a
# non-monotonic DTS in coding order -> muxer "non monotonically increasing dts"
# EINVAL). libxavs2 has CAP_DELAY and no FF_CODEC_CAP_EOF_FLUSH, so the missing
# REORDER prop is the sole trigger; VVC/EVC already carry it. Applied here (CWD
# is the extracted FFmpeg source). --fuzz=0: a future FFmpeg version that drifts
# or fixes this upstream makes the patch fail loudly (drop it then) rather than
# mis-apply. See patches/ffmpeg-avs2-reorder.patch.
if ! patch -p1 -f --fuzz=0 < "$SCRIPT_DIR/patches/ffmpeg-avs2-reorder.patch"; then
  patch -p1 -R --fuzz=0 --dry-run < "$SCRIPT_DIR/patches/ffmpeg-avs2-reorder.patch" >/dev/null 2>&1 \
    || die "ffmpeg-avs2-reorder.patch failed to apply and is not already applied"
fi

print_flags

# Build the full configure command as a string, then eval it.
# This is necessary because FFMPEG_CONFIGURE_OPTS and NVCCFLAGS
# contain multiple flags that must word-split, while --extra-cflags
# and similar must preserve their quoted values.
_ffconf="./configure $FFMPEG_CONFIGURE_OPTS"

if [ -n "$NVCCFLAGS" ]; then
  _ffconf="$_ffconf --nvccflags=\"$NVCCFLAGS\""
fi

# Debug posture, from the level in effect (lib/flags.sh). Without this the final
# binary is stripped whatever every library did: FFmpeg's Makefile links
# ffmpeg_g and derives a stripped ffmpeg from it, and --disable-debug leaves
# ffmpeg_g with nothing in it either. With no --debug the value is the
# --disable-debug this line has always passed, so a normal build is unchanged.
_ffconf="$_ffconf \
  $(mf_debug_ffmpeg_opts "${MF_DEBUG_LEVEL:-}") \
  --disable-shared \
  --enable-pthreads \
  --enable-static \
  --enable-version3 \
  --extra-cflags=\"$CFLAGS\" \
  --extra-ldexeflags=\"$LDEXEFLAGS\" \
  --extra-ldflags=\"$LDFLAGS\" \
  --extra-libs=\"$EXTRALIBS\" \
  --pkgconfigdir=\"$PREFIX/lib/pkgconfig\" \
  --pkg-config-flags=\"--static\" \
  --prefix=\"$PREFIX\" \
  --extra-version=\"$EXTRA_VERSION\""

# Prevent ffmpeg's version.sh from detecting the project's .git
log "$ $_ffconf"
GIT_DIR=/nonexistent \
eval "$_ffconf" > "$PREFIX/.logs/ffmpeg-configure.log" 2>&1 || {
  cat "$PREFIX/.logs/ffmpeg-configure.log" >&2
  die "FFmpeg configure failed"
}

run make -j "$MJOBS"

# FFmpeg's own install is staged and stamped like every recipe's, so the one
# package that writes into the workspace without a manifest stops being an
# exception (GH-77). Before this, every file FFmpeg installed was claimed by no
# stamp -- 248 of them on a full build, and the largest single reason a
# prefix-side orphan audit could not be a gate. Not the only one: a full rebuild
# with FFmpeg stamped still leaves the meson bytecode caches unclaimed, because
# they are written when meson RUNS rather than when it is installed (GH-77).
#
# DESTDIR on the command line, matching default_install and the GNU Coding
# Standards. FFmpeg honours the environment too -- probed on 8.0.1, 248 files
# staged either way, and ffbuild/config.mak references $(DESTDIR) without
# assigning it -- but the command-line form is the one that survives an upstream
# that starts assigning it, and that failure is silent.
#
# The stamp is EVIDENCE, NOT A GATE. Nothing consults it, and nothing should:
# FFmpeg is the final target, and a stamp keyed on the version alone cannot
# stand for a build whose configure line changes with --enable-gpl, --tls=, and
# every other selector. Skipping on it would silently ignore the flags the
# operator just changed. It is rewritten on every build, so a drifted one heals
# itself.
# Reset first, mirroring run_recipe: FFmpeg's window inherits whatever
# MF_STAGE_PENDING and MF_STAGE_RESERVED the last recipe left, and a leak would
# attribute another package's files to this stamp. They are empty here today,
# which is a property of every predecessor's exit path rather than of this code.
mf_stage_pending_reset
mf_stage_reserved_reset
mf_stage_begin
run make install DESTDIR="$DESTDIR"
# Commits as well as records -- the `file` read-back below reads $PREFIX, and
# without the merge the binary is still sitting in the stage.
#
# INSIDE the window, where run_recipe writes its stamp after mf_stage_end, and
# that is not a free choice: mf_stage_end deletes the stage dir, so a
# stamp_write below it would find no staged tree, take mf_stage_commit's stray
# branch, and record an EMPTY manifest -- FFmpeg back to being the unmanifested
# exception this exists to remove. run_recipe can write afterwards only because
# mf_stage_claim already committed inside its window and mf_stage_restore hands
# the paths back; this recipe has neither. tests/ffmpeg-stamped.sh pins the
# order for exactly that reason.
stamp_write "ffmpeg" "$FFMPEG_VERSION"
mf_stage_end

# Verify the binary
if command_exists "file"; then
  _binary_type=$(file "$PREFIX/bin/ffmpeg" | sed 's/^.*: //')
  log ""
  log "Built binary: $_binary_type"
fi

log ""
log "Build complete. Binaries available at:"
log "  ffmpeg:  $PREFIX/bin/ffmpeg"
log "  ffprobe: $PREFIX/bin/ffprobe"
log "  ffplay:  $PREFIX/bin/ffplay"

# Finalize the recipe-declared pc-skip queue. Each transitive-utility recipe
# (PKG_TRANSITIVE_UTIL=true) appended its .pc filenames during the build pass.
# FFmpeg's configure has now consumed them to bake transitive link flags inline
# into libav*.pc, so the names can be recorded as not-for-install.
#
# Recorded, not deleted. Deleting them here made the workspace single-use
# (GH-60): the recipes that own them are stamped, so a second build never
# reinstalls them and its configure resolves the names from the system instead.
# do_install reads the list; see lib/pc-exclusions.sh for the whole argument.
pc_exclusions_finalize
