#!/bin/sh
# shellcheck disable=SC1090,SC2034
# Build engine — recipe loading and phase execution.
# SC2034: PKG_* defaults below are read by recipe pkg_* functions after this
# file is sourced; shellcheck can't see the cross-file consumer.

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
  PKG_GITHUB_REPO=""
  # Recipe-declared dependency on the compiled-in openssldir. A recipe that
  # bakes the trust store into its output sets PKG_USES_OPENSSLDIR=true and
  # PKG_OPENSSLDIR_FALLBACK to the directory it wants when nothing else
  # resolves; run_recipe then resolves and validates it BEFORE the stamp
  # decision. See the openssldir block in run_recipe for why that timing is
  # load-bearing.
  PKG_USES_OPENSSLDIR=false
  PKG_OPENSSLDIR_FALLBACK=""
  # Recipe-declared install intent. If true, the recipe's pkgconfig files
  # listed in PKG_PC_FILES (space-separated, without .pc suffix) are queued
  # for removal AFTER FFmpeg's configure has consumed them but BEFORE
  # do_install copies the workspace to the install prefix. Used for
  # transitive utility deps (fontconfig, harfbuzz, freetype, ...) that
  # FFmpeg needs at build time but downstream consumers should resolve
  # against system pkgconfig. PKG_PC_FILES defaults to "$PKG_NAME".
  PKG_TRANSITIVE_UTIL=false
  PKG_PC_FILES=""

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

  # Required host-command guard. Reached only after the disable/mutex and
  # license guards above, so a missing tool here belongs to a package the build
  # actually intends to build — fail loud rather than silently dropping it.
  # python3/cargo/git are accepted host prerequisites; the escape hatch is an
  # explicit --disable=PKG.
  if [ -n "$PKG_REQUIRES_CMD" ]; then
    for _cmd in $PKG_REQUIRES_CMD; do
      if ! command_exists "$_cmd"; then
        die "$PKG_NAME requires '$_cmd', which is not installed. Install it, or skip this package with --disable=$PKG_NAME."
      fi
    done
  fi

  # Meson guard. mediaforge builds both meson and ninja (recipes/tools/) ahead of
  # every consumer, so this should always pass — if it doesn't, those tool
  # recipes were disabled or failed to build. Fail loud rather than skip.
  if [ "$PKG_REQUIRES_MESON" = true ]; then
    if ! command_exists meson || ! command_exists ninja; then
      die "$PKG_NAME requires meson and ninja, which mediaforge builds in recipes/tools/. They are missing — the meson/ninja recipe was disabled or failed. Re-enable it, or skip this package with --disable=$PKG_NAME."
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

  # Queue this recipe's .pc files for removal if it's a transitive utility.
  # We do this BEFORE check_guards / stamp_check so the queue is populated
  # even when the recipe is already-built or skipped. Default PKG_PC_FILES
  # to "$PKG_NAME" when the recipe didn't override.
  if [ "$PKG_TRANSITIVE_UTIL" = true ]; then
    for _pc in ${PKG_PC_FILES:-$PKG_NAME}; do
      printf '%s.pc\n' "$_pc" >> "$PREFIX/.pc-skip-queue"
    done
  fi

  # Check guards
  if ! check_guards; then
    # Don't re-accumulate the FFmpeg flag for a recipe excluded BY POLICY this
    # run: explicit --disable/mutex (DISABLE_PKGS), or its license tier not
    # enabled (GPL/nonfree). FFmpeg would reject the flag (e.g. --enable-libx264
    # without --enable-gpl aborts configure) or mislicense the binary. Transient
    # guards (missing cmd/meson, platform, arch) still re-accumulate, since the
    # stamped lib is present, linkable, and carries no license objection.
    _excluded=false
    for _d in $DISABLE_PKGS; do
      [ "$_d" = "$PKG_NAME" ] && _excluded=true && break
    done
    [ "$PKG_GPL" = true ] && [ "$ENABLE_GPL" != true ] && _excluded=true
    [ "$PKG_NONFREE" = true ] && [ "$ENABLE_NONFREE" != true ] && _excluded=true
    # A default-disabled (opt-in) recipe is a POLICY exclusion like the license
    # tiers above: the user did not ask for it, so don't re-feed its FFmpeg flag
    # even when a stamp from a prior build is present. If it HAD been
    # force-enabled (--enable=PKG), check_guards would not have skipped it here —
    # unless a later transient guard (platform/arch/cmd) tripped, in which case
    # the lib is not usable this run and suppressing the flag is the safe choice.
    [ "$PKG_DISABLED" = true ] && _excluded=true
    if [ "$_excluded" != true ]; then
      _has_stamp=false
      for _s in "$PREFIX/.stamps/${PKG_NAME}-"*; do [ -f "$_s" ] && _has_stamp=true && break; done
      if [ -n "$PKG_FFMPEG_OPT" ] && [ "$_has_stamp" = true ]; then
        FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS $PKG_FFMPEG_OPT"
      fi
    fi
    return 0
  fi

  # Resolve the compiled-in openssldir BEFORE the stamp is consulted.
  #
  # The timing is the whole point. stamp_check keys the stamp on <pkg>-<ver>
  # (lib/utils.sh:70), so the openssldir — a build input that is compiled into
  # the library — is not part of the recipe's identity. A rebuild whose ONLY
  # changed input is --openssldir therefore hits the stamp below, returns
  # "already built", and silently keeps the previously baked path. That is the
  # normal way a user meets this flag: build, discover https:// has no trust
  # store, re-run with --openssldir.
  #
  # Putting the check inside a phase does not work: the phases run ~40 lines
  # below, past the stamp's `return 0`, so it would be dead code on precisely
  # the path it exists to guard. Putting it at recipe top level does not work
  # either: check_updates sources every recipe in its own loop (lib/updates.sh)
  # without ever entering run_recipe, and it does not parse --openssldir, so a
  # top-level assert would abort `check-updates` on any workspace whose recorded
  # value differs from a fresh probe. Here it runs on the build path only, and
  # only after check_guards has confirmed the recipe is actually wanted.
  #
  # This also leaves OPENSSLDIR_RESOLVED set for the phases, so the recipe
  # records rather than re-derives it — one resolution per run.
  # The assert fires ONLY when this recipe is already stamped, i.e. only when the
  # stamp is about to make us skip a rebuild that the changed input calls for.
  # Asserting unconditionally would abort two legitimate rebuilds instead:
  #   * a build that failed AFTER pkg_configure recorded the value leaves a
  #     record with no stamp, so the corrected re-run would be refused — and the
  #     remedy the message prints (rm the stamp) would match nothing;
  #   * the two TLS arms share one record with different fallbacks, so switching
  #     --tls=libressl to --tls=openssl on a host with no cert.pem would abort a
  #     build in which the user changed nothing about the trust store.
  # In both, no stamp exists for this recipe, so the build proceeds and re-records.
  if [ "$PKG_USES_OPENSSLDIR" = true ]; then
    resolve_openssldir "$PKG_OPENSSLDIR_FALLBACK"
    if stamp_exists "$PKG_NAME" "$PKG_VERSION"; then
      openssldir_assert_unchanged "$OPENSSLDIR_RESOLVED" "$PKG_NAME"
    fi
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
