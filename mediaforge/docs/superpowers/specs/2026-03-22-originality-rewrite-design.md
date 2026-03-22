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

17 variables renamed to industry-standard build-system terminology. 5 variables kept (FFmpeg's own terms or no better alternative).

### Renamed

| Current | New | Standard from |
|---|---|---|
| `CWD` | `TOPDIR` | OpenWrt, Buildroot |
| `PACKAGES` | `DISTDIR` | Gentoo, FreeBSD ports, pkgsrc |
| `WORKSPACE` | `PREFIX` | GNU Autotools, FreeBSD, Homebrew |
| `CONFIGURE_OPTIONS` | `FFMPEG_CONFIGURE_OPTS` | Buildroot `_CONF_OPTS`, FreeBSD `CONFIGURE_ARGS` |
| `NVCC_FLAGS` | `NVCCFLAGS` | FFmpeg configure, Gentoo, CMake (`<COMPILER>FLAGS` convention) |
| `GPL` | `ENABLE_GPL` | FFmpeg `--enable-gpl` |
| `NONFREE` | `ENABLE_NONFREE` | FFmpeg `--enable-nonfree` |
| `LATEST` | `REBUILD_OUTDATED` | Descriptive (no prior art) |
| `MANPAGES` | `INSTALL_MANPAGES` | CMake `INSTALL_*` pattern |
| `SKIPINSTALL` | `SKIP_INSTALL` | Descriptive |
| `DISABLE_LV2` | `NO_LV2` | Matches `--disable-lv2` CLI flag, shorter |
| `IS_DARWIN` | `OS_MACOS` | Simplified `OS_` prefix |
| `IS_LINUX` | `OS_LINUX` | `OS_` prefix |
| `IS_MACOS_SILICON` | `OS_MACOS_ARM` | More precise |
| `IS_FREEBSD` | `OS_FREEBSD` | `OS_` prefix |
| `MULTIARCH` | `MULTIARCH_TRIPLET` | Debian, GCC |
| `MACOS_LIBTOOL` | `GNU_LIBTOOL` | Autotools convention |

### Kept (unchanged)

| Variable | Reason |
|---|---|
| `LDEXEFLAGS` | FFmpeg's own canonical term (via `--extra-ldexeflags`) |
| `EXTRALIBS` | FFmpeg's own `--extra-libs` parameter |
| `MJOBS` | No strong prior art for alternatives |
| `AUTOINSTALL` | No strong prior art either way |
| `INSTALL_FOLDER` | Subsumed by install rewrite (Section 5) -- variable ceases to exist |

Note: `SUDO` is a local variable in `lib/install.sh` only. It is subsumed by the install flow rewrite (Section 5) and does not need a rename entry.

### Propagation

Every reference to renamed variables must be updated. **High-risk files requiring careful review:**

- `mediaforge.sh` -- variable initialization, CLI parsing, main loop
- `lib/utils.sh` -- `$DISTDIR` in stamp functions (was `$PACKAGES`)
- `lib/download.sh` -- `$DISTDIR` (was `$PACKAGES`)
- `lib/cleanup.sh` -- `$TOPDIR` in `on_exit()` (was `$CWD`), `$DISTDIR` and `$PREFIX` in `full_cleanup()` (were `$PACKAGES` and `$WORKSPACE`). After variable renames and `remove_dir()` inlining (to `rm -rf`), `full_cleanup()` is sufficiently different from upstream's `cleanup()`.
- `lib/framework.sh` -- `$ENABLE_GPL`, `$ENABLE_NONFREE`, `$NO_LV2` in `check_guards()` (were `$GPL`, `$NONFREE`, `$DISABLE_LV2`); `$PREFIX` throughout (was `$WORKSPACE`). **Critical:** After `fetch()` no longer `cd`s into the source directory, `run_recipe()` must add `cd "$DISTDIR/$PKG_DIRNAME"` after calling `fetch()` to set the working directory for build phases.
- `lib/platform.sh` -- `$OS_MACOS`, `$OS_LINUX`, `$OS_MACOS_ARM`, `$OS_FREEBSD` (were `$IS_DARWIN`, `$IS_LINUX`, `$IS_MACOS_SILICON`, `$IS_FREEBSD`). Also replace `nproc`/`sysctl` CPU detection with POSIX `getconf _NPROCESSORS_ONLN` as primary (fallback chain: `getconf _NPROCESSORS_ONLN` -> `nproc` -> `sysctl -n hw.ncpu` -> `/proc/cpuinfo` via `awk` -> default `1`). Ultimate fallback is `1` (safer than upstream's `4` for unknown systems).
- `lib/install.sh` -- full rewrite (Section 5), no propagation needed
- `recipes/**/*.sh` -- `$PREFIX` (was `$WORKSPACE`), `$DISTDIR` (was `$PACKAGES`) in any recipe referencing these
- `recipes/other/lv2.sh` -- **HIGH RISK:** Calls `build()`/`build_done()` for 7 sub-packages (waflib, serd, pcre, zix, sord, sratom, lilv) with different package names than the parent recipe. All must become `stamp_check()`/`stamp_write()`. Also calls `download()` with positional args for sub-packages — must use `fetch()` positional arg fallback.
- `recipes/hwaccel/opencl.sh` -- **HIGH RISK:** Calls `build()`/`build_done()` for `opencl-icd-loader` sub-package, and calls `download()` with positional args inside `pkg_install()`. Same treatment as lv2.sh.
- `recipes/ffmpeg.sh` -- `$FFMPEG_CONFIGURE_OPTS` (was `$CONFIGURE_OPTIONS`), `$NVCCFLAGS` (was `$NVCC_FLAGS`)
- `recipes/hwaccel/nv-codec.sh` -- `$NVCCFLAGS` (was `$NVCC_FLAGS`)

---

## 3. Utility Function Rewrites

6 functions replaced with new names and structurally different implementations. 2 functions explicitly kept.

### `build()` / `build_done()` -> `stamp_check()` / `stamp_write()`

**Current:** Checks `$PACKAGES/$pkg.done`, reads version string from file contents, compares.

**New:**
- Stamps in `$PREFIX/.stamps/` (not alongside tarballs)
- Stamp filename encodes version: `.stamps/x264-0.164` (no `.done` extension)
- `stamp_check()` returns success if stamp file exists with matching version in filename
- `stamp_write()` creates the stamp file with `touch`
- `REBUILD_OUTDATED` mode: `stamp_check()` compares stamp filename against current `PKG_VERSION`

**Directory creation:** `$PREFIX/.stamps/` is created during setup in `mediaforge.sh` alongside `$PREFIX` and `$DISTDIR` (`mkdir -p`).

**Migration:** Existing `.done` files in `$DISTDIR/` (formerly `$PACKAGES/`) are NOT migrated. On first run after upgrade, all packages will rebuild. This is a known breaking change and is acceptable because: (a) stamps are cheap, (b) a full rebuild ensures consistency, (c) users upgrading from a derived version to the MIT version should start clean.

### `execute()` -> `run()`

**Current:** Captures output into a shell variable, prints on failure.

**New:**
- Redirects stdout+stderr to a log file: `$PREFIX/.logs/$PKG_NAME-$_phase.log` (phase-disambiguated)
- Phase names: `prepare`, `configure`, `build`, `install`, `post-install`
- On success: remove the log
- On failure: `cat` the log to stderr, then `die()`
- Side benefit: persistent build logs for debugging

**Directory creation:** `$PREFIX/.logs/` is created during setup in `mediaforge.sh` alongside other directories.

**Log lifecycle:** Each phase creates a fresh log. On success the log is removed. On failure the log persists for debugging. Successful recipes leave no log files. Failed recipes leave one log file for the failing phase.

### `execute_stdin()` -> `run_stdin()`

**Current:** Runs a command with stdin piped from the caller. Used by `recipes/video/x265.sh` for `ar -M` heredoc.

**New:** Same rename pattern as `execute()` -> `run()`. The implementation is rewritten to use the same log-file approach:
- Redirects stdout+stderr to `$PREFIX/.logs/$PKG_NAME-$_phase.log`
- Stdin is passed through from the caller
- On failure: `cat` the log to stderr, then `die()`

### `download()` -> `fetch()`

**Current:** Positional args `download(URL, FILENAME, DIRNAME)`, flat retry, tar auto-detection.

**New:**
- Reads `PKG_URL`, `PKG_FILENAME`, `PKG_DIRNAME` directly (no positional args)
- Exponential backoff retry (1s, 2s, 4s) instead of flat sleep
- Explicit archive type detection (`case` on extension for `.tar.gz`, `.tar.xz`, `.tar.bz2`, `.zip`)
- Does NOT `cd` into extracted directory (framework handles working directory)

**FFmpeg download:** `recipes/ffmpeg.sh` is not a standard recipe run through `run_recipe()` -- it is sourced directly by `mediaforge.sh` after all recipes complete. For the FFmpeg source download, `fetch()` supports a **positional arg fallback**: if `PKG_URL` is empty, `fetch "$url" "$filename" "$dirname"` works as before. This preserves compatibility for the FFmpeg build step and any future non-recipe downloads.

### `make_dir()` / `remove_dir()` -> removed

Inline `mkdir -p` and `rm -rf` at call sites. The upstream's creative choice was to extract these as named functions; the opposite choice (inlining) is equally valid and structurally different.

### Kept functions

| Function | Reason |
|---|---|
| `library_exists()` | Already SIMILAR to upstream (uses pkg-config return code vs. output check). Different enough to keep. |
| `print_flags()` | References standard env vars (`CFLAGS`, `LDFLAGS`, `LDEXEFLAGS`). Minor function, not worth rewriting for originality since the variable names it prints are either standard or kept FFmpeg terms. |

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

### Dispatch mechanism

The current `bflag`/`cflag` state variables are replaced by a subcommand dispatcher:

```sh
_cmd="${1:-build}"
shift 2>/dev/null || true

case "$_cmd" in
  build)          cmd_build "$@" ;;
  clean)          cmd_clean "$@" ;;
  install)        cmd_install "$@" ;;
  uninstall)      cmd_uninstall "$@" ;;
  check-updates)  cmd_check_updates "$@" ;;
  list-profiles)  cmd_list_profiles "$@" ;;
  help|-h|--help) cmd_help ;;
  version|--version) cmd_version ;;
  -*)             die "Unknown option: $_cmd (did you mean 'mediaforge build $_cmd'?)" ;;
  *)              die "Unknown command: $_cmd" ;;
esac
```

Each `cmd_*` function handles its own option parsing. Global options (none currently) would be parsed before the subcommand dispatch.

### Build Options

| Flag | Short | Description |
|---|---|---|
| `--enable-gpl` | `-g` | Enable GPL-licensed codecs |
| `--enable-nonfree` | `-G` | Enable non-free codecs (implies `--enable-gpl`) |
| `--disable-lv2` | `-L` | Skip LV2 plugin chain |
| `--enable-static` | `-s` | Full static binary (Linux only) |
| `--enable-small` | `-m` | Minimal build |
| `--profile=X.Y` | `-p` | Version profile |
| `--jobs=N` | `-j` | Parallel job count (default: auto-detect) |
| `--rebuild-outdated` | `-u` | Rebuild stale dependencies |
| `--no-install` | `-I` | Skip post-build install |
| `--yes` | `-y` | Non-interactive mode |
| `--verbose` | `-v` | Show build commands (`-vv` for compiler lines) |
| `--quiet` | `-q` | Errors only |
| `--dry-run` | `-n` | Show what would build without building |
| `--keep-going` | `-k` | Don't stop on first recipe failure |

### Option Parsing: Hybrid getopts + case

Each `cmd_*` function uses POSIX `getopts` for short options, then a `case` fallback for long options. This is portable and avoids external `getopt`.

```sh
cmd_build() {
  # Phase 1: getopts handles short options
  OPTIND=1
  while getopts "gGLsmp:j:Iyvqnkh" _opt; do
    case "$_opt" in
      g) ENABLE_GPL=true ;;
      G) ENABLE_NONFREE=true; ENABLE_GPL=true ;;
      L) NO_LV2=true ;;
      s) FULL_STATIC=true ;;
      m) ENABLE_SMALL=true ;;
      p) PROFILE_NAME="$OPTARG" ;;
      j) MJOBS="$OPTARG" ;;
      I) SKIP_INSTALL=true ;;
      y) AUTOINSTALL=true ;;
      v) VERBOSE=$((VERBOSE + 1)) ;;
      q) QUIET=true ;;
      n) DRY_RUN=true ;;
      k) KEEP_GOING=true ;;
      h) cmd_help; exit 0 ;;
      '?') exit 2 ;;
    esac
  done
  shift $((OPTIND - 1))

  # Phase 2: case handles remaining long options
  while [ $# -gt 0 ]; do
    case "$1" in
      --enable-gpl)        ENABLE_GPL=true ;;
      --enable-nonfree)    ENABLE_NONFREE=true; ENABLE_GPL=true ;;
      --disable-lv2)       NO_LV2=true ;;
      --enable-static)     FULL_STATIC=true ;;
      --enable-small)      ENABLE_SMALL=true ;;
      --profile=*)         PROFILE_NAME="${1#--profile=}" ;;
      --profile)           shift; PROFILE_NAME="$1" ;;
      --jobs=*)            MJOBS="${1#--jobs=}" ;;
      --jobs)              shift; MJOBS="$1" ;;
      --rebuild-outdated)  REBUILD_OUTDATED=true ;;
      --no-install)        SKIP_INSTALL=true ;;
      --yes)               AUTOINSTALL=true ;;
      --verbose)           VERBOSE=$((VERBOSE + 1)) ;;
      --quiet)             QUIET=true ;;
      --dry-run)           DRY_RUN=true ;;
      --keep-going)        KEEP_GOING=true ;;
      --)                  shift; break ;;
      -*)                  die "Unknown option: $1" ;;
      *)                   break ;;
    esac
    shift
  done
}
```

**How it works:** `getopts` consumes all leading short options and option groups (e.g., `-gvj8`). After `getopts` exhausts short options, the `while`/`case` loop handles any remaining `--long-form` arguments. Users can freely mix: `mediaforge build -gv --profile=7.1 --keep-going`.

**Note on `-vv`:** POSIX `getopts` handles repeated short options naturally. `-vv` is parsed as `-v -v`, incrementing `VERBOSE` twice.

### Backward compatibility

Old flags (`-b`, `--build`, `-c`, `--cleanup`, `--gpl`, `--nonfree`, `--latest`, `--small`, `--full-static`, `--skip-install`, `--auto-install`) are NOT supported. Using them produces an error with guidance:

```
Error: Unknown option '--gpl'. Did you mean 'mediaforge build --enable-gpl'?
```

This is a clean break, not a deprecation period.

### POSIX Compliance

- POSIX `getopts` for short options (portable across sh, dash, bash, ksh, zsh)
- Manual `while`/`case` for long options (no external `getopt`)
- All long options support `--option=value` syntax
- `--` end-of-options marker supported
- Exit codes: 0 success, 1 runtime error, 2 usage error
- `--help` output to stdout; usage errors to stderr

### New CLI state variables

The CLI redesign introduces new state variables not present in upstream:

| Variable | Set by | Used by |
|---|---|---|
| `FULL_STATIC` | `--enable-static` / `-s` | `mediaforge.sh` (sets `LDEXEFLAGS="-static -fPIC"`) |
| `ENABLE_SMALL` | `--enable-small` / `-m` | `recipes/ffmpeg.sh` (adds `--enable-small`) |
| `VERBOSE` | `--verbose` / `-v` (incremental) | `run()` function, progress output |
| `QUIET` | `--quiet` / `-q` | Progress output suppression |
| `DRY_RUN` | `--dry-run` / `-n` | `run_recipe()` (skip execution, print plan) |
| `KEEP_GOING` | `--keep-going` / `-k` | `run_recipe()` error handler |

Note: `vaapi.sh` and other recipes that check `LDEXEFLAGS` for static mode detection continue to work unchanged since `FULL_STATIC` sets `LDEXEFLAGS`.

### New flag implementation details

- **`--dry-run`**: Prints the recipe name, version, and action (build/skip) for each entry in `_order.conf` without executing. Format matches Ninja progress output. Stamp checks still run to determine skip/build status.
- **`--keep-going`**: On recipe failure, `run()` logs the error but does not call `die()`. Instead, the failed recipe is recorded and the loop continues. At the end, all failures are printed and the script exits 1 if any failed.
- **`--verbose` / `-v`**: Level 1 (`-v`) streams `run()` output to stderr in real-time (tee to log + stderr). Level 2 (`-vv`) also prints the full command being executed before running it.
- **`--quiet` / `-q`**: Suppresses progress output. Only errors are printed (to stderr).

### Progress Output (Ninja-style)

```
[12/53] Building libx264 v164...
[13/53] SKIP x265 v4.1 (up to date)
```

Compact single-line progress replacing verbose log output. `-v` for details.

---

## 5. Install / Uninstall Flow

Complete rewrite of `lib/install.sh`. Upstream only copies binaries with a Y/n prompt. Mediaforge adds library installation, interactive prefix selection, manifest tracking, and uninstall.

The current `INSTALL_FOLDER` and `SUDO` variables are eliminated. The new install flow uses its own local variables.

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

Writes a manifest: `$dest/.mediaforge-manifest` listing every installed file (relative paths).

Behavior modifiers:
- `--prefix=DIR` skips the menu
- `--yes` selects User (non-root) or System (root) automatically
- `--no-install` on `build` skips the install phase entirely

Privilege escalation: if the selected prefix requires root (e.g., `/usr/local`), `sudo` is used for copy commands. Detected by checking write permissions on the target directory (`[ -w "$_dest" ]`).

File installation uses POSIX tools only: `mkdir -p` for directories, `cp` for files, `chmod` for permissions. The `install` utility is NOT used (not POSIX-mandated).

### Uninstall

Discovers installs by scanning for `.mediaforge-manifest` in known locations (`/usr/local`, `$HOME/.local`):

```
Found mediaforge installations:
  1) System   /usr/local     (47 files, requires sudo)
  2) User     ~/.local       (47 files)

Uninstall from [1-2]:
```

Reads the manifest and removes every listed file. `--yes` skips confirmation. `--prefix=DIR` targets a specific location. If no manifest found, prints error and exits with code 1.

---

## 6. Recipe Fix Rewrites

~9 recipes where the specific fix implementation is creative expression copied from upstream. The fix itself (what it does) is functional; only the implementation needs to differ.

**Strategy change:** Convert inline `sed` fixes to `patch -p1` files stored in a new `patches/` directory. This is more auditable, version-trackable, and structurally different from the upstream's inline sed approach. `patch` is POSIX-mandated.

| Recipe | Derived fix | New approach |
|---|---|---|
| `libvorbis` | `force_cpusubtype_ALL` sed removal | `patch -p1 < patches/libvorbis-cpusubtype.patch` |
| `giflib` | Makefile doc/man sed removal | `patch -p1 < patches/giflib-makefile.patch` or `awk` rewrite |
| `libzmq` | `stats_proxy` sed fix | Verify if still needed; if so, `patch -p1` |
| `srt` | `lgcc_eh` pkgconfig sed fix | `awk` rewrite of pkgconfig file |
| `x265` | `lgcc_s` -> `lgcc_eh` pkgconfig sed | `awk` rewrite of pkgconfig file |
| `chromaprint` | `-lstdc++` appended to pkgconfig Libs via sed | `awk` rewrite of pkgconfig file |
| `openh264` | `-lstdc++` appended to pkgconfig Libs via sed | `awk` rewrite of pkgconfig file |
| `libjxl` | pkgconfig and cmake sed fixes (2 patterns) | `patch -p1` for cmake fix; `awk` for pkgconfig |
| `ffmpeg.sh` | `--extra-version` value | Use `--extra-version=mediaforge` unconditionally |

### Additional recipe notes

- **`xvidcore`** post-install cleanup (`rm -f libxvidcore.4.dylib`, `rm -f libxvidcore.so*`) matches upstream. After variable renames and `remove_dir()` inlining, the structure is sufficiently different. No additional action needed.
- **`ffmpeg.sh`** -- the `GIT_DIR=/nonexistent` workaround is a **different implementation** from upstream's `.git -> .git.bak` rename approach. No change needed. The `verify_binary_type` equivalent uses a different sed pattern. No change needed.

### Tooling guidelines for all recipes

| Task | Use | Avoid |
|---|---|---|
| Fix third-party source bugs | `patch -p1 < patches/name.patch` | Inline `sed` on source files |
| Fix pkgconfig/build metadata | `awk` with `-v` variables | `sed` (awk is better for field-based edits) |
| Simple single-line substitution | `sed 's/old/new/'` with `> tmp && mv tmp orig` | `sed -i` (not POSIX) |
| Template expansion | `awk` with `-v` or `sed` with multiple `-e` | `sed -i`, `envsubst` |
| CPU detection | `getconf _NPROCESSORS_ONLN` (POSIX) | `nproc` (Linux-only) |
| File installation | `cp` + `chmod` + `mkdir -p` | `install` (not POSIX) |
| Output | `printf` | `echo` (non-portable flags) |

### Patch directory structure

```
patches/
  libvorbis-cpusubtype.patch
  giflib-makefile.patch
  libzmq-stats-proxy.patch    (if still needed)
```

Patches are generated with `diff -u` and applied with `patch -p1`. Each patch targets a specific upstream version; version-specific patches can be gated with `case "$PKG_VERSION"` in the recipe's `pkg_prepare()` phase.

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
- **~20 original recipes** (pkg-config, m4, autoconf, automake, libtool, gettext, zimg, kvazaar, openh264, speex, twolame, gsm, libilbc, vo_amrwbenc, libtiff, libpng, libjxl, libwebp, openjpeg, librtmp, bs2b, ladspa, librist, libcaca, codec2, flite, libgme, libopenmpt, libshine, libsnappy)
- **All C23/GCC 15 compatibility fixes**
- **All `PKG_*` recipe variables** (part of the original framework)

Note: giflib has an original recipe structure but its sed patterns are derived (listed in Section 6). The recipe file will be modified but only the sed implementation changes.

---

## 8. Scope Summary

| Area | Units changed | Effort |
|---|---|---|
| Variable renames | 17 variables across all files | Medium (find+replace, but must verify every reference) |
| Utility function rewrites | 6 functions (4 new implementations, 2 removed) | Medium |
| Kept functions | 2 functions (explicitly unchanged) | None |
| CLI redesign | `mediaforge.sh` CLI parsing + dispatch | Medium |
| Install/uninstall flow | `lib/install.sh` (full rewrite) | High (new features: menu, libs, manifest, uninstall) |
| Progress output | `lib/utils.sh` or new `lib/progress.sh` | Low |
| Recipe sed rewrites | 6 recipes | Low |
| **Total** | | **~1-2 days focused work** |

---

## 9. Verification

After **all** implementation is complete, verify originality by:

1. Fetch upstream `build-ffmpeg` and run a text similarity analysis (e.g., `diff`, custom script)
2. Confirm no function names match upstream
3. Confirm no project-specific variable names match upstream
4. Confirm CLI flags and behavior are structurally different
5. Confirm install flow is structurally different
6. Syntax check all files: `for f in lib/*.sh recipes/**/*.sh; do sh -n "$f"; done`
7. Full build test: `mediaforge build --enable-gpl` (uses new CLI syntax -- only runnable after CLI redesign is complete)

Note: Steps 1-5 are originality checks. Steps 6-7 are functional checks. If implementing incrementally, run `sh -n` after each change and defer the full build test until the end.
