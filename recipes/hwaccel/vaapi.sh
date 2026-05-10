PKG_NAME="vaapi"
PKG_VERSION="${PKG_VERSION_VAAPI:-1}"
PKG_URL=""
PKG_LINUX_ONLY=true
PKG_SKIP_EXTRACT=true

# Decide --enable-vaapi at recipe-source time, NOT in pkg_prepare. The
# framework appends PKG_FFMPEG_OPT before pkg_prepare runs on stamp-cached
# hits, so a runtime override there is too late.
if [ -n "$LDEXEFLAGS" ]; then
  log "Skipping vaapi (incompatible with --enable-static — Arch ships .so only)"
  PKG_FFMPEG_OPT=""
elif ! library_exists "libva"; then
  log "Skipping vaapi (libva not found on host)"
  PKG_FFMPEG_OPT=""
else
  PKG_FFMPEG_OPT="--enable-vaapi"
fi

pkg_configure() { :; }
pkg_build() { :; }
pkg_install() { :; }
