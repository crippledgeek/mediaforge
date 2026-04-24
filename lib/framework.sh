#!/bin/sh
# shellcheck disable=SC1090
# Build engine — recipe loading and phase execution

# Default phase functions
default_configure() {
  if [ "$PKG_CMAKE" = true ]; then
    # shellcheck disable=SC2086
    run cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF \
      $PKG_CMAKE_FLAGS .
  else
    # shellcheck disable=SC2086
    run ./configure --prefix="$PREFIX" \
      --disable-shared --enable-static \
      $PKG_CONFIGURE_FLAGS
  fi
}

default_build() {
  run make -j "$MJOBS"
}

default_install() {
  run make install
}

default_noop() {
  :
}

# Reset all PKG_* variables and phase functions between recipes
reset_recipe() {
  PKG_NAME=""
  PKG_VERSION=""
  PKG_URL=""
  PKG_FILENAME=""
  PKG_DIRNAME=""
  PKG_FFMPEG_OPT=""
  PKG_GPL=false
  PKG_NONFREE=false
  PKG_REQUIRES_CMD=""
  PKG_REQUIRES_MESON=false
  PKG_LINUX_ONLY=false
  PKG_SKIP_ON_ARCH=""
  PKG_SKIP_EXTRACT=false
  PKG_DISABLED=false
  PKG_MUTEX_GROUP=""
  PKG_CONFIGURE_FLAGS=""
  PKG_CMAKE=false
  PKG_CMAKE_FLAGS=""
  # shellcheck disable=SC2034
  PKG_GITHUB_REPO=""

  # Reset phase functions to defaults
  pkg_prepare()      { default_noop; }
  pkg_configure()    { default_configure; }
  pkg_build()        { default_build; }
  pkg_install()      { default_install; }
  pkg_post_install() { default_noop; }
}

# Check whether a recipe should be skipped based on guards
# Returns 0 if recipe should run, 1 if it should be skipped
check_guards() {
  # Generic CLI disable list (drives --disable= and --tls=/--aac=/etc.)
  for _d in $DISABLE_PKGS; do
    if [ "$_d" = "$PKG_NAME" ]; then
      log "Skipping $PKG_NAME (disabled via CLI)"
      return 1
    fi
  done

  # Disabled guard (e.g., SKIPRAV1E=yes), with --enable=PKG override
  if [ "$PKG_DISABLED" = true ]; then
    _force=false
    for _e in $ENABLE_PKGS; do
      [ "$_e" = "$PKG_NAME" ] && _force=true && break
    done
    if [ "$_force" != true ]; then
      log "Skipping $PKG_NAME (disabled)"
      return 1
    fi
    log "Force-enabling $PKG_NAME via --enable=$PKG_NAME"
  fi

  # GPL guard
  if [ "$PKG_GPL" = true ] && [ "$ENABLE_GPL" != true ]; then
    log "Skipping $PKG_NAME (requires --gpl)"
    return 1
  fi

  # Nonfree guard
  if [ "$PKG_NONFREE" = true ] && [ "$ENABLE_NONFREE" != true ]; then
    log "Skipping $PKG_NAME (requires --nonfree)"
    return 1
  fi

  # Required commands guard
  if [ -n "$PKG_REQUIRES_CMD" ]; then
    for _cmd in $PKG_REQUIRES_CMD; do
      if ! command_exists "$_cmd"; then
        warn "$_cmd not found — skipping $PKG_NAME"
        return 1
      fi
    done
  fi

  # Meson guard
  if [ "$PKG_REQUIRES_MESON" = true ]; then
    if ! command_exists meson || ! command_exists ninja; then
      warn "meson/ninja not found — skipping $PKG_NAME"
      return 1
    fi
  fi

  # Linux-only guard
  if [ "$PKG_LINUX_ONLY" = true ] && [ "$OS_LINUX" != true ]; then
    log "Skipping $PKG_NAME (Linux only)"
    return 1
  fi

  # Architecture guard
  if [ -n "$PKG_SKIP_ON_ARCH" ] && [ "$OS_ARCH" = "$PKG_SKIP_ON_ARCH" ]; then
    log "Skipping $PKG_NAME (not supported on $OS_ARCH)"
    return 1
  fi

  return 0
}

# Run a single recipe file through the build lifecycle
run_recipe() {
  _recipe_path="$1"

  if [ ! -f "$_recipe_path" ]; then
    die "Recipe not found: $_recipe_path"
  fi

  # Reset state
  reset_recipe

  # Source the recipe to load its variables and phase overrides
  . "$_recipe_path"

  # Validate required fields (PKG_URL may be empty if PKG_SKIP_EXTRACT is true)
  if [ -z "$PKG_NAME" ] || [ -z "$PKG_VERSION" ]; then
    die "Recipe $_recipe_path missing required fields (PKG_NAME, PKG_VERSION)"
  fi
  if [ -z "$PKG_URL" ] && [ "$PKG_SKIP_EXTRACT" != true ]; then
    die "Recipe $_recipe_path missing PKG_URL (set PKG_SKIP_EXTRACT=true for header-only packages)"
  fi

  # Check guards
  if ! check_guards; then
    # Still accumulate ffmpeg option if the package was previously built
    _has_stamp=false
    for _s in "$PREFIX/.stamps/${PKG_NAME}-"*; do [ -f "$_s" ] && _has_stamp=true && break; done
    if [ -n "$PKG_FFMPEG_OPT" ] && [ "$_has_stamp" = true ]; then
      FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS $PKG_FFMPEG_OPT"
    fi
    return 0
  fi

  # Check stamp (stamp_check returns 1 if already built)
  if ! stamp_check "$PKG_NAME" "$PKG_VERSION"; then
    # Already built — accumulate ffmpeg option and skip
    if [ -n "$PKG_FFMPEG_OPT" ]; then
      FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS $PKG_FFMPEG_OPT"
    fi
    return 0
  fi

  # Dry-run short-circuit: print intent, accumulate ffmpeg flag, skip download/build
  if [ "${DRY_RUN:-false}" = true ]; then
    log "Would build $PKG_NAME-$PKG_VERSION"
    if [ -n "$PKG_FFMPEG_OPT" ]; then
      FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS $PKG_FFMPEG_OPT"
    fi
    return 0
  fi

  # Set current package for trap handler
  set_current_package "$PKG_NAME"

  # Save compiler flags
  _saved_cflags="$CFLAGS"
  _saved_cxxflags="$CXXFLAGS"
  _saved_ldflags="$LDFLAGS"
  _saved_cppflags="$CPPFLAGS"
  _saved_dir=$(pwd)

  # Download and extract
  if [ "$PKG_SKIP_EXTRACT" != true ]; then
    _dl_file=""
    _dl_dir=""
    if [ -n "$PKG_FILENAME" ]; then
      _dl_file="$PKG_FILENAME"
    fi
    if [ -n "$PKG_DIRNAME" ]; then
      _dl_dir="$PKG_DIRNAME"
    fi
    fetch "$PKG_URL" "$_dl_file" "$_dl_dir"
  fi

  # Run phases
  pkg_prepare
  pkg_configure
  pkg_build
  pkg_install
  pkg_post_install

  # Mark as done
  stamp_write "$PKG_NAME" "$PKG_VERSION"

  # Accumulate ffmpeg configure option
  if [ -n "$PKG_FFMPEG_OPT" ]; then
    FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS $PKG_FFMPEG_OPT"
  fi

  # Restore compiler flags
  CFLAGS="$_saved_cflags"
  CXXFLAGS="$_saved_cxxflags"
  LDFLAGS="$_saved_ldflags"
  CPPFLAGS="$_saved_cppflags"

  # Restore working directory
  cd "$_saved_dir" || die "Failed to restore working directory"

  set_current_package ""
}
