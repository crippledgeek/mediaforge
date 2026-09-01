#!/bin/sh
# shellcheck disable=SC1090,SC2034
# Build engine — recipe loading and phase execution.
# Requires lib/registry.sh to be sourced first: check_guards resolves a
# recipe's CLI-facing name through recipe_key, which lives there.
# SC2034: PKG_* defaults below are read by recipe pkg_* functions after this
# file is sourced; shellcheck can't see the cross-file consumer.

# The one place cmake is configured. Recipes call this instead of `run cmake`,
# so the install prefix and the build type are set once rather than at the 21
# configure call sites spread over 17 recipes -- the build type in particular is
# the knob a debug mode has to turn, and turning it in 17 recipes is 17 chances
# to miss one.
# tests/cmake-single-entry.sh pins that nothing configures cmake around it.
#
# It supplies ONLY what every call site already had: the prefix, plus the build
# type when the recipe names one via PKG_CMAKE_BUILD_TYPE. BUILD_SHARED_LIBS and
# ENABLE_SHARED are deliberately NOT supplied here even though most recipes pass
# them, because several do not, and adding them would silently change those
# builds. Likewise a recipe that names no build type still gets none: ten
# currently do that, and defaulting them to Release would move them from the -O2
# they inherit through CFLAGS to -O3 -DNDEBUG. This extraction is a refactor,
# and a behaviour change riding inside one is what nobody reviews for.
#
# Every other argument passes through untouched, which is why the differing
# source-dir spellings (`.`, `-S . -B build`, `../../../source`) all still work.
mf_cmake() {
  # A debug level OVERRIDES the recipe's own build type. That is the whole
  # reason this helper exists: the ten recipes that name no build type and the
  # 25 pinned to Release would otherwise stay optimized while the rest of the
  # tree went debug, and the result still compiles and still links.
  _mf_bt=$(mf_debug_cmake_type "${MF_DEBUG_LEVEL:-}")
  [ -n "$_mf_bt" ] || _mf_bt="${PKG_CMAKE_BUILD_TYPE:-}"
  if [ -n "$_mf_bt" ]; then
    run cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DCMAKE_BUILD_TYPE="$_mf_bt" "$@"
  else
    run cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" "$@"
  fi
}

# The one meson setup. Eighteen call sites across 13 recipes repeated the
# same four flags -- prefix, buildtype, default-library, libdir -- and differed
# only in their build directory and their -D options.
#
# $1 is the build directory (positional to meson); everything after is passed
# through. Option order is irrelevant to meson, so the extras land last.
#
# Spelled `meson setup` even where a recipe used the bare `meson <dir>` form:
# the bare form is the deprecated spelling of the same operation, and having one
# spelling is the point of this helper.
#
# PKG_MESON_BUILDTYPE mirrors PKG_CMAKE_BUILD_TYPE -- one knob per build system,
# both reset per recipe. Note that meson's buildtype does NOT control assertions
# the way cmake's does: -Ddebug=false leaves NDEBUG undefined, which is the
# separate b_ndebug option. Anything turning these knobs together has to set
# that explicitly rather than assume the two systems agree.
mf_meson() {
  _mf_builddir="$1"
  shift
  # A debug level replaces the buildtype AND names b_ndebug explicitly, because
  # meson does not tie NDEBUG to buildtype the way cmake does.
  #
  # Precisely: the level's arguments land after THIS HELPER's defaults, not after
  # the recipe's own "$@". No recipe passes buildtype or b_ndebug today (none in
  # recipes/ does, and tests/meson-single-entry.sh forbids it), so the ordering
  # is not reachable -- but the guarantee is "the level beats the helper", not
  # "the level beats everything".
  #
  # The unquoted expansion below is deliberate word-splitting, and it is safe
  # here for a reason the linter cannot see: $_mf_dbg is never operator input.
  # It is one of exactly three fixed strings from the table in lib/flags.sh,
  # selected by a level that mediaforge.sh has already validated -- so there is
  # no value it can hold that contains a glob or an unexpected word.
  #
  # The level supplies its OWN --buildtype, so the recipe's is omitted entirely
  # rather than passed first and overridden. meson does accept the flag twice
  # and take the last (verified), but relying on that is relying on argparse's
  # behaviour rather than on anything meson documents -- and a build log showing
  # `--buildtype=release --buildtype=debug` invites exactly the "which one won?"
  # question this helper exists to remove.
  _mf_dbg=$(mf_debug_meson_args "${MF_DEBUG_LEVEL:-}")
  # PYTHONDONTWRITEBYTECODE stops meson caching its own bytecode into
  # $PREFIX/share/meson/**/__pycache__ (GH-77). Those files are written when
  # meson RUNS rather than when it is installed, so no recipe's manifest can
  # claim them: measured on a full --enable-nonfree workspace in 2026-08, they
  # were 151 of the 163 files reconcile's unclaimed audit reported.
  #
  # Fixed at the generator rather than excluded from the audit, which is where
  # every packaging system that hit this converged: rpm closed the .pyc
  # false-positive Won't-Fix and pointed at brp-python-bytecompile, and Debian
  # uses py3compile/py3clean or this same variable. It matters beyond tidiness
  # here, because lilv -- built as a sub-package inside recipes/audio/lv2.sh, not
  # a recipe of its own -- deliberately INSTALLS a .pyc that its stamp claims, at
  # lib/pythonX.Y/site-packages/__pycache__/lilv.cpythonXY.pyc. A blanket
  # __pycache__ exclusion in the audit would have hidden that file's whole class
  # rather than the noise.
  #
  # The cost is an uncached import per meson start: ~420ms, measured as
  # `meson --version` with the cache purged (754ms mean) against warm (331ms
  # mean). A build starts meson at the 18 mf_meson sites, the 17
  # `run ninja … install` steps, and lv2's two `run meson` steps -- so at most
  # ~15s if every start pays the full import, seconds against a build measured in
  # tens of minutes.
  #
  # EXPORTED for the rest of this recipe rather than set on this one command,
  # because `meson setup` is not the only writer: `ninja -C build install` spawns
  # `meson --internal install`, which imports the same package again. Measured on
  # a probe project -- setup and ninja under the variable wrote 0 .pyc, and the
  # install step that did not inherit it wrote 100. recipes/audio/lv2.sh is the
  # in-tree case: its zix sub-build reaches the same code as `run meson compile`
  # and `run meson install` AFTER its mf_meson call, and inherits this only
  # because the export outlives that call.
  #
  # reset_recipe unsets it, which is what bounds the export: run_recipe is a
  # plain call and every recipe is sourced into this same shell, so without that
  # it would reach every later recipe. mediaforge.sh unsets it again before
  # sourcing recipes/ffmpeg.sh, which does not go through run_recipe at all.
  export PYTHONDONTWRITEBYTECODE=1
  if [ -n "$_mf_dbg" ]; then
    # shellcheck disable=SC2086
    run meson setup "$_mf_builddir" --prefix="$PREFIX" \
      --default-library=static --libdir="$PREFIX/lib" $_mf_dbg "$@"
  else
    run meson setup "$_mf_builddir" --prefix="$PREFIX" \
      --buildtype="${PKG_MESON_BUILDTYPE:-release}" \
      --default-library=static --libdir="$PREFIX/lib" "$@"
  fi
}

# Rewrite an installed .pc in place, once.
#
# Eight recipes did this by hand and in two mechanisms: six appended -lstdc++ to
# Libs: (chromaprint, vmaf, openh264, vvenc, xeve, xevd) with byte-identical awk
# programs, and two swapped -lgcc_s for -lgcc_eh under LDEXEFLAGS (srt, x265),
# guard included. Only the .pc filename varied.
#
# All eight shared a silent failure. `awk prog "$_pc" > "$_pc.tmp" && mv ...` on
# a .pc that is not there fails the awk, skips the mv, and leaves the recipe
# having quietly not applied its fix -- so a library whose pkg-config name or
# layout changed upstream would link without the flag the recipe exists to add,
# and nothing would say so. The existence check is the reason to have one
# definition rather than eight.
#
# The path is the LIVE prefix, not the stage, and that is correct: this runs in
# pkg_post_install, after the framework has merged what pkg_install staged, and
# it overwrites a file already named in the recipe's manifest under the same
# name. See lib/stage.sh on why a create at a live-prefix path would not be.
# Leading underscore: framework-INTERNAL. It takes an arbitrary awk program, so
# a recipe calling it directly is back to N spellings of the rewrite with only
# the existence check shared -- the thing this replaced. The two wrappers below
# are the recipe-facing surface, and tests/pc-rewrite-single-entry.sh asserts no
# recipe names this one.
#
# _mf_pc, not _pc: POSIX sh has no locals, and lib/install.sh and mediaforge.sh
# both use a bare _pc as a loop variable. Unreachable today -- neither loop runs
# a recipe phase -- but the two neighbours in this file namespace theirs (_mf_bt,
# _mf_builddir) for the same reason.
_mf_pc_rewrite() { # pc-name  awk-program
  # An allowlist, not a blocklist, because $1 becomes a PATH. Every caller
  # passes a literal today and the wrappers are the only callers, so this is
  # inert -- but PKG_PC_FILES already exists in the tree as a recipe-DECLARED
  # value, so a future caller interpolating one is a short step, and the cost of
  # being wrong is a write outside lib/pkgconfig. `..` is rejected separately
  # because `.` has to be allowed: real .pc names carry versions (gtk+-3.0).
  case "$1" in
    ''|*[!A-Za-z0-9._+-]*|*..*)
      die "$PKG_NAME: refusing .pc name '$1' -- expected a bare name, not a path" ;;
  esac
  _mf_pc="$PREFIX/lib/pkgconfig/${1}.pc"
  [ -f "$_mf_pc" ] || die "$PKG_NAME: expected $_mf_pc to rewrite (upstream .pc name or layout changed?)"
  awk "$2" "$_mf_pc" > "$_mf_pc.tmp" || { rm -f "$_mf_pc.tmp"; die "$PKG_NAME: failed to rewrite $_mf_pc"; }
  mv "$_mf_pc.tmp" "$_mf_pc" || { rm -f "$_mf_pc.tmp"; die "$PKG_NAME: failed to replace $_mf_pc"; }
}

# C++ libraries whose upstream .pc omits -lstdc++, which a --static link needs.
#
# For a .pc the BUILD GENERATES, patch the generator in pkg_prepare instead --
# recipes/image/libjxl.sh does that for this same problem. This is for one
# already installed, which is a different operation on a different artifact.
mf_pc_add_stdcxx() { # pc-name
  # $0 is awk's whole-record variable, so the single quotes are the point and
  # expanding it would be the bug. The linter cannot see that the argument is an
  # awk program rather than shell, which it could when awk was called inline
  # here -- the one thing this extraction costs.
  # shellcheck disable=SC2016
  _mf_pc_rewrite "$1" '/^Libs:/ && !/-lstdc\+\+/ {$0 = $0 " -lstdc++"} {print}'
}

# -lgcc_s is the shared unwinder; a fully static executable needs -lgcc_eh.
# Guarded here rather than at each call site, because both callers carried the
# same `[ -n "$LDEXEFLAGS" ]` test and a third would have to remember it.
#
# The guard costs the safety net asymmetrically, and that is deliberate rather
# than an oversight: mf_pc_add_stdcxx dies the moment its .pc name rots
# upstream, while this one returns before looking, so the same rot in srt's or
# x265's .pc surfaces only on an --enable-static run. Matching the old
# semantics -- a non-static build had no reason to touch those files.
mf_pc_static_libgcc() { # pc-name
  [ -n "${LDEXEFLAGS:-}" ] || return 0
  _mf_pc_rewrite "$1" '/^Libs/ {gsub(/-lgcc_s/, "-lgcc_eh")} {print}'
}

# Default phase functions
default_configure() {
  if [ "$PKG_CMAKE" = true ]; then
    # shellcheck disable=SC2086
    mf_cmake -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF \
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
  # DESTDIR on the COMMAND LINE, not merely in the environment.
  #
  # An assignment inside a makefile beats an environment variable of the same
  # name; only a command-line assignment beats the makefile. xvidcore ships a
  # bare `DESTDIR=` in build/generic/platform.inc, so it ignored the exported
  # one entirely: measured 0 files staged through the environment against 3
  # through the command line, on the same tree. Nothing failed and nothing
  # warned -- the recipe installed straight to the live prefix exactly as it did
  # before staging existed, and only its manifest came out empty, which reads
  # identically to a recipe that installs with a shell cp.
  #
  # `make install DESTDIR=...` is the form the GNU Coding Standards document,
  # so this is the canonical spelling rather than a workaround for one recipe.
  if [ -n "${DESTDIR:-}" ]; then
    run make install DESTDIR="$DESTDIR"
  else
    run make install
  fi
  # Publish immediately, so a recipe can manipulate what it just installed
  # (GH-59). Under staging `make install` writes to $DESTDIR, and a recipe that
  # goes on to touch "$PREFIX/..." in the SAME phase would otherwise act on a
  # prefix the files have not reached yet.
  #
  # That is not hypothetical: recipes/video/xeve.sh and recipes/video/xevd.sh
  # both call default_install and then `rm -f "$PREFIX/lib/libxeve.so"` to drop
  # the shared library upstream ships beside the static one. Without this commit
  # the rm matches nothing, the merge publishes the .so anyway, and FFmpeg's
  # static link can resolve -lxeve against it -- the exact outcome those two
  # lines exist to prevent, silently undone.
  #
  # A recipe that overrides pkg_install with a raw `ninja -C build install` or
  # `cmake --install` and then edits $PREFIX must commit for the same reason.
  mf_stage_commit
}

default_noop() {
  :
}

# Accumulate this recipe's FFmpeg configure flag.
#
# Three of run_recipe's exits contribute the flag UNCONDITIONALLY -- already
# stamped, dry-run, and a completed build -- and each carried its own copy of the
# same four lines. Missing one configures FFmpeg without a codec whose library is
# present, and the build still succeeds.
#
# The guard-skip path earlier in run_recipe is deliberately NOT this function: it
# returns before these and accumulates only when the recipe already has a stamp,
# which is its own rule rather than this one. Converging it here would change
# that condition, so it is left alone on purpose.
#
# tests/dry-run-matrix.sh is what would eventually notice a miss, and only for
# the dry-run path.
accumulate_ffmpeg_opt() {
  if [ -n "$PKG_FFMPEG_OPT" ]; then
    FFMPEG_CONFIGURE_OPTS="$FFMPEG_CONFIGURE_OPTS $PKG_FFMPEG_OPT"
  fi
}

# Reset all PKG_* variables and phase functions between recipes
reset_recipe() {
  PKG_NAME=""
  PKG_VERSION=""
  PKG_URL=""
  PKG_COMMIT=""
  # Framework-derived, never recipe-set: the path of this recipe's .hash file.
  # Nested fetch calls inside pkg_install() inherit it as ordinary shell state,
  # which is how lv2's sub-tarballs all land in one lv2.hash.
  PKG_HASH_FILE=""
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
  # Empty means "supply no build type", which is what the recipes that never
  # set one already do. Reset per recipe like every other PKG_*, so one recipe's
  # Release cannot leak into the next recipe's build.
  PKG_CMAKE_BUILD_TYPE=""
  # Empty means mf_meson's own default (release), which is what all eighteen
  # call sites passed explicitly before they were converged.
  PKG_MESON_BUILDTYPE=""
  # Not a PKG_* field: the environment variable mf_meson exports so meson stops
  # caching its bytecode into the prefix (GH-77). It is reset here for the same
  # reason PKG_CMAKE_BUILD_TYPE is -- recipes are sourced into one shell, so an
  # export lives until something clears it, and its intended lifetime is one
  # recipe. A meson recipe re-exports it; a recipe that never calls mf_meson
  # builds exactly as it did before.
  #
  # This clears it for every recipe that arrives through load_recipe, which is
  # every recipe in _order.conf. It is NOT the whole story: recipes/ffmpeg.sh is
  # sourced directly by mediaforge.sh, outside run_recipe and therefore outside
  # this reset, so mediaforge.sh unsets it again at that call. Two sites because
  # there are two paths into a recipe, not because one of them is redundant.
  unset PYTHONDONTWRITEBYTECODE
  # A C standard this recipe's source needs. Sixteen recipes carried the flag;
  # in 12 of them the entire body of pkg_prepare() was appending -std=gnu11 to
  # CFLAGS and exporting it. The other four folded it in beside real work, which
  # is how the shapes diverged -- a recipe wanting a REAL prepare step had to
  # remember to carry the flag along with it.
  PKG_C_STD=""
  PKG_GITHUB_REPO=""
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
  # Every name the user can type -- --disable=, --enable=, and the mutex
  # exclusions lib/resolve.sh writes into DISABLE_PKGS -- is a recipe FILENAME,
  # because that is what the registry validates against. PKG_NAME is the
  # display name and three recipes diverge from their filename, so comparing
  # against it made --disable=vapoursynth validate, warn nothing, and do
  # nothing. recipe_key (lib/registry.sh) is that one identity; PKG_NAME stays
  # in the log lines, which is what it is for.
  #
  # FATAL rather than a fallback to PKG_NAME. load_recipe derives a hash-file
  # path for every recipe, so this cannot fire in a well-formed run -- and when
  # something structural IS wrong, degrading quietly to the identity we just
  # removed is the worst available answer. That is not hypothetical: this guard
  # was written with a `|| _guard_key="$PKG_NAME"` fallback, and it silently
  # absorbed a test file that sourced this module without lib/registry.sh --
  # recipe_key was undefined, the fallback fired, the comparison ran against the
  # wrong identity, and the suite stayed green.
  _guard_key=$(recipe_key) || die "Cannot derive a CLI identity for '$PKG_NAME': no hash-file path is set for this recipe, so --disable=/--enable= cannot be matched against it. load_recipe (lib/framework.sh) sets PKG_HASH_FILE for every recipe -- reaching here means this recipe was loaded some other way, or lib/registry.sh was never sourced."

  # Generic CLI disable list (drives --disable= and --tls=/--aac=/etc.)
  for _d in $DISABLE_PKGS; do
    if [ "$_d" = "$_guard_key" ]; then
      log "Skipping $PKG_NAME (disabled via CLI)"
      return 1
    fi
  done

  # Disabled guard (e.g., SKIPRAV1E=yes), with --enable=PKG override
  if [ "$PKG_DISABLED" = true ]; then
    _force=false
    for _e in $ENABLE_PKGS; do
      [ "$_e" = "$_guard_key" ] && _force=true && break
    done
    if [ "$_force" != true ]; then
      log "Skipping $PKG_NAME (disabled)"
      return 1
    fi
    log "Force-enabling $PKG_NAME via --enable=$_guard_key"
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
        die "$PKG_NAME requires '$_cmd', which is not installed. Install it, or skip this package with --disable=$_guard_key."
      fi
    done
  fi

  # Meson guard. mediaforge builds both meson and ninja (recipes/tools/) ahead of
  # every consumer, so this should always pass — if it doesn't, those tool
  # recipes were disabled or failed to build. Fail loud rather than skip.
  if [ "$PKG_REQUIRES_MESON" = true ]; then
    if ! command_exists meson || ! command_exists ninja; then
      die "$PKG_NAME requires meson and ninja, which mediaforge builds in recipes/tools/. They are missing — the meson/ninja recipe was disabled or failed. Re-enable it, or skip this package with --disable=$_guard_key."
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

# load_recipe RECIPE_PATH
# Reset recipe state, derive PKG_HASH_FILE from the recipe's own path, source
# the recipe, and validate the fields every recipe must set. Shared by
# run_recipe() (full build lifecycle) and cmd_makesum() (fetch-only, in
# lib/makesum.sh) so the derivation lives in exactly one place — a helper only
# the new caller used would just be a second copy that drifts from this one.
load_recipe() {
  _recipe_path="$1"

  if [ ! -f "$_recipe_path" ]; then
    die "Recipe not found: $_recipe_path"
  fi

  # Reset state
  reset_recipe

  # Every recipe's checksums live in a sidecar beside its own .sh file, so the
  # lookup is derived from the path the caller already gave us rather than
  # threaded through fetch()'s argument list (which is already at its
  # three-argument ceiling).
  PKG_HASH_FILE="${_recipe_path%.sh}.hash"

  # Source the recipe to load its variables and phase overrides
  . "$_recipe_path"

  # Validate required fields (PKG_URL may be empty if PKG_SKIP_EXTRACT is true)
  if [ -z "$PKG_NAME" ] || [ -z "$PKG_VERSION" ]; then
    die "Recipe $_recipe_path missing required fields (PKG_NAME, PKG_VERSION)"
  fi
  if [ -z "$PKG_URL" ] && [ "$PKG_SKIP_EXTRACT" != true ]; then
    die "Recipe $_recipe_path missing PKG_URL (set PKG_SKIP_EXTRACT=true for header-only packages)"
  fi
}

# Run a single recipe file through the build lifecycle
run_recipe() {
  load_recipe "$1"

  # Queue this recipe's .pc files as not-for-install if it's a transitive
  # utility. We do this BEFORE check_guards / stamp_check so the queue is
  # populated even when the recipe is already-built or skipped — that is what
  # makes the answer a property of the build rather than of the subset of it
  # that recompiled. Default PKG_PC_FILES to "$PKG_NAME" when the recipe
  # didn't override. See lib/pc-exclusions.sh.
  if [ "$PKG_TRANSITIVE_UTIL" = true ]; then
    pc_exclusions_queue "${PKG_PC_FILES:-$PKG_NAME}"
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
    # Same registry identity check_guards used to decide the skip; comparing a
    # different name here would let a --disable=d recipe re-accumulate the very
    # FFmpeg flag the skip exists to suppress -- and "the skip" includes the
    # LICENCE tiers, so a wrong match here re-emits --enable-libx264 for a build
    # that never asked for --enable-gpl. Failing loud is the only answer that
    # cannot silently mislicense a binary; a fallback to any other identity can.
    # Fatal on the same terms as check_guards, and on stronger ones: this line is
    # only reached after check_guards returned, which means it already derived
    # the key, so a failure here is a state change between the two rather than a
    # missing value.
    _excl_key=$(recipe_key) || die "Cannot derive a CLI identity for '$PKG_NAME' while deciding whether to re-accumulate its FFmpeg flag, though check_guards derived one moments earlier. PKG_HASH_FILE changed mid-recipe."
    for _d in $DISABLE_PKGS; do
      [ "$_d" = "$_excl_key" ] && _excluded=true && break
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

  # Check stamp (stamp_check returns 1 if already built)
  if ! stamp_check "$PKG_NAME" "$PKG_VERSION"; then
    # Already built — accumulate ffmpeg option and skip
    accumulate_ffmpeg_opt
    return 0
  fi

  # Dry-run short-circuit: print intent, accumulate ffmpeg flag, skip download/build
  if [ "${DRY_RUN:-false}" = true ]; then
    log "Would build $PKG_NAME-$PKG_VERSION"
    accumulate_ffmpeg_opt
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

  # A recipe that declares a C standard gets it appended for the duration of its
  # own build. Applied after the save above and before any phase runs, so the
  # restore at the end of this function takes it back off again -- one recipe's
  # -std cannot leak into the next. GCC 15 defaults to -std=gnu23, which is what
  # made this necessary for the older sources in the tree (K&R definitions,
  # unprototyped functions, C23 reserved keywords).
  if [ -n "$PKG_C_STD" ]; then
    CFLAGS="$CFLAGS -std=$PKG_C_STD"
    export CFLAGS
  fi

  # Run phases.
  #
  # Staging (GH-59) wraps the two INSTALL phases only. DESTDIR is meaningful
  # nowhere else -- the GNU Coding Standards scope it to install targets -- and
  # narrowing the window keeps configure and build seeing exactly the
  # environment they saw before.
  #
  # That is true of the PHASES, not of everything that runs inside them. Four
  # recipes run a full configure+compile within the window (lv2's seven
  # sub-packages and opencl's ICD loader in pkg_install, libcdio's paranoia in
  # pkg_post_install, rav1e's cargo cinstall), so their sub-builds see DESTDIR
  # set. That is harmless for a build that does not install, and correct for one
  # that does -- but a NEW sub-build whose compile performs an internal install
  # to an absolute path outside $PREFIX would have it redirected into the stage
  # and discarded. That is exactly what a widened window did to gettext's
  # textstyle install before it was reverted, and it is why the window was
  # narrowed rather than widened.
  #
  # mf_stage_pending_reset before rather than after: a recipe that dies mid-build
  # leaves its accumulator behind, and the next recipe must not inherit it and
  # write another package's files into its own stamp.
  mf_stage_pending_reset
  mf_stage_reserved_reset
  pkg_prepare
  pkg_configure
  pkg_build

  mf_stage_begin
  pkg_install
  # Merge BEFORE pkg_post_install, which is the load-bearing ordering here.
  # Thirteen recipes' post_install reads back or deletes a file pkg_install put
  # in the live prefix: nine rewrite or rename an installed .pc (chromaprint,
  # srt, vmaf, openh264, vvenc, x265, xevd, xeve, and shaderc which renames
  # one), brotli and xvidcore delete shared libraries make install produced,
  # lcevc reads its own archives back, and libressl asserts libtls.pc exists.
  # Every one of them would read a path still sitting in the stage if this merge
  # waited for the stamp.
  #
  # CLAIM rather than merely commit: this recipe's own files must be out of
  # reach before any nested stamp_write can drain them. libcdio builds
  # libcdio-paranoia in its pkg_post_install and stamps it, which would
  # otherwise take all ~100 of libcdio's files into the paranoia stamp and leave
  # libcdio's own stamp empty. See mf_stage_claim.
  mf_stage_claim
  pkg_post_install
  # Catches the two recipes that INSTALL from post_install: x264's
  # `make install-lib-static` and libcdio's second `make install`. Both honour
  # DESTDIR, so both stage; without this their files would reach the prefix but
  # never a manifest. libcdio's paranoia build has already taken its own share
  # through its own stamp_write, so what this claims is whatever is left.
  mf_stage_claim
  mf_stage_end

  # Mark as done, draining this recipe's claimed files into the stamp.
  mf_stage_restore
  stamp_write "$PKG_NAME" "$PKG_VERSION"

  accumulate_ffmpeg_opt

  # Restore compiler flags
  CFLAGS="$_saved_cflags"
  CXXFLAGS="$_saved_cxxflags"
  LDFLAGS="$_saved_ldflags"
  CPPFLAGS="$_saved_cppflags"

  # Restore working directory
  cd "$_saved_dir" || die "Failed to restore working directory"

  set_current_package ""
}
