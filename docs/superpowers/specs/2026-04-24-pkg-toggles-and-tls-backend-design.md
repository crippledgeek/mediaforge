# Package Toggles, TLS Backend Selector, and Interactive Menu

**Status:** Draft — awaiting user review
**Date:** 2026-04-24
**Branch:** `feature/pkg-toggles-and-tls-backend`
**Origin:** mediaforge's `openssl` recipe currently embeds `tls_openssl.o` into
`libavformat.a`, which blocks linking `wreq`+BoringSSL into the Rust `rdlp`
project on this host (see `project_mediaforge-ffmpeg-openssl` memory).

## 1. Goals

1. Let the user pick a TLS backend at build time without touching recipe files,
   and without coupling the choice to `--enable-nonfree`.
2. Generalise package enable/disable selection so **any** recipe can be toggled
   from the CLI by name, with typo-safe validation.
3. Introduce a declarative notion of mutually-exclusive recipe groups (TLS, AAC,
   H.264, H.265, AV1 encoder) and enforce "at most one" at both CLI and
   interactive layers.
4. Offer an optional interactive menu (`--menu`) for discoverability across the
   ~80 recipes, with a POSIX-sh fallback when `whiptail` is absent.
5. Prompt — once per group, interactively — when a licence flag enables more
   than one member of a mutex group and the user did not pick explicitly.
6. Preserve non-interactive (`--yes` / CI) behaviour with documented defaults.

## 2. Non-Goals

- Replacing the existing `while/case` long-option parser with a third-party
  library (e.g. `ko1nksm/getoptions`). The current parser works; adding a
  codegen step is not justified.
- Auto-installing `whiptail`. If it is missing, the POSIX fallback runs.
- Supporting `kdialog`/`zenity`/GUI fallbacks. Terminal only.
- Providing "Did you mean X?" via Levenshtein distance. Substring match is
  sufficient for a recipe list of ~80 names.
- A recipe dependency resolver. Order is still controlled by `_order.conf`.

## 3. Terminology

- **Recipe name** — the value of `PKG_NAME` in a recipe file; also the stem of
  the recipe file path under `recipes/<category>/<name>.sh`.
- **Mutex group** — a named set of recipes, at most one of which may be active
  in a single build. Declared by `PKG_MUTEX_GROUP="<group>"` in the recipe.
- **Explicit choice** — a per-group CLI flag (`--tls=`, `--aac=`, `--h264=`,
  `--h265=`, `--av1-enc=`) or an interactive selection.
- **Conservative default** — the group member chosen when running
  non-interactively and the user made no explicit choice.

## 4. Mutex Groups

| Group | Members | Conservative default (non-interactive) | Skip if |
|---|---|---|---|
| `tls` | `openssl`, `gnutls`, `mbedtls`, `libressl`, (sentinel `none`) | `gnutls` | N/A — always resolved |
| `aac` | `fdk_aac`, (sentinel `native`) | `native` | N/A — native is always on |
| `h264` | `x264`, `openh264` | `x264` if `--enable-gpl`, else `openh264` | Skip group if neither `--enable-gpl` nor explicit choice |
| `h265` | `x265`, `kvazaar` | `x265` if `--enable-gpl`, else `kvazaar` | Skip group if neither `--enable-gpl` nor explicit choice |
| `av1-enc` | `svtav1`, `rav1e`, `libaom` | `svtav1` | N/A |

`libressl` and `mbedtls` are new recipes added as part of this branch. The
CLI value `libressl` refers to LibreSSL's `libtls` library; the recipe
installs LibreSSL, and FFmpeg is configured with `--enable-libtls` (FFmpeg's
flag name for the same thing). Using the project name `libressl` at the CLI
layer avoids confusion with the FFmpeg internal flag name. The `none`
sentinel for `tls` means no TLS backend — HTTPS/RTMPS/SRT-encrypted inputs
are disabled at the FFmpeg layer.

`native` for `aac` is also a sentinel (no recipe); it means "use FFmpeg's
built-in AAC encoder", which is always compiled in.

**Patent caveat for `h264` group.** Both `x264` and `openh264` are
patent-encumbered when built from source. `openh264`'s BSD-3 source license
covers the *code*, not the H.264 patents — Cisco's royalty-free distribution
applies only to their pre-built binary download, not to a source build
linked into mediaforge's `libavcodec.a`. Choosing between them is a
software-license trade-off (GPL vs BSD), not a patent trade-off. End users
distributing binaries built from either remain liable for MPEG-LA royalties
unless they qualify for an exemption. Document this in `docs/cli-flags.md`.

## 5. CLI Surface

### 5.1 New flags

```
--tls=BACKEND         openssl|gnutls|mbedtls|libressl|none
--aac=IMPL            fdk_aac|native
--h264=IMPL           x264|openh264
--h265=IMPL           x265|kvazaar
--av1-enc=IMPL        svtav1|rav1e|libaom
--disable=PKG         Disable a recipe by name. Repeatable; may also be comma-separated.
--enable=PKG          Force-enable a recipe that defaults to off. Repeatable.
--menu                Launch interactive selector (whiptail preferred, POSIX fallback otherwise).
--list-pkgs           Print every recipe name with its category and mutex group, then exit 0.
```

**`--enable=PKG` override scope.** `--enable=` overrides only the
recipe-level `PKG_DISABLED=true` flag and any `--disable=PKG` token earlier
on the same command line. It does **not** override licence guards
(`PKG_GPL`, `PKG_NONFREE`), platform guards (`PKG_LINUX_ONLY`,
`PKG_SKIP_ON_ARCH`), or required-command guards (`PKG_REQUIRES_CMD`). To
build `fdk_aac`, the user still needs `--enable-nonfree`. To build a
GPL-only recipe, the user still needs `--enable-gpl`. This keeps licence
opt-in explicit and prevents accidental nonfree linkage via an
auto-completed `--enable=` token.

### 5.2 Preserved flags

All existing flags continue to work unchanged: `--enable-gpl`, `--enable-nonfree`,
`--enable-static`, `--enable-small`, `--disable-lv2`, `--profile=`, `--jobs=`,
`--rebuild-outdated`, `--no-install`, `--yes`, `--verbose`, `--quiet`,
`--dry-run`, `--keep-going`.

`--disable-lv2` becomes an alias for `--disable=lv2`.

### 5.3 Validation

After arg parsing, every token in `DISABLE_PKGS` and `ENABLE_PKGS` is matched
against the recipe-name registry derived from `_order.conf`. Unknown tokens
abort with a substring-match suggestion:

```
Unknown package: opssl. Did you mean: openssl ?
Unknown package: xyz. Run 'mediaforge.sh --list-pkgs' to see all.
```

Per-group flags validate against an enum with a fixed list.

## 6. Mutex Resolution Algorithm

Run after all flag parsing, before the main build loop.

1. **Build the "candidate active" set** — every recipe whose guards pass given
   the current licence flags (`ENABLE_GPL`, `ENABLE_NONFREE`, architecture,
   OS, required commands).
2. **Subtract** every name in `DISABLE_PKGS`.
3. **For each mutex group**:
   1. Count group members remaining active.
   2. If count ≤ 1 → group is resolved.
   3. If the user passed an explicit per-group flag → disable all other
      members of the group.
   4. Else if interactive (stdin is a TTY AND `AUTOINSTALL != yes`) →
      prompt the user (radiolist or numbered-read fallback). Add non-chosen
      members to `DISABLE_PKGS`.
   5. Else → apply the conservative default for the group. Log the auto-choice
      to stdout.
4. **Log the final choice matrix** at INFO level before the build loop.

The algorithm is idempotent: re-running it with the resolved choices produces
the same result (no further prompts).

## 7. Interactive Menu (`--menu`)

Activated only when `--menu` is passed. Always interactive — rejects `--yes`
combined with `--menu` at parse time.

### 7.1 whiptail path (preferred)

Detection: `command -v whiptail`.

Four screens, shown in order:

1. **Licence tier** — radiolist: `free` / `gpl` / `nonfree`. Translates to
   `ENABLE_GPL` / `ENABLE_NONFREE`.
2. **Build options** — checklist with `--separate-output`:
   `static`, `small`, `lv2`, `rebuild-outdated`.
3. **Mutex group picks** — one radiolist per group where the current licence
   tier leaves more than one member active. Default-selected item matches the
   conservative default (§4).
4. **Per-recipe overrides** — scrollable checklist of every remaining recipe,
   pre-ticked according to current state. User may untick to add to
   `DISABLE_PKGS` or tick to add to `ENABLE_PKGS`.

Exit handling:
- Exit 0 with selections → continue with selections.
- Exit 0 with empty stdout → user pressed OK without ticking any item;
  treat as "no overrides for this screen", continue. (whiptail does not
  conflate this with Cancel.)
- Exit 1 (Cancel) → abort with "menu cancelled".
- Exit 255 (ESC/error) → abort with "menu aborted".

### 7.2 POSIX fallback

When `whiptail` is absent, a new `lib/menu.sh` provides two primitives:

```sh
menu_radiolist "Title" default_tag tag1 "desc1" tag2 "desc2" ...   # echoes chosen tag
menu_checklist "Title" "tag1=on" "tag2=off" ...                    # echoes chosen tags, one per line
```

Both display a numbered list via `printf`, read input via `read`, and loop
until a valid selection is confirmed (empty line with at least one choice for
checklist; any valid number for radiolist). Purely POSIX — no Bash-isms.

The same four-screen flow as §7.1 applies; each screen calls the appropriate
primitive.

## 8. Smart Prompts (Without `--menu`)

Even without `--menu`, mutex resolution (§6 step 3.iv) may prompt. This is the
"user enabled nonfree without picking a TLS backend" case.

Prompt UI reuses the same `menu_radiolist` primitive (or `whiptail --radiolist`
when available). Each prompt asks once per unresolved group and defaults the
cursor to the conservative-default member.

Skipped entirely when:
- `AUTOINSTALL=yes` (i.e. `--yes` / `-y`)
- stdin is not a TTY (`! [ -t 0 ]`)
- `$CI` is set (common convention for continuous-integration environments)

In any of those, the conservative default is applied and logged.

## 9. Persistence of Choices

On a successful run, the resolved choice matrix is written to
`$PREFIX/.mediaforge-choices` as a simple `KEY=VALUE` file:

```
TLS_BACKEND=gnutls
AAC_IMPL=native
H264_IMPL=x264
H265_IMPL=x265
AV1_ENC_IMPL=svtav1
DISABLE_PKGS=libbluray,zvbi
ENABLE_PKGS=
```

On subsequent runs, this file is sourced **before** mutex resolution, so the
previous picks become the in-memory defaults. Explicit CLI flags override;
`--menu` ignores the file (user is re-choosing explicitly).

A new `clean` subcommand option `--clean-choices` deletes this file.

**Profile-switch interaction:** `.mediaforge-choices` lives in `$PREFIX`,
which is shared across profiles on the same host. Switching profiles does
**not** automatically invalidate stored choices — the resolver merges
profile defaults (§11) *under* the stored choices, so a user who picked
`openssl` on one profile keeps `openssl` when switching. To reset, run
`--clean-choices` or `--menu`.

## 10. Recipe Changes

### 10.1 Reset block (`lib/framework.sh:reset_recipe`)

Add:
```sh
PKG_MUTEX_GROUP=""
```

### 10.2 Guard block (`lib/framework.sh:check_guards`)

Add one new block at the top of the function:

```sh
for _d in $DISABLE_PKGS; do
  [ "$_d" = "$PKG_NAME" ] && { log "Skipping $PKG_NAME (disabled)"; return 1; }
done
```

Remove the dedicated `NO_LV2` block; `--disable-lv2` is now an alias for
`--disable=lv2` (see §5.2) and flows through the generic path.

Remove `PKG_SKIP_IF_NONFREE` handling; it is superseded by mutex groups.

### 10.3 Recipe declarations

- `recipes/crypto/openssl.sh` — add `PKG_MUTEX_GROUP="tls"`, drop `PKG_NONFREE=true`.
- `recipes/crypto/gnutls.sh` — add `PKG_MUTEX_GROUP="tls"`, drop `PKG_SKIP_IF_NONFREE=true`.
- `recipes/crypto/gmp.sh`, `recipes/crypto/nettle.sh` — drop `PKG_SKIP_IF_NONFREE=true`;
  these are gnutls build-deps and are handled by the gnutls recipe's guard
  (active only when `tls=gnutls`).
- `recipes/crypto/mbedtls.sh` **(new)** — `PKG_MUTEX_GROUP="tls"`. Configure
  with `-DUSE_SHARED_MBEDTLS_LIBRARY=Off -DUSE_STATIC_MBEDTLS_LIBRARY=On
  -DENABLE_PROGRAMS=Off -DENABLE_TESTING=Off` (cmake) so the recipe
  produces only static `.a` archives, matching the rest of the toolchain.
- `recipes/crypto/libressl.sh` **(new)** — `PKG_MUTEX_GROUP="tls"`, providing
  libtls. Configure with `--disable-shared --enable-static
  --disable-asm-tests` (autoconf), again static-only. Verify the resulting
  `libtls.a` is found by FFmpeg's pkg-config probe (LibreSSL ships
  `libtls.pc`).
- `recipes/audio/fdk_aac.sh` — add `PKG_MUTEX_GROUP="aac"` (keep `PKG_NONFREE=true`).
- `recipes/video/x264.sh` — add `PKG_MUTEX_GROUP="h264"`.
- `recipes/video/openh264.sh` — add `PKG_MUTEX_GROUP="h264"`.
- `recipes/video/x265.sh` — add `PKG_MUTEX_GROUP="h265"`.
- `recipes/video/kvazaar.sh` — add `PKG_MUTEX_GROUP="h265"`.
- `recipes/video/svtav1.sh` — add `PKG_MUTEX_GROUP="av1-enc"`.
- `recipes/video/rav1e.sh` — add `PKG_MUTEX_GROUP="av1-enc"`.
- `recipes/video/av1.sh` (libaom) — add `PKG_MUTEX_GROUP="av1-enc"`.

### 10.4 Build-dependency chains

The gmp→nettle→gnutls chain only runs when `tls=gnutls`. Since gmp and nettle
have no `PKG_MUTEX_GROUP`, they rely on the generic `DISABLE_PKGS` path: when
`tls=openssl` the resolution layer pushes `gmp`, `nettle`, `gnutls` onto
`DISABLE_PKGS`. This is expressed as a small lookup table in `lib/resolve.sh`:

```sh
tls_disable_companions() {
  case "$1" in
    gnutls)  echo "openssl mbedtls libressl" ;;
    openssl) echo "gnutls gmp nettle mbedtls libressl" ;;
    mbedtls) echo "openssl gnutls gmp nettle libressl" ;;
    libressl) echo "openssl gnutls gmp nettle mbedtls" ;;
    none)    echo "openssl gnutls gmp nettle mbedtls libressl" ;;
  esac
}
```

## 11. Profiles

### 11.1 Precedence (definitive)

Sources of truth for the final choice matrix, highest precedence first:

1. Explicit CLI flag (`--tls=`, `--enable=`, etc.)
2. `--menu` selections (when `--menu` is passed; ignores the stored file)
3. Smart-prompt answers from the current run (§8)
4. `$PREFIX/.mediaforge-choices` (stored choices from the previous run)
5. Active profile's `*_DEFAULT` value
6. Global conservative default (§4)

Each lower level is consulted only when the higher level did not set a value.
Conflicts within a single level (e.g. `--tls=openssl` and `--tls=gnutls`) are
last-wins with a warning logged.

### 11.2 Profile defaults

Each `profiles/ffmpeg-*.conf` may declare group defaults:

```sh
TLS_BACKEND_DEFAULT=gnutls
AAC_IMPL_DEFAULT=native
H264_IMPL_DEFAULT=x264
H265_IMPL_DEFAULT=x265
AV1_ENC_IMPL_DEFAULT=svtav1
```

Absent values fall back to the global conservative defaults in §4.
Explicit CLI flags and the `.mediaforge-choices` file both override the
profile defaults.

## 12. Testing

No compilation, no network. Two harnesses live under `tests/`:

### 12.1 `tests/shellcheck.sh`

Runs `sh -n` on every `.sh` file in the tree, then `shellcheck -s sh` where
available. CI-friendly: exit non-zero on first failure unless `-k`.

### 12.2 `tests/dry-run-matrix.sh`

For each cell in the matrix (TLS backend × licence tier × `--enable-static`
on/off × one representative profile), invokes:

```sh
./mediaforge.sh build --dry-run --yes --tls=<backend> [flags]
```

and asserts that the produced `FFMPEG_CONFIGURE_OPTS` contains the expected
`--enable-<tls>` (and no other TLS flag), plus the expected licence flags.
Failures print the full opts line and the delta.

### 12.3 Negative tests

- `--disable=opssl` → exits non-zero, stderr mentions "Did you mean: openssl".
- `--tls=bogus` → exits non-zero with enum error.
- `--tls=openssl --tls=gnutls` → last-wins with a warn line (parser already
  does this; test locks it in).
- `--tls=gnutls --disable=gnutls` → exits non-zero, stderr explicitly names
  the contradiction.
- `--enable=fdk_aac` (without `--enable-nonfree`) → fdk_aac still skipped;
  log line confirms "PKG_NONFREE guard prevented force-enable".

### 12.4 Menu and smart-prompt verification

These paths are interactive; they are validated two ways:

- **Scripted stdin** for the POSIX fallback path: `printf '2\n\n' |
  ./mediaforge.sh build --dry-run` simulates choosing item 2 then confirming.
  The harness asserts the resulting `FFMPEG_CONFIGURE_OPTS` matches.
- **Manual checklist** in `docs/menu.md` for the whiptail path. Each release
  candidate is exercised against the checklist before merge to `develop`.

No automated whiptail tests; the dependency on a real terminal is too high
relative to the value of catching regressions in a stable third-party
binary.

## 13. Documentation

- `CLAUDE.md` §"Recipe Framework" — new `PKG_MUTEX_GROUP` entry.
- `CLAUDE.md` §"CLI Structure" — new flags.
- `CLAUDE.md` §"Commands" — example invocations for common TLS backends.
- New `docs/cli-flags.md` — complete recipe listing with category + mutex
  group, plus the H.264 patent caveat from §4. Generated by piping
  `mediaforge.sh --list-pkgs` into the file at release time.
- New `docs/menu.md` — walkthrough screenshots (ASCII) of the `--menu` flow.

`--list-pkgs` implementation: derive recipe name from the file path
(`recipes/<category>/<name>.sh` → name); read `PKG_MUTEX_GROUP` and
`PKG_GPL`/`PKG_NONFREE` via `grep` (one regex per attribute) rather than
sourcing each recipe. This keeps the command fast (~80 files, <50 ms) and
side-effect-free.

## 14. Migration Notes

Breaking changes — none user-visible in default flow, because:
- Default build (no flags) still yields a free build. It used to have no TLS
  backend compiled in (since openssl was nonfree-gated and gnutls was
  nonfree-skipped). Now the default is `--tls=gnutls`, which **adds** HTTPS
  support to the default build. This is an improvement; documented in
  `MEMORY.md`.
- `--enable-nonfree` no longer implies `--tls=openssl`. Users depending on
  that should pass `--tls=openssl` explicitly, or use `--menu` to confirm.
  The prompt in §8 covers interactive users automatically.
- Conversely, `--tls=openssl` now works under a free build (without
  `--enable-nonfree`). OpenSSL's Apache-2.0 license is compatible with
  FFmpeg's LGPL core. The former `PKG_NONFREE=true` on openssl was a
  mediaforge-internal artefact, not a license requirement. Users who want
  openssl in a license-clean build can now request it.

Internal (recipe-level) breaking changes:
- `PKG_SKIP_IF_NONFREE` removed from the reset block and guard logic. Any
  out-of-tree recipe relying on it must migrate to `PKG_MUTEX_GROUP`.

## 15. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| `whiptail` absent on a user's host | POSIX fallback in `lib/menu.sh` |
| Profile adds a TLS backend default that conflicts with CLI `--tls=` | CLI wins; log a `notice` line documenting the override |
| `.mediaforge-choices` goes stale after recipe rename | File is in `$PREFIX` which is cleaned by `mediaforge.sh clean`; additionally `--clean-choices` subcommand |
| User passes `--disable=gnutls` while `--tls=gnutls` (self-contradiction) | Detected in mutex resolution; aborts with explicit error |
| New `mbedtls` / `libressl` recipes drift from upstream | Standard `check-updates` subcommand already tracks GitHub releases; add the two new repos to its registry |

## 16. Implementation Order

1. Framework: add `PKG_MUTEX_GROUP` to reset + generic `DISABLE_PKGS` guard.
2. CLI: add `--disable=`, `--enable=`, `--list-pkgs` + validation.
3. CLI: add per-group flags (`--tls=`, `--aac=`, `--h264=`, `--h265=`, `--av1-enc=`).
4. Resolver: `lib/resolve.sh` with `tls_disable_companions` + mutex resolution loop.
5. New recipes: `mbedtls.sh`, `libressl.sh`.
6. Annotate existing recipes with mutex groups; remove `PKG_SKIP_IF_NONFREE`.
7. Persistence: `.mediaforge-choices` read/write + `--clean-choices`.
8. Menu: `lib/menu.sh` (POSIX primitives) + `--menu` flow using whiptail when
   present.
9. Smart prompts (§8) reusing menu primitives.
10. Tests: shellcheck harness + dry-run matrix.
11. Documentation: CLAUDE.md, docs/cli-flags.md, docs/menu.md, MEMORY.md.

Each step is independently `sh -n`-clean and passes the dry-run matrix before
the next begins.
