# Mediaforge Originality Rewrite Design

**Date:** 2026-03-22
**Goal:** Eliminate derivative work from upstream [markus-perl/ffmpeg-build-script](https://github.com/markus-perl/ffmpeg-build-script) (GPL-3.0) so mediaforge can be released under the MIT license.
**Approach:** Surgical rename + rewrite of ~45 derived code units. ~40+ original units (recipe framework, profiles, update checker, ~20 original recipes, C23 fixes) are untouched.

---

## 1. Legal Basis

The upstream project is GPL-3.0. Mediaforge is a rewrite from monolithic Bash to modular POSIX sh. Analysis identified:

- **0 character-identical lines** (every line was at minimum Bash-to-POSIX converted)
- **~45 derived code units** (same logic with syntax changes)
- **~12 similar units** (same approach, meaningfully different implementation)
- **~8 functional units** (only correct way to do it, not copyrightable per merger doctrine)
- **~40+ original units** (no upstream equivalent)

### What is NOT copyrightable (no changes needed)

Per the **merger doctrine** and **scenes a faire**:

- **Configure flags** dictated by upstream projects (`--enable-static`, `--enable-pic`, `--prefix`)
- **x265 multilib build pattern** (12/10/8-bit dirs, cmake flags, `ar -M` merge) -- used by BtbN/FFmpeg-Builds, rdp/ffmpeg-windows-build-helpers, and documented by x265 upstream
- **Build order** determined by dependency graphs
- **Standard env vars** (`CFLAGS`, `LDFLAGS`, `PATH`, `PKG_CONFIG_PATH`)
- **Platform workarounds** (libvpx Darwin `--version-script` removal, known macOS fixes)

### What IS copyrightable (changes required)

- Utility function names + logic structure
- Project-specific variable names + initial values
- CLI flags and their behavior
- Install flow (prompts, cascade logic)
- Specific sed patterns in recipes (creative expression, not the fix itself)

---

## 2. Variable Renames

16 variables renamed to industry-standard build-system terminology. 6 variables kept (FFmpeg's own terms or no better alternative).

### Renamed

| Current | New | Standard from |
|---|---|---|
| `CWD` | `TOPDIR` | OpenWrt, Buildroot |
| `PACKAGES` | `DISTDIR` | Gentoo, FreeBSD ports, pkgsrc |
| `WORKSPACE` | `PREFIX` | GNU Autotools, FreeBSD, Homebrew |
| `CONFIGURE_OPTIONS` | `FFMPEG_CONFIGURE_OPTS` | Buildroot `_CONF_OPTS`, FreeBSD `CONFIGURE_ARGS` |
| `GPL` | `ENABLE_GPL` | FFmpeg `--enable-gpl` |
| `NONFREE` | `ENABLE_NONFREE` | FFmpeg `--enable-nonfree` |
| `LATEST` | `REBUILD_OUTDATED` | Descriptive (no prior art) |
| `MANPAGES` | `INSTALL_MANPAGES` | CMake `INSTALL_*` pattern |
| `SKIPINSTALL` | `SKIP_INSTALL` | Descriptive |
| `IS_DARWIN` | `OS_MACOS` | Simplified `OS_` prefix |
| `IS_LINUX` | `OS_LINUX` | `OS_` prefix |
| `IS_MACOS_SILICON` | `OS_MACOS_ARM` | More precise |
| `IS_FREEBSD` | `OS_FREEBSD` | `OS_` prefix |
| `MULTIARCH` | `MULTIARCH_TRIPLET` | Debian, GCC |
| `MACOS_LIBTOOL` | `GNU_LIBTOOL` | Autotools convention |
| `INSTALL_FOLDER` | `DESTDIR` | GNU Coding Standards |

### Kept (unchanged)

| Variable | Reason |
|---|---|
| `LDEXEFLAGS` | FFmpeg's own canonical term |
| `EXTRALIBS` | FFmpeg's own `--extra-libs` parameter |
| `NVCCFLAGS` | Standard `<COMPILER>FLAGS` convention (FFmpeg, Gentoo, CMake) |
| `MJOBS` | No strong prior art for alternatives |
| `AUTOINSTALL` | No strong prior art either way |
| `SUDO` → `SUDO_CMD` | Minor rename to common convention |

### Propagation

Every `PKG_*` recipe variable references to renamed variables must be updated. For example:
- `$PACKAGES` -> `$DISTDIR` in `lib/download.sh`, `lib/utils.sh`, `lib/cleanup.sh`, `mediaforge.sh`
- `$WORKSPACE` -> `$PREFIX` in all recipes, `lib/framework.sh`, `mediaforge.sh`
- etc.

---

## 3. Utility Function Rewrites

5 functions replaced with new names and structurally different implementations.

### `build()` / `build_done()` -> `stamp_check()` / `stamp_write()`

**Current:** Checks `$PACKAGES/$pkg.done`, reads version string from file contents, compares.

**New:**
- Stamps in `$PREFIX/.stamps/` (not alongside tarballs)
- Stamp filename encodes version: `.stamps/x264-0.164` (no `.done` extension)
- `stamp_check()` returns success if stamp file exists with matching version in filename
- `stamp_write()` creates the stamp file with `touch`
- `REBUILD_OUTDATED` mode: `stamp_check()` compares stamp filename against current `PKG_VERSION`

### `execute()` -> `run()`

**Current:** Captures output into a shell variable, prints on failure.

**New:**
- Redirects stdout+stderr to a log file: `$PREFIX/.logs/$PKG_NAME.log`
- On success: remove the log
- On failure: `cat` the log to stderr, then `die()`
- Side benefit: persistent build logs for debugging

### `download()` -> `fetch()`

**Current:** Positional args `download(URL, FILENAME, DIRNAME)`, flat retry, tar auto-detection.

**New:**
- Reads `PKG_URL`, `PKG_FILENAME`, `PKG_DIRNAME` directly (no positional args)
- Exponential backoff retry (1s, 2s, 4s) instead of flat sleep
- Explicit archive type detection (`case` on extension for `.tar.gz`, `.tar.xz`, `.tar.bz2`, `.zip`)
- Does NOT `cd` into extracted directory (framework handles working directory)

### `make_dir()` / `remove_dir()` -> removed

Inline `mkdir -p` and `rm -rf` at call sites. The upstream's creative choice was to extract these as named functions; the opposite choice (inlining) is equally valid and structurally different.

---

## 4. CLI Redesign

Complete redesign from flag-based to subcommand-based, following POSIX/GNU/autotools conventions.

### Subcommands

```
mediaforge build [options]
mediaforge clean
mediaforge install [--prefix=DIR] [--yes]
mediaforge uninstall [--prefix=DIR] [--yes]
mediaforge check-updates [--profile=X.Y]
mediaforge list-profiles
mediaforge help
mediaforge version
```

### Build Options

| Flag | Short | Description |
|---|---|---|
| `--enable-gpl` | | Enable GPL-licensed codecs |
| `--enable-nonfree` | | Enable non-free codecs (implies `--enable-gpl`) |
| `--disable-lv2` | | Skip LV2 plugin chain |
| `--enable-static` | | Full static binary (Linux only) |
| `--enable-small` | | Minimal build |
| `--profile=X.Y` | `-p` | Version profile |
| `--jobs=N` | `-j` | Parallel job count (default: auto-detect) |
| `--rebuild-outdated` | | Rebuild stale dependencies |
| `--no-install` | | Skip post-build install |
| `--yes` | `-y` | Non-interactive mode |
| `--verbose` | `-v` | Show build commands (`-vv` for compiler lines) |
| `--quiet` | `-q` | Errors only |
| `--dry-run` | `-n` | Show what would build without building |
| `--keep-going` | `-k` | Don't stop on first recipe failure |

### POSIX Compliance

- Manual `while`/`case` parsing (no external `getopt`)
- All long options support `--option=value` syntax
- `--` end-of-options marker supported
- Exit codes: 0 success, 1 runtime error, 2 usage error
- `--help` output to stdout; usage errors to stderr

### Progress Output (Ninja-style)

```
[12/53] Building libx264 v164...
[13/53] SKIP x265 v4.1 (up to date)
```

Compact single-line progress replacing verbose log output. `-v` for details.

---

## 5. Install / Uninstall Flow

Complete rewrite. Upstream only copies binaries with a Y/n prompt. Mediaforge adds library installation, interactive prefix selection, manifest tracking, and uninstall.

### Install

Interactive System/User/Other selection menu:

```
Install location:
  1) System   /usr/local     (requires sudo)
  2) User     ~/.local
  3) Other    enter custom path

Select [1-3]:
```

Installs:
- `bin/ffmpeg`, `bin/ffprobe`, `bin/ffplay`
- `lib/*.a` (static libraries)
- `lib/pkgconfig/*.pc` (rewritten with new prefix)
- `include/` (development headers)
- `share/man/man1/` (man pages, unless `--no-manpages`)

Writes a manifest: `$DESTDIR/.mediaforge-manifest` listing every installed file.

Behavior modifiers:
- `--prefix=DIR` skips the menu
- `--yes` selects User (non-root) or System (root) automatically
- `--no-install` on `build` skips the install phase entirely

### Uninstall

Discovers installs by scanning for `.mediaforge-manifest` in known locations:

```
Found mediaforge installations:
  1) System   /usr/local     (47 files, requires sudo)
  2) User     ~/.local       (47 files)

Uninstall from [1-2]:
```

Reads the manifest and removes every listed file. `--yes` skips confirmation. `--prefix=DIR` targets a specific location.

---

## 6. Recipe Sed Pattern Rewrites

~6 recipes where the specific sed expression is creative expression copied from upstream. The fix itself (what the sed does) is functional; only the sed implementation needs to differ.

| Recipe | Derived sed pattern | Change |
|---|---|---|
| `libvorbis` | `force_cpusubtype_ALL` removal | Different sed approach or `autoreconf` |
| `giflib` | Makefile doc/man target removal | Different sed pattern or `make` target override |
| `libzmq` | `stats_proxy` fix | Verify if still needed; rewrite sed |
| `srt` | `lgcc_eh` pkgconfig fix | Different sed implementation |
| `x265` | `lgcc_s` -> `lgcc_eh` in pkgconfig | Different sed implementation |
| `ffmpeg.sh` | `--extra-version` value | Use `--extra-version=mediaforge` |

---

## 7. What Does NOT Change

The following are already original and require no modification:

- **Recipe framework** (`lib/framework.sh`): `run_recipe()`, `reset_recipe()`, `check_guards()`, phase functions, `_order.conf`
- **Version profiles** (`profiles/*.conf`, `PKG_VERSION_*` pattern)
- **Update checker** (`lib/updates.sh`, `--check-updates`, `PKG_GITHUB_REPO`)
- **Logging** (`log()`, `warn()`, `die()`)
- **Trap handling** (`on_exit()`, `setup_traps()`, `_CURRENT_PACKAGE` tracking)
- **Compiler flag save/restore** between recipes
- **Extra flags accumulators** (`.extra_cflags`, `.extra_ldflags`)
- **~20 original recipes** (giflib, pkg-config, m4, autoconf, automake, libtool, gettext, zimg, kvazaar, openh264, speex, twolame, gsm, libilbc, vo_amrwbenc, libtiff, libpng, libjxl, libwebp, openjpeg, librtmp, bs2b, ladspa, librist, libcaca, codec2, flite, libgme, libopenmpt, libshine, libsnappy)
- **All C23/GCC 15 compatibility fixes**
- **All `PKG_*` recipe variables** (part of the original framework)

---

## 8. Scope Summary

| Area | Units changed | Effort |
|---|---|---|
| Variable renames | 16 variables across all files | Medium (find+replace, but must verify every reference) |
| Utility function rewrites | 5 functions (3 new implementations, 2 removed) | Medium |
| CLI redesign | `mediaforge.sh` CLI parsing section | Medium |
| Install/uninstall flow | `lib/install.sh` (full rewrite) | High (new features: menu, libs, manifest, uninstall) |
| Progress output | `lib/utils.sh` or new `lib/progress.sh` | Low |
| Recipe sed rewrites | 6 recipes | Low |
| **Total** | | **~1-2 days focused work** |

---

## 9. Verification

After implementation, verify originality by:

1. Fetch upstream `build-ffmpeg` and run a text similarity analysis (e.g., `diff`, custom script)
2. Confirm no function names match upstream
3. Confirm no project-specific variable names match upstream
4. Confirm CLI flags and behavior are structurally different
5. Confirm install flow is structurally different
6. Syntax check all files: `for f in lib/*.sh recipes/**/*.sh; do sh -n "$f"; done`
7. Full build test: `mediaforge build --enable-gpl`
