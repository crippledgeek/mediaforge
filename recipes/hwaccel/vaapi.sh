PKG_NAME="vaapi"
PKG_VERSION="1"
PKG_URL=""
PKG_FFMPEG_OPT="--enable-vaapi"
PKG_LINUX_ONLY=true
PKG_SKIP_EXTRACT=true

pkg_prepare() {
  if [ -n "$LDEXEFLAGS" ]; then
    log "Skipping vaapi (incompatible with --full-static)"
    PKG_FFMPEG_OPT=""
    return 0
  fi
  if ! library_exists "libva"; then
    log "Skipping vaapi (libva not found)"
    PKG_FFMPEG_OPT=""
    return 0
  fi
}

pkg_configure() { :; }
pkg_build() { :; }
pkg_install() { :; }
