# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this project.

## Project

**mediaforge** — A POSIX shell build system that compiles FFmpeg 8.0.1 from source with ~50 modular dependency recipes. Rewrite of [markus-perl/ffmpeg-build-script](https://github.com/markus-perl/ffmpeg-build-script) from monolithic Bash to portable, maintainable `#!/bin/sh`.

## Commands

```sh
cd mediaforge/

# Build FFmpeg with free codecs only
./mediaforge.sh -b

# Build with GPL codecs (x264, x265, xvidcore, vid_stab)
./mediaforge.sh -b --gpl

# Build with GPL + non-free codecs (adds openssl, fdk-aac)
./mediaforge.sh -b --nonfree

# Rebuild outdated dependencies
./mediaforge.sh -b --latest

# Full static binary (Linux only)
./mediaforge.sh -b --full-static

# Clean all build artifacts
./mediaforge.sh -c

# Build with a specific FFmpeg version profile
./mediaforge.sh -b --profile 7.1

# List available version profiles
./mediaforge.sh --list-profiles

# Check for dependency updates on GitHub
./mediaforge.sh --check-updates
./mediaforge.sh --check-updates --profile 7.1

# Syntax check (no tests exist)
bash -n mediaforge.sh
for f in lib/*.sh recipes/**/*.sh; do sh -n "$f"; done
```

No test suite, linter config, or CI pipeline exists. Validate with `sh -n` syntax checks.

## Architecture

```
mediaforge.sh          → CLI parsing, sources lib/, iterates _order.conf, sources ffmpeg.sh + install.sh
lib/utils.sh           → execute(), log(), die(), build()/build_done() gating, command_exists()
lib/platform.sh        → IS_DARWIN/IS_LINUX/IS_MACOS_SILICON flags, MJOBS detection, MULTIARCH
lib/framework.sh       → run_recipe() lifecycle, reset_recipe(), check_guards(), default phases
lib/download.sh        → download(URL, [FILENAME, [DIRNAME]]) with cache + retry
lib/cleanup.sh         → EXIT/INT/TERM trap handler, preserves .done files on failure
lib/install.sh         → Post-build binary installation (ffmpeg, ffprobe, ffplay)
recipes/_order.conf    → Declarative build order (one recipe path per line)
recipes/ffmpeg.sh      → Final FFmpeg build consuming accumulated CONFIGURE_OPTIONS
recipes/{category}/    → ~50 package recipes (tools, crypto, video, audio, image, hwaccel, other)
```

**Build flow**: `mediaforge.sh` sources all `lib/*.sh`, parses CLI, then loops `_order.conf` calling `run_recipe()` for each. After all recipes, it reads `.extra_cflags`/`.extra_ldflags` accumulator files, sources `recipes/ffmpeg.sh`, then `lib/install.sh`.

## Version Profiles

Profile files live in `profiles/ffmpeg-X.Y.Z.conf` and pin all dependency versions for a given FFmpeg release. Four profiles ship: `8.0.1`, `7.1`, `7.0`, `6.1`.

When a profile is active (via `--profile X.Y`), it is sourced before recipes run, exporting `PKG_VERSION_<NAME>` variables. Recipes reference these with the pattern `${PKG_VERSION_NAME:-default}`, falling back to the recipe's own default when no profile is loaded.

## Recipe Framework

Each recipe is a shell file sourced by `run_recipe()`. It sets `PKG_*` variables and optionally overrides phase functions.

**Required variables**: `PKG_NAME`, `PKG_VERSION`, `PKG_URL`

**Key optional variables**:
- `PKG_FFMPEG_OPT` — FFmpeg configure flag(s) to accumulate (e.g., `--enable-libx264`)
- `PKG_GPL=true` / `PKG_NONFREE=true` — Licensing guards
- `PKG_SKIP_IF_NONFREE=true` — Mutual exclusion (gmp/nettle/gnutls skipped when openssl active)
- `PKG_REQUIRES_CMD="cargo python3"` — Command dependency guard
- `PKG_REQUIRES_MESON=true` / `PKG_LINUX_ONLY=true` / `PKG_SKIP_ON_ARCH="arm64"`
- `PKG_CMAKE=true` + `PKG_CMAKE_FLAGS` — Use cmake instead of autoconf
- `PKG_FILENAME`, `PKG_DIRNAME`, `PKG_SKIP_EXTRACT` — Download/extract overrides

**Phase functions** (override any subset):
```sh
pkg_prepare()       # Pre-build (patches, env setup)
pkg_configure()     # Default: ./configure or cmake based on PKG_CMAKE
pkg_build()         # Default: make -j "$MJOBS"
pkg_install()       # Default: make install
pkg_post_install()  # Post-install (extra flags, pkgconfig fixups)
```

**Compiler flags** are saved before each recipe and restored after, preventing cross-contamination. Recipes that need persistent flag changes write to `$WORKSPACE/.extra_cflags` or `$WORKSPACE/.extra_ldflags`.

## Shell Conventions

All code must be **POSIX sh** — no Bashisms:
- `[ "$var" = value ]` not `[[ ]]`
- `command -v` not `which`
- String concatenation not `+=`
- No arrays, no `=~`, no brace expansion, no process substitution
- Booleans are string comparisons: `[ "$IS_LINUX" = true ]`
- Use `printf` over `echo` for portability where output matters
- Prefix local-scope variables with `_` (e.g., `_pkg`, `_ver`) since POSIX sh has no `local`
- Use `sed ... > tmp && mv tmp orig` not `sed -i` (not portable)

## Working Directories

| Variable | Path | Purpose |
|---|---|---|
| `$CWD` | Invocation dir | User's working directory |
| `$PACKAGES` | `$CWD/packages` | Downloaded tarballs + extracted sources, `.done` files |
| `$WORKSPACE` | `$CWD/workspace` | Installed headers, libs, binaries, pkgconfig |

Build artifacts are fully isolated — no system modifications until explicit install step.
