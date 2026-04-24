# Package Toggles + TLS Backend + Menu — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add first-class TLS backend selection, generic per-recipe enable/disable with typo-safe validation, mutually-exclusive recipe groups, optional whiptail-backed interactive menu, smart prompts for unresolved mutex groups, and choice persistence — all in POSIX sh.

**Architecture:** A new `lib/resolve.sh` runs after CLI parsing and translates per-group flags + stored choices + profile defaults into a single `DISABLE_PKGS` string consumed by the existing recipe-guard system. A new `lib/menu.sh` provides whiptail-or-POSIX primitives reused by both `--menu` and the smart-prompt path. Recipes gain a single new attribute, `PKG_MUTEX_GROUP`, replacing the ad-hoc `PKG_SKIP_IF_NONFREE` mechanism.

**Tech Stack:** POSIX sh (no Bashisms — see CLAUDE.md "Shell Conventions"), `awk`, `grep`, `sed`, optional `whiptail` from the `newt` package, `shellcheck` for linting.

**Spec:** `docs/superpowers/specs/2026-04-24-pkg-toggles-and-tls-backend-design.md`

**Branch:** `feature/pkg-toggles-and-tls-backend`

**Working dir guidance for the engineer:** All paths in this plan are relative to the repository root (`/home/matte/dev/bash/mediaforge`). Always start each session with `git status` to confirm you're on the feature branch and the working tree is what the previous task left.

---

## File Map

| Path | Status | Responsibility |
|---|---|---|
| `lib/resolve.sh` | new | Translate per-group flags + stored/profile defaults into `DISABLE_PKGS`; enforce mutex; optionally invoke smart prompts. |
| `lib/menu.sh` | new | `menu_radiolist` and `menu_checklist` primitives. Whiptail when present, POSIX `read` loop otherwise. |
| `lib/registry.sh` | new | Build the recipe-name registry from `recipes/_order.conf`; provide `is_known_pkg`, `suggest_pkg`, `mutex_group_of`. |
| `lib/utils.sh` | modify | Source `lib/registry.sh`; add `warn_once` helper. |
| `lib/framework.sh` | modify | Add `PKG_MUTEX_GROUP` to `reset_recipe`; add `DISABLE_PKGS` guard at top of `check_guards`; remove `PKG_SKIP_IF_NONFREE` and `NO_LV2` special cases. |
| `mediaforge.sh` | modify | Source `lib/registry.sh` + `lib/resolve.sh` + `lib/menu.sh`; add new flags (`--tls=`, `--aac=`, `--h264=`, `--h265=`, `--av1-enc=`, `--disable=`, `--enable=`, `--menu`, `--list-pkgs`, `--clean-choices`); call `resolve_choices` before the build loop. |
| `recipes/crypto/openssl.sh` | modify | Add `PKG_MUTEX_GROUP="tls"`; drop `PKG_NONFREE=true`. |
| `recipes/crypto/gnutls.sh` | modify | Add `PKG_MUTEX_GROUP="tls"`; drop `PKG_SKIP_IF_NONFREE=true`. |
| `recipes/crypto/gmp.sh` | modify | Drop `PKG_SKIP_IF_NONFREE=true`. |
| `recipes/crypto/nettle.sh` | modify | Drop `PKG_SKIP_IF_NONFREE=true`. |
| `recipes/crypto/mbedtls.sh` | new | mbedTLS recipe, static-only, `PKG_MUTEX_GROUP="tls"`, `PKG_FFMPEG_OPT="--enable-mbedtls"`. |
| `recipes/crypto/libressl.sh` | new | LibreSSL recipe, static-only, `PKG_MUTEX_GROUP="tls"`, `PKG_FFMPEG_OPT="--enable-libtls"`. |
| `recipes/audio/fdk_aac.sh` | modify | Add `PKG_MUTEX_GROUP="aac"`. |
| `recipes/video/x264.sh` | modify | Add `PKG_MUTEX_GROUP="h264"`. |
| `recipes/video/openh264.sh` | modify | Add `PKG_MUTEX_GROUP="h264"`. |
| `recipes/video/x265.sh` | modify | Add `PKG_MUTEX_GROUP="h265"`. |
| `recipes/video/kvazaar.sh` | modify | Add `PKG_MUTEX_GROUP="h265"`. |
| `recipes/video/svtav1.sh` | modify | Add `PKG_MUTEX_GROUP="av1-enc"`. |
| `recipes/video/rav1e.sh` | modify | Add `PKG_MUTEX_GROUP="av1-enc"`. |
| `recipes/video/av1.sh` | modify | Add `PKG_MUTEX_GROUP="av1-enc"` (libaom). |
| `recipes/_order.conf` | modify | Add `recipes/crypto/mbedtls.sh` and `recipes/crypto/libressl.sh` to the crypto block. |
| `profiles/ffmpeg-8.0.1.conf` | modify | Add commented-out `*_DEFAULT` lines as documentation. |
| `profiles/ffmpeg-7.1.conf` | modify | Same. |
| `profiles/ffmpeg-7.0.conf` | modify | Same. |
| `profiles/ffmpeg-6.1.conf` | modify | Same. |
| `tests/shellcheck.sh` | new | Run `sh -n` over every `.sh`; run `shellcheck -s sh` when available. |
| `tests/dry-run-matrix.sh` | new | Invoke `mediaforge.sh build --dry-run` across the TLS × licence × static matrix; assert expected `--enable-*` flags. |
| `tests/negative.sh` | new | Negative tests: unknown package, contradictions, force-enable-vs-nonfree. |
| `tests/menu-stdin.sh` | new | Scripted-stdin tests for the POSIX menu fallback. |
| `tests/run.sh` | new | Top-level runner that calls the three test scripts above. |
| `CLAUDE.md` | modify | Document `PKG_MUTEX_GROUP` and the new flags. |
| `docs/cli-flags.md` | new | Full recipe listing with category + mutex group + H.264 patent caveat. |
| `docs/menu.md` | new | ASCII walkthrough of the four-screen menu flow. |
| `.gitignore` | modify | Already done in spec commit; verify no further change needed. |

**Total:** 4 new lib files, 2 new recipes, 1 new top-level entry-point change, 11 recipe annotations, 4 profile updates, 5 test scripts, 2 doc files, 1 doc edit.

---

## Implementation Stages

The plan is organised in eight stages (A–H). Each stage produces a working, dry-run-clean state. Within a stage, tasks must be done in order; stages can be checkpointed.

### Stage A — Test harness + framework foundation
Tasks A1–A4. Establishes shellcheck + a tiny dry-run runner; adds `PKG_MUTEX_GROUP` + generic `DISABLE_PKGS` guard. After Stage A: `--disable-lv2` still works (now via the generic path), nothing else has changed user-visibly.

### Stage B — Recipe registry + generic --disable=/--enable=
Tasks B1–B3. New `lib/registry.sh`; CLI gains `--disable=`, `--enable=`, `--list-pkgs`. After Stage B: a user can disable any recipe by name with typo suggestions.

### Stage C — TLS backend selector (the rdlp blocker)
Tasks C1–C7. New `lib/resolve.sh` and `lib/menu.sh` minimum; new `mbedtls.sh` + `libressl.sh`; `--tls=` flag; recipe annotations for the `tls` group; remove `PKG_SKIP_IF_NONFREE`. After Stage C: `--tls=gnutls` produces a TLS-clean libavformat.a; rdlp Phase 2 unblocks.

### Stage D — Other mutex groups
Tasks D1–D2. Annotate aac/h264/h265/av1-enc recipes; add per-group flags; expand resolver tables.

### Stage E — Choice persistence
Tasks E1–E2. Read/write `.mediaforge-choices`; add `--clean-choices`.

### Stage F — Smart prompts
Tasks F1–F2. Wire `lib/menu.sh` primitives into the resolver's "unresolved mutex" branch.

### Stage G — Full --menu
Tasks G1–G3. Four-screen whiptail flow + POSIX fallback path.

### Stage H — Profile defaults + docs
Tasks H1–H4. Profile `*_DEFAULT` variables; CLAUDE.md; `docs/cli-flags.md`; `docs/menu.md`.

---

## Stage A — Test harness + framework foundation

### Task A1: Create the shellcheck test script

**Files:**
- Create: `tests/shellcheck.sh`
- Create: `tests/run.sh`

- [ ] **Step 1: Write `tests/shellcheck.sh`**

```sh
#!/bin/sh
# Lints every shell file under the repo with `sh -n` and (when available) `shellcheck -s sh`.
# Exit non-zero on first failure unless KEEP_GOING=1.

set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

_fail=0
_files=$(find mediaforge.sh lib recipes tests -type f -name '*.sh')

for f in $_files; do
  if ! sh -n "$f"; then
    printf 'sh -n FAILED: %s\n' "$f" >&2
    _fail=1
    [ "${KEEP_GOING:-0}" = "1" ] || exit 1
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  for f in $_files; do
    if ! shellcheck -s sh -e SC1090,SC1091,SC2034 "$f"; then
      printf 'shellcheck FAILED: %s\n' "$f" >&2
      _fail=1
      [ "${KEEP_GOING:-0}" = "1" ] || exit 1
    fi
  done
else
  printf 'shellcheck not installed — skipping\n' >&2
fi

exit "$_fail"
```

- [ ] **Step 2: Write `tests/run.sh`**

```sh
#!/bin/sh
# Top-level test runner. Sequential — each script exits non-zero on failure.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

sh tests/shellcheck.sh
# Stage B+ will add more invocations here.

printf 'All tests passed.\n'
```

- [ ] **Step 3: Make them executable and run**

```sh
chmod +x tests/shellcheck.sh tests/run.sh
sh tests/run.sh
```

Expected: exits 0; if `shellcheck` is installed and any pre-existing file fails, **stop and address those failures before proceeding** — they will mask issues introduced by later tasks. The `-e SC1090,SC1091,SC2034` excludes are the existing `# shellcheck disable=` comments in the codebase made directive-level.

- [ ] **Step 4: Commit**

```sh
git add tests/shellcheck.sh tests/run.sh
git commit -m "test: add shellcheck + sh -n harness"
```

---

### Task A2: Add PKG_MUTEX_GROUP to the recipe reset block

**Files:**
- Modify: `lib/framework.sh`

- [ ] **Step 1: Read the current `reset_recipe` function**

Open `lib/framework.sh`. Locate the `reset_recipe()` function (currently lines 33–61).

- [ ] **Step 2: Add `PKG_MUTEX_GROUP=""` to the reset block**

Edit `lib/framework.sh`. Find the line:
```sh
  PKG_DISABLED=false
```
Add directly after it:
```sh
  PKG_MUTEX_GROUP=""
```

- [ ] **Step 3: Run the test harness to confirm no regression**

```sh
sh tests/run.sh
```

Expected: PASS. Adding a new initialisation line cannot break existing behaviour.

- [ ] **Step 4: Commit**

```sh
git add lib/framework.sh
git commit -m "framework: add PKG_MUTEX_GROUP to recipe reset block"
```

---

### Task A3: Add DISABLE_PKGS guard at the top of check_guards

**Files:**
- Modify: `lib/framework.sh`
- Modify: `mediaforge.sh`

- [ ] **Step 1: Add the global default in `mediaforge.sh`**

Open `mediaforge.sh`. Locate the "Feature flags (defaults)" block (currently around line 30–48). Add directly under `KEEP_GOING=false`:

```sh
DISABLE_PKGS=""
ENABLE_PKGS=""
```

- [ ] **Step 2: Add the guard block in `lib/framework.sh:check_guards`**

Open `lib/framework.sh`. Locate `check_guards()`. Insert this block as the **first** check, immediately under the `# Disabled guard` block:

```sh
  # Generic CLI disable list (drives --disable= and --tls=/--aac=/etc.)
  for _d in $DISABLE_PKGS; do
    if [ "$_d" = "$PKG_NAME" ]; then
      log "Skipping $PKG_NAME (disabled via CLI)"
      return 1
    fi
  done
```

- [ ] **Step 3: Verify lint passes**

```sh
sh tests/run.sh
```

Expected: PASS.

- [ ] **Step 4: Smoke-test with a known recipe name**

```sh
DISABLE_PKGS=lv2 ./mediaforge.sh build --dry-run 2>&1 | grep -i "skipping lv2"
```

Expected: at least one line matching `Skipping lv2 (disabled via CLI)`. (The dry-run will still proceed past lv2 and may fail later — that's fine for this smoke test; we only care that the guard fired.)

If `--dry-run` is not yet implemented in `mediaforge.sh`, this smoke test is deferred to Task A4.

- [ ] **Step 5: Commit**

```sh
git add lib/framework.sh mediaforge.sh
git commit -m "framework: generic DISABLE_PKGS guard at top of check_guards"
```

---

### Task A4: Migrate --disable-lv2 onto the generic path; remove NO_LV2 special-case

**Files:**
- Modify: `lib/framework.sh`
- Modify: `mediaforge.sh`

- [ ] **Step 1: Locate the `NO_LV2` special-case in `lib/framework.sh`**

Find the block (currently at framework.sh:120–127):
```sh
  if [ "$NO_LV2" = true ] && [ "$PKG_NAME" = "lv2" ]; then
    log "Skipping $PKG_NAME (--disable-lv2)"
    return 1
  fi
```

Delete this entire block. The generic `DISABLE_PKGS` guard from Task A3 now handles it.

- [ ] **Step 2: Update `mediaforge.sh` to translate `--disable-lv2` → `DISABLE_PKGS`**

In `mediaforge.sh`, find the two arms that set `NO_LV2=true`:
```sh
      -L)  NO_LV2=true ;;
```
and:
```sh
      --disable-lv2)       NO_LV2=true ;;
```

Replace both with:
```sh
      -L)  DISABLE_PKGS="$DISABLE_PKGS lv2" ;;
```
and:
```sh
      --disable-lv2)       DISABLE_PKGS="$DISABLE_PKGS lv2" ;;
```

Also remove the `NO_LV2=false` line from the feature-flags defaults block (kept for now if other code references it — but a `grep -n NO_LV2 .` should now show zero hits in `lib/` or `mediaforge.sh`).

- [ ] **Step 3: Verify nothing references NO_LV2 anymore**

```sh
grep -rn NO_LV2 mediaforge.sh lib/ recipes/
```

Expected: no output. If anything remains, replace with the equivalent `DISABLE_PKGS` check.

- [ ] **Step 4: Run tests**

```sh
sh tests/run.sh
```

Expected: PASS.

- [ ] **Step 5: Commit**

```sh
git add lib/framework.sh mediaforge.sh
git commit -m "cli: --disable-lv2 now flows through generic DISABLE_PKGS guard"
```

---

## Stage B — Recipe registry + generic --disable=/--enable=

### Task B1: Create lib/registry.sh

**Files:**
- Create: `lib/registry.sh`
- Modify: `mediaforge.sh`

- [ ] **Step 1: Write `lib/registry.sh`**

```sh
# Recipe registry — derive package metadata from recipes/_order.conf and the
# recipe files themselves. Side-effect free: never sources a recipe.

# Cached recipe-name list (space-separated). Populated lazily.
_REGISTRY_NAMES=""

# Build the registry from _order.conf (path → name).
registry_init() {
  [ -n "$_REGISTRY_NAMES" ] && return 0
  _REGISTRY_NAMES=$(awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    {
      # Strip inline comments and trailing whitespace
      sub(/[[:space:]]*#.*$/, "")
      sub(/^[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      if ($0 == "") next
      # Extract basename without .sh
      n = split($0, parts, "/")
      name = parts[n]
      sub(/\.sh$/, "", name)
      print name
    }
  ' "$SCRIPT_DIR/recipes/_order.conf")
}

# Return 0 if $1 is a known recipe name.
is_known_pkg() {
  registry_init
  for _r in $_REGISTRY_NAMES; do
    [ "$_r" = "$1" ] && return 0
  done
  return 1
}

# Print substring-matching recipe names, comma-separated, max 3.
suggest_pkg() {
  registry_init
  printf '%s\n' $_REGISTRY_NAMES | grep -i "$1" 2>/dev/null | head -3 | paste -sd, -
}

# Print mutex group of $1 (or empty). Reads PKG_MUTEX_GROUP from the recipe
# file via grep — does NOT source the recipe.
mutex_group_of() {
  registry_init
  for _path in "$SCRIPT_DIR"/recipes/*/"$1.sh"; do
    [ -f "$_path" ] || continue
    awk -F'"' '/^PKG_MUTEX_GROUP=/ { print $2; exit }' "$_path"
    return 0
  done
  return 0
}

# Print "name<TAB>category<TAB>mutex_group<TAB>flags" for every recipe.
list_pkgs() {
  registry_init
  for _name in $_REGISTRY_NAMES; do
    for _path in "$SCRIPT_DIR"/recipes/*/"$_name.sh"; do
      [ -f "$_path" ] || continue
      _cat=$(basename "$(dirname "$_path")")
      _grp=$(awk -F'"' '/^PKG_MUTEX_GROUP=/ { print $2; exit }' "$_path")
      _flg=""
      grep -q '^PKG_GPL=true' "$_path" 2>/dev/null && _flg="${_flg}gpl,"
      grep -q '^PKG_NONFREE=true' "$_path" 2>/dev/null && _flg="${_flg}nonfree,"
      _flg=${_flg%,}
      printf '%s\t%s\t%s\t%s\n' "$_name" "$_cat" "${_grp:--}" "${_flg:--}"
    done
  done
}
```

- [ ] **Step 2: Source it from `mediaforge.sh`**

In `mediaforge.sh`, in the "Source libraries" block (around line 17–22), add **after** `lib/utils.sh` and **before** `lib/platform.sh`:

```sh
. "$SCRIPT_DIR/lib/registry.sh"
```

- [ ] **Step 3: Run tests**

```sh
sh tests/run.sh
```

Expected: PASS.

- [ ] **Step 4: Smoke test — list every recipe**

```sh
sh -c '. ./lib/utils.sh; SCRIPT_DIR=$PWD; . ./lib/registry.sh; list_pkgs' | head -5
```

Expected: at least 5 tab-separated lines, e.g.:
```
giflib  tools  -  -
pkg-config  tools  -  -
yasm  tools  -  -
nasm  tools  -  -
zlib  tools  -  -
```

- [ ] **Step 5: Commit**

```sh
git add lib/registry.sh mediaforge.sh
git commit -m "registry: derive recipe metadata from _order.conf without sourcing"
```

---

### Task B2: Add --disable=, --enable=, and --list-pkgs CLI flags

**Files:**
- Modify: `mediaforge.sh`
- Create: `tests/negative.sh`

- [ ] **Step 1: Add the parser arms**

In `mediaforge.sh`, in the long-options `case` block of `cmd_build` (currently around line 105–125), add these arms before the `--)` line:

```sh
      --disable=*)         DISABLE_PKGS="$DISABLE_PKGS $(echo "${1#--disable=}" | tr ',' ' ')" ;;
      --disable)           shift; DISABLE_PKGS="$DISABLE_PKGS $(echo "$1" | tr ',' ' ')" ;;
      --enable=*)          ENABLE_PKGS="$ENABLE_PKGS $(echo "${1#--enable=}" | tr ',' ' ')" ;;
      --enable)            shift; ENABLE_PKGS="$ENABLE_PKGS $(echo "$1" | tr ',' ' ')" ;;
      --list-pkgs)         list_pkgs; exit 0 ;;
```

- [ ] **Step 2: Add the validation block**

In `mediaforge.sh`, find the line (in `cmd_build`, after the parser `done`):
```sh
  # Apply deferred flags
```

Insert this **before** that line:

```sh
  # Validate every name in DISABLE_PKGS / ENABLE_PKGS against the recipe registry
  registry_init
  for _p in $DISABLE_PKGS $ENABLE_PKGS; do
    if ! is_known_pkg "$_p"; then
      _hint=$(suggest_pkg "$_p")
      if [ -n "$_hint" ]; then
        die "Unknown package: $_p. Did you mean: $_hint ?"
      else
        die "Unknown package: $_p. Run '$PROGNAME build --list-pkgs' to see all."
      fi
    fi
  done
```

- [ ] **Step 3: Update `cmd_help` to document the new flags**

In `mediaforge.sh:cmd_help`, in the "Build options" block, add these lines (alphabetical order with the existing options):

```sh
  printf '      --disable=PKG         Disable a recipe by name (repeatable, comma-separated ok)\n'
  printf '      --enable=PKG          Force-enable a recipe that defaults to off\n'
  printf '      --list-pkgs           Print every recipe with category and mutex group\n'
```

Also update the `Commands:` block to mention `--list-pkgs` is a build-mode flag.

- [ ] **Step 4: Write the negative-test harness**

Create `tests/negative.sh`:

```sh
#!/bin/sh
# Negative tests: invalid input must fail with an actionable message.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

_fail=0
_run() {
  _desc=$1; shift
  _expect=$1; shift
  _output=$("$@" 2>&1) && _rc=0 || _rc=$?
  if [ "$_rc" = "0" ]; then
    printf 'FAIL [%s]: expected non-zero exit, got 0\n' "$_desc" >&2
    _fail=1
    return
  fi
  if ! printf '%s' "$_output" | grep -q "$_expect"; then
    printf 'FAIL [%s]: stderr did not contain "%s"\n' "$_desc" "$_expect" >&2
    printf '  got: %s\n' "$_output" >&2
    _fail=1
    return
  fi
  printf 'PASS [%s]\n' "$_desc"
}

_run "unknown pkg with suggestion" "Did you mean: openssl" \
  ./mediaforge.sh build --disable=opssl --dry-run --yes

_run "unknown pkg, no suggestion" "Run 'mediaforge.sh build --list-pkgs'" \
  ./mediaforge.sh build --disable=zzznonexistent --dry-run --yes

exit "$_fail"
```

Make it executable and add it to `tests/run.sh`:

```sh
chmod +x tests/negative.sh
```

In `tests/run.sh`, add before the final `printf` line:

```sh
sh tests/negative.sh
```

- [ ] **Step 5: Run the failing test**

```sh
sh tests/negative.sh
```

Expected: PASS for both cases. (If FAIL, debug the suggestion logic — check that `suggest_pkg` is returning the right thing.)

- [ ] **Step 6: Commit**

```sh
git add mediaforge.sh tests/negative.sh tests/run.sh
git commit -m "cli: --disable=/--enable=/--list-pkgs with typo-safe validation"
```

---

### Task B3: Wire --enable= into the recipe override path

**Files:**
- Modify: `lib/framework.sh`

- [ ] **Step 1: Add the ENABLE_PKGS override in `check_guards`**

In `lib/framework.sh:check_guards`, locate the `# Disabled guard` block:
```sh
  # Disabled guard (e.g., SKIPRAV1E=yes)
  if [ "$PKG_DISABLED" = true ]; then
    log "Skipping $PKG_NAME (disabled)"
    return 1
  fi
```

Replace with:
```sh
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
```

Note: `--enable=` does NOT override `PKG_GPL`, `PKG_NONFREE`, or platform guards. Those remain hard gates per the spec (§5.1 "Override scope").

- [ ] **Step 2: Add the negative test for force-enable-vs-nonfree**

Append to `tests/negative.sh` (before the final `exit`):

```sh
_run "force-enable does not bypass nonfree guard" "Skipping fdk_aac (requires --nonfree)" \
  ./mediaforge.sh build --enable=fdk_aac --dry-run --yes
```

- [ ] **Step 3: Run tests**

```sh
sh tests/run.sh
```

Expected: PASS.

- [ ] **Step 4: Commit**

```sh
git add lib/framework.sh tests/negative.sh
git commit -m "framework: --enable=PKG overrides PKG_DISABLED only, not licence guards"
```

---

## Stage C — TLS backend selector

### Task C1: Create lib/resolve.sh skeleton with tls_disable_companions

**Files:**
- Create: `lib/resolve.sh`
- Modify: `mediaforge.sh`

- [ ] **Step 1: Write `lib/resolve.sh`**

```sh
# Resolver — translate per-group flags + stored choices + profile defaults
# into a final DISABLE_PKGS string. Idempotent.

# Per-group user choices (set from CLI; empty means "not chosen").
TLS_BACKEND=""
AAC_IMPL=""
H264_IMPL=""
H265_IMPL=""
AV1_ENC_IMPL=""

# Conservative defaults (used when non-interactive and nothing else resolves).
TLS_BACKEND_DEFAULT_BUILTIN="gnutls"
AAC_IMPL_DEFAULT_BUILTIN="native"
H264_IMPL_DEFAULT_BUILTIN="x264"
H265_IMPL_DEFAULT_BUILTIN="x265"
AV1_ENC_IMPL_DEFAULT_BUILTIN="svtav1"

# Members of each mutex group (excluding sentinels like "none" and "native").
TLS_GROUP="openssl gnutls mbedtls libressl"
AAC_GROUP="fdk_aac"
H264_GROUP="x264 openh264"
H265_GROUP="x265 kvazaar"
AV1_ENC_GROUP="svtav1 rav1e av1"   # av1 = libaom recipe filename

# Given a chosen TLS backend, return the space-separated list of TLS-related
# packages that must be disabled. gmp/nettle are gnutls build-deps.
tls_disable_companions() {
  case "$1" in
    gnutls)   echo "openssl mbedtls libressl" ;;
    openssl)  echo "gnutls gmp nettle mbedtls libressl" ;;
    mbedtls)  echo "openssl gnutls gmp nettle libressl" ;;
    libressl) echo "openssl gnutls gmp nettle mbedtls" ;;
    none)     echo "openssl gnutls gmp nettle mbedtls libressl" ;;
    *)        echo "" ;;
  esac
}

# Validate a value against a "|"-separated enum. Aborts on mismatch.
_validate_enum() {
  _name=$1; _value=$2; _allowed=$3
  case "|$_allowed|" in
    *"|$_value|"*) return 0 ;;
  esac
  die "Invalid $_name: $_value. Allowed: $(printf '%s' "$_allowed" | tr '|' ',')"
}

# Top-level resolver. Mutates DISABLE_PKGS in place. Idempotent.
resolve_choices() {
  # Apply built-in defaults if nothing set them.
  : "${TLS_BACKEND:=$TLS_BACKEND_DEFAULT_BUILTIN}"
  : "${AAC_IMPL:=$AAC_IMPL_DEFAULT_BUILTIN}"
  : "${H264_IMPL:=$H264_IMPL_DEFAULT_BUILTIN}"
  : "${H265_IMPL:=$H265_IMPL_DEFAULT_BUILTIN}"
  : "${AV1_ENC_IMPL:=$AV1_ENC_IMPL_DEFAULT_BUILTIN}"

  _validate_enum "--tls"     "$TLS_BACKEND"  "openssl|gnutls|mbedtls|libressl|none"
  _validate_enum "--aac"     "$AAC_IMPL"     "fdk_aac|native"
  _validate_enum "--h264"    "$H264_IMPL"    "x264|openh264"
  _validate_enum "--h265"    "$H265_IMPL"    "x265|kvazaar"
  _validate_enum "--av1-enc" "$AV1_ENC_IMPL" "svtav1|rav1e|av1"

  # TLS: disable companions of the chosen backend
  for _p in $(tls_disable_companions "$TLS_BACKEND"); do
    DISABLE_PKGS="$DISABLE_PKGS $_p"
  done

  # AAC: only fdk_aac is a mutex member; native means "skip fdk_aac"
  case "$AAC_IMPL" in
    native) DISABLE_PKGS="$DISABLE_PKGS fdk_aac" ;;
  esac

  # H264 / H265 / AV1-enc: disable every member of the group except the chosen one
  for _g_var in H264_GROUP H265_GROUP AV1_ENC_GROUP; do
    eval "_members=\$$_g_var"
    eval "_chosen=\$${_g_var%_GROUP}_IMPL"
    for _m in $_members; do
      [ "$_m" = "$_chosen" ] && continue
      DISABLE_PKGS="$DISABLE_PKGS $_m"
    done
  done

  # Detect contradictions: --tls=X --disable=X
  for _chosen in "$TLS_BACKEND" "$AAC_IMPL" "$H264_IMPL" "$H265_IMPL" "$AV1_ENC_IMPL"; do
    [ "$_chosen" = "none" ] || [ "$_chosen" = "native" ] && continue
    for _d in $DISABLE_PKGS_INPUT; do
      [ "$_d" = "$_chosen" ] && \
        die "Contradiction: '$_chosen' is both selected via per-group flag and listed in --disable="
    done
  done
}
```

Note: this skeleton uses a snapshot variable `DISABLE_PKGS_INPUT` for the contradiction check — set it from the CLI parser before calling `resolve_choices`. See Task C2 step 2.

- [ ] **Step 2: Source it from `mediaforge.sh`**

In `mediaforge.sh`, in the "Source libraries" block, add **after** `lib/registry.sh`:

```sh
. "$SCRIPT_DIR/lib/resolve.sh"
```

- [ ] **Step 3: Run tests**

```sh
sh tests/run.sh
```

Expected: PASS. The resolver isn't called yet — this only verifies the file lints clean.

- [ ] **Step 4: Commit**

```sh
git add lib/resolve.sh mediaforge.sh
git commit -m "resolve: skeleton with tls_disable_companions and enum validation"
```

---

### Task C2: Wire --tls= into the CLI parser and call resolve_choices

**Files:**
- Modify: `mediaforge.sh`

- [ ] **Step 1: Add the parser arms for --tls= and the four other group flags**

In `mediaforge.sh`, in the long-options block of `cmd_build`, add before `--)`:

```sh
      --tls=*)             TLS_BACKEND="${1#--tls=}" ;;
      --tls)               shift; TLS_BACKEND="$1" ;;
      --aac=*)             AAC_IMPL="${1#--aac=}" ;;
      --aac)               shift; AAC_IMPL="$1" ;;
      --h264=*)            H264_IMPL="${1#--h264=}" ;;
      --h264)              shift; H264_IMPL="$1" ;;
      --h265=*)            H265_IMPL="${1#--h265=}" ;;
      --h265)              shift; H265_IMPL="$1" ;;
      --av1-enc=*)         AV1_ENC_IMPL="${1#--av1-enc=}" ;;
      --av1-enc)           shift; AV1_ENC_IMPL="$1" ;;
```

- [ ] **Step 2: Snapshot DISABLE_PKGS for contradiction detection, then call resolve_choices**

In `mediaforge.sh`, locate the line just after the validation block from Task B2 step 2 (the loop over `$DISABLE_PKGS $ENABLE_PKGS`). Insert directly after it:

```sh
  # Snapshot the user-provided disables before resolver augments them
  DISABLE_PKGS_INPUT="$DISABLE_PKGS"

  # Resolve per-group choices into DISABLE_PKGS
  resolve_choices

  # Log final choice matrix
  log "Choices: tls=$TLS_BACKEND aac=$AAC_IMPL h264=$H264_IMPL h265=$H265_IMPL av1-enc=$AV1_ENC_IMPL"
```

- [ ] **Step 3: Update `cmd_help`**

Add to the build-options block in `cmd_help`:

```sh
  printf '      --tls=BACKEND         TLS backend: openssl|gnutls|mbedtls|libressl|none (default: gnutls)\n'
  printf '      --aac=IMPL            AAC encoder: fdk_aac|native (default: native)\n'
  printf '      --h264=IMPL           H.264 encoder: x264|openh264 (default: x264)\n'
  printf '      --h265=IMPL           H.265 encoder: x265|kvazaar (default: x265)\n'
  printf '      --av1-enc=IMPL        AV1 encoder: svtav1|rav1e|av1 (default: svtav1)\n'
```

- [ ] **Step 4: Run tests**

```sh
sh tests/run.sh
```

Expected: PASS — the negative tests should now also exercise resolver validation.

- [ ] **Step 5: Smoke-test the resolver output**

```sh
./mediaforge.sh build --tls=gnutls --dry-run --yes 2>&1 | grep "Choices:"
```

Expected: a line `Choices: tls=gnutls aac=native h264=x264 h265=x265 av1-enc=svtav1`.

- [ ] **Step 6: Commit**

```sh
git add mediaforge.sh
git commit -m "cli: --tls=/--aac=/--h264=/--h265=/--av1-enc= flags + resolver wiring"
```

---

### Task C3: Add the dry-run matrix test

**Files:**
- Create: `tests/dry-run-matrix.sh`
- Modify: `tests/run.sh`

- [ ] **Step 1: Write `tests/dry-run-matrix.sh`**

```sh
#!/bin/sh
# Dry-run matrix: assert FFMPEG_CONFIGURE_OPTS contains the expected --enable-*
# for every supported TLS × licence combination.
#
# Relies on `--dry-run` printing the final FFMPEG_CONFIGURE_OPTS at INFO level.
# The grep patterns below assume the existing `log` function prefixes lines with
# the package name or "Choices:".

set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

_fail=0
_run() {
  _desc=$1; shift
  _expect=$1; shift
  _output=$("$@" --dry-run --yes 2>&1) || true
  if ! printf '%s' "$_output" | grep -q "$_expect"; then
    printf 'FAIL [%s]: missing "%s"\n' "$_desc" "$_expect" >&2
    _fail=1
    return
  fi
  printf 'PASS [%s]\n' "$_desc"
}

_run_no() {
  _desc=$1; shift
  _forbidden=$1; shift
  _output=$("$@" --dry-run --yes 2>&1) || true
  if printf '%s' "$_output" | grep -q "$_forbidden"; then
    printf 'FAIL [%s]: contained forbidden "%s"\n' "$_desc" "$_forbidden" >&2
    _fail=1
    return
  fi
  printf 'PASS [%s]\n' "$_desc"
}

# Default: gnutls
_run    "default tls=gnutls"      "tls=gnutls"     ./mediaforge.sh build
_run_no "default has no openssl"  "Skipping openssl (disabled" ./mediaforge.sh build  # default disables openssl

# Explicit backends
_run "tls=openssl logged"   "tls=openssl"  ./mediaforge.sh build --tls=openssl
_run "tls=mbedtls logged"   "tls=mbedtls"  ./mediaforge.sh build --tls=mbedtls
_run "tls=libressl logged"  "tls=libressl" ./mediaforge.sh build --tls=libressl
_run "tls=none logged"      "tls=none"     ./mediaforge.sh build --tls=none

# Mutex companions
_run "openssl disables gnutls" "Skipping gnutls (disabled via CLI)" \
  ./mediaforge.sh build --tls=openssl
_run "gnutls disables openssl" "Skipping openssl (disabled via CLI)" \
  ./mediaforge.sh build --tls=gnutls

# AAC default skips fdk_aac
_run "aac=native skips fdk_aac" "Skipping fdk_aac (disabled via CLI)" \
  ./mediaforge.sh build

# H264 default keeps x264, skips openh264
_run "h264 default disables openh264" "Skipping openh264 (disabled via CLI)" \
  ./mediaforge.sh build

exit "$_fail"
```

Make it executable and add to `tests/run.sh`:

```sh
chmod +x tests/dry-run-matrix.sh
```

In `tests/run.sh`, add before the final `printf`:

```sh
sh tests/dry-run-matrix.sh
```

- [ ] **Step 2: Run the matrix**

```sh
sh tests/dry-run-matrix.sh
```

Expected: most cases PASS. The mbedtls and libressl cases will FAIL until Tasks C4–C5 add those recipes — that's acceptable; mark these tests TODO and continue.

If you want strict TDD discipline, comment out the mbedtls/libressl lines now and uncomment them after C4/C5.

- [ ] **Step 3: Commit (with the failing mbedtls/libressl lines commented if needed)**

```sh
git add tests/dry-run-matrix.sh tests/run.sh
git commit -m "test: dry-run matrix for TLS and AAC/H264 mutex resolution"
```

---

### Task C4: Create recipes/crypto/mbedtls.sh

**Files:**
- Create: `recipes/crypto/mbedtls.sh`
- Modify: `recipes/_order.conf`

- [ ] **Step 1: Write the mbedtls recipe**

```sh
PKG_NAME="mbedtls"
PKG_VERSION="${PKG_VERSION_MBEDTLS:-3.6.4}"
PKG_GITHUB_REPO="Mbed-TLS/mbedtls"
PKG_URL="https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-${PKG_VERSION}/mbedtls-${PKG_VERSION}.tar.bz2"
PKG_FILENAME="mbedtls-${PKG_VERSION}.tar.bz2"
PKG_FFMPEG_OPT="--enable-mbedtls"
PKG_MUTEX_GROUP="tls"
PKG_CMAKE=true
PKG_CMAKE_FLAGS="\
  -DUSE_SHARED_MBEDTLS_LIBRARY=Off \
  -DUSE_STATIC_MBEDTLS_LIBRARY=On \
  -DENABLE_PROGRAMS=Off \
  -DENABLE_TESTING=Off \
  -DMBEDTLS_FATAL_WARNINGS=Off"

pkg_post_install() {
  # mbedtls does not ship .pc files by default; FFmpeg's mbedtls probe uses
  # plain -lmbedtls -lmbedx509 -lmbedcrypto, so headers + libs in $PREFIX are
  # sufficient. Nothing to do.
  :
}
```

- [ ] **Step 2: Add to `recipes/_order.conf`**

Find the crypto block in `recipes/_order.conf`:
```
recipes/other/gettext.sh
recipes/crypto/openssl.sh
recipes/crypto/gmp.sh
recipes/crypto/nettle.sh
recipes/crypto/gnutls.sh
```

Replace with:
```
recipes/other/gettext.sh
recipes/crypto/openssl.sh
recipes/crypto/mbedtls.sh
recipes/crypto/libressl.sh
recipes/crypto/gmp.sh
recipes/crypto/nettle.sh
recipes/crypto/gnutls.sh
```

(libressl will be created in Task C5 — adding both order entries here in one go to keep the ordering decision in one commit.)

- [ ] **Step 3: Run tests**

```sh
sh tests/shellcheck.sh
```

Expected: PASS for the new recipe.

The dry-run matrix will fail on libressl (file not yet created) — that's expected; resolved in C5.

- [ ] **Step 4: Commit**

```sh
git add recipes/crypto/mbedtls.sh recipes/_order.conf
git commit -m "recipes: add mbedtls crypto recipe (static-only, --enable-mbedtls)"
```

---

### Task C5: Create recipes/crypto/libressl.sh

**Files:**
- Create: `recipes/crypto/libressl.sh`

- [ ] **Step 1: Write the libressl recipe**

```sh
PKG_NAME="libressl"
PKG_VERSION="${PKG_VERSION_LIBRESSL:-4.0.0}"
PKG_URL="https://cdn.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${PKG_VERSION}.tar.gz"
PKG_FILENAME="libressl-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-libtls"
PKG_MUTEX_GROUP="tls"

pkg_configure() {
  run ./configure --prefix="$PREFIX" \
    --disable-shared --enable-static \
    --disable-asm \
    --disable-tests
}

pkg_post_install() {
  # LibreSSL ships libtls.pc; FFmpeg's libtls probe uses pkg-config.
  # Verify the .pc file exists.
  if [ ! -f "$PREFIX/lib/pkgconfig/libtls.pc" ]; then
    warn "libressl: libtls.pc not found at $PREFIX/lib/pkgconfig/libtls.pc"
  fi
}
```

- [ ] **Step 2: Lint**

```sh
sh tests/shellcheck.sh
```

Expected: PASS.

- [ ] **Step 3: Re-run the dry-run matrix**

```sh
sh tests/dry-run-matrix.sh
```

Expected: all TLS-related cases now PASS (mbedtls and libressl recipes both exist; the resolver disables them as needed).

- [ ] **Step 4: Commit**

```sh
git add recipes/crypto/libressl.sh
git commit -m "recipes: add libressl crypto recipe (static-only, --enable-libtls)"
```

---

### Task C6: Annotate existing crypto recipes with mutex groups

**Files:**
- Modify: `recipes/crypto/openssl.sh`
- Modify: `recipes/crypto/gnutls.sh`
- Modify: `recipes/crypto/gmp.sh`
- Modify: `recipes/crypto/nettle.sh`

- [ ] **Step 1: Update openssl.sh**

In `recipes/crypto/openssl.sh`, replace the line:
```sh
PKG_NONFREE=true
```
with:
```sh
PKG_MUTEX_GROUP="tls"
```

OpenSSL's Apache-2.0 license is compatible with FFmpeg's LGPL core; the `PKG_NONFREE` tag was a mediaforge-internal convention, not a license requirement (see spec §14).

- [ ] **Step 2: Update gnutls.sh**

In `recipes/crypto/gnutls.sh`, replace:
```sh
PKG_SKIP_IF_NONFREE=true
```
with:
```sh
PKG_MUTEX_GROUP="tls"
```

- [ ] **Step 3: Update gmp.sh and nettle.sh**

In `recipes/crypto/gmp.sh`, delete the line `PKG_SKIP_IF_NONFREE=true`. (Do NOT add a mutex group — gmp/nettle are gnutls build-deps, not TLS backends. The resolver's `tls_disable_companions` lists them explicitly.)

Same for `recipes/crypto/nettle.sh`.

- [ ] **Step 4: Run tests**

```sh
sh tests/run.sh
```

Expected: PASS. The dry-run matrix should now show that `--tls=openssl --enable-nonfree` no longer auto-implies anything, and `--tls=gnutls` (the new default) skips openssl.

- [ ] **Step 5: Commit**

```sh
git add recipes/crypto/openssl.sh recipes/crypto/gnutls.sh recipes/crypto/gmp.sh recipes/crypto/nettle.sh
git commit -m "recipes/crypto: replace PKG_SKIP_IF_NONFREE with PKG_MUTEX_GROUP=tls"
```

---

### Task C7: Remove PKG_SKIP_IF_NONFREE from framework

**Files:**
- Modify: `lib/framework.sh`

- [ ] **Step 1: Verify no recipe still uses PKG_SKIP_IF_NONFREE**

```sh
grep -rn PKG_SKIP_IF_NONFREE recipes/
```

Expected: no output. If any recipe still references it, fix that recipe before continuing.

- [ ] **Step 2: Remove the reset and guard**

In `lib/framework.sh:reset_recipe`, delete the line:
```sh
  PKG_SKIP_IF_NONFREE=false
```

In `lib/framework.sh:check_guards`, delete the entire block:
```sh
  # Skip-if-nonfree guard (gmp/nettle/gnutls vs openssl mutual exclusion)
  if [ "$PKG_SKIP_IF_NONFREE" = true ] && [ "$ENABLE_NONFREE" = true ]; then
    log "Skipping $PKG_NAME (nonfree path uses alternative)"
    return 1
  fi
```

- [ ] **Step 3: Run tests**

```sh
sh tests/run.sh
```

Expected: PASS. (If any in-tree recipe still relied on this, the dry-run matrix will surface it.)

- [ ] **Step 4: Commit**

```sh
git add lib/framework.sh
git commit -m "framework: remove PKG_SKIP_IF_NONFREE — superseded by mutex groups"
```

**Stage C done.** At this point: `./mediaforge.sh build --tls=gnutls` produces a TLS-clean configuration that excludes openssl from libavformat.a. The rdlp Phase 2 blocker is resolved as soon as the user runs a real (non-dry-run) build.

---

## Stage D — Other mutex groups

### Task D1: Annotate AAC, H.264, H.265, AV1-encoder recipes

**Files:**
- Modify: `recipes/audio/fdk_aac.sh`
- Modify: `recipes/video/x264.sh`
- Modify: `recipes/video/openh264.sh`
- Modify: `recipes/video/x265.sh`
- Modify: `recipes/video/kvazaar.sh`
- Modify: `recipes/video/svtav1.sh`
- Modify: `recipes/video/rav1e.sh`
- Modify: `recipes/video/av1.sh`

- [ ] **Step 1: Add `PKG_MUTEX_GROUP="aac"` to fdk_aac.sh**

Insert a new line after `PKG_URL=...` (or after `PKG_NONFREE=true`):
```sh
PKG_MUTEX_GROUP="aac"
```

- [ ] **Step 2: Add `PKG_MUTEX_GROUP="h264"` to x264.sh and openh264.sh**

In each, insert near the top:
```sh
PKG_MUTEX_GROUP="h264"
```

- [ ] **Step 3: Add `PKG_MUTEX_GROUP="h265"` to x265.sh and kvazaar.sh**

Same pattern.

- [ ] **Step 4: Add `PKG_MUTEX_GROUP="av1-enc"` to svtav1.sh, rav1e.sh, and av1.sh**

Same pattern.

- [ ] **Step 5: Run tests**

```sh
sh tests/run.sh
```

Expected: PASS — the dry-run matrix already covers some of these cases.

- [ ] **Step 6: Commit**

```sh
git add recipes/audio/fdk_aac.sh recipes/video/x264.sh recipes/video/openh264.sh recipes/video/x265.sh recipes/video/kvazaar.sh recipes/video/svtav1.sh recipes/video/rav1e.sh recipes/video/av1.sh
git commit -m "recipes: annotate aac/h264/h265/av1-enc mutex groups"
```

---

### Task D2: Extend the dry-run matrix to cover the new groups

**Files:**
- Modify: `tests/dry-run-matrix.sh`

- [ ] **Step 1: Add cases**

Append to `tests/dry-run-matrix.sh` (before the final `exit`):

```sh
# AAC
_run "aac=fdk_aac requires nonfree, defaults skip" "Skipping fdk_aac" \
  ./mediaforge.sh build --aac=fdk_aac
# Note: --aac=fdk_aac without --enable-nonfree is permitted at the resolver
# layer (mutex says "use fdk_aac"), but PKG_NONFREE guard skips it. This is
# the correct layered behaviour per spec §5.1.

# H264
_run    "h264=openh264 disables x264" "Skipping x264 (disabled via CLI)" \
  ./mediaforge.sh build --h264=openh264
_run_no "h264=openh264 keeps openh264" "Skipping openh264 (disabled via CLI)" \
  ./mediaforge.sh build --h264=openh264

# H265
_run    "h265=kvazaar disables x265" "Skipping x265 (disabled via CLI)" \
  ./mediaforge.sh build --h265=kvazaar

# AV1-enc
_run    "av1-enc=rav1e disables svtav1 and av1" "Skipping svtav1 (disabled via CLI)" \
  ./mediaforge.sh build --av1-enc=rav1e
_run    "av1-enc=rav1e disables av1 (libaom)"   "Skipping av1 (disabled via CLI)" \
  ./mediaforge.sh build --av1-enc=rav1e
```

- [ ] **Step 2: Run**

```sh
sh tests/dry-run-matrix.sh
```

Expected: all PASS.

- [ ] **Step 3: Commit**

```sh
git add tests/dry-run-matrix.sh
git commit -m "test: dry-run matrix coverage for aac/h264/h265/av1-enc groups"
```

**Stage D done.**

---

## Stage E — Choice persistence

### Task E1: Read .mediaforge-choices on startup

**Files:**
- Modify: `lib/resolve.sh`
- Modify: `mediaforge.sh`

- [ ] **Step 1: Add the loader to `lib/resolve.sh`**

Append to `lib/resolve.sh`:

```sh
# Load previously-stored choices, if present. Stored values are applied
# *under* CLI flags (i.e. CLI overrides storage). Per spec §11.1.
load_stored_choices() {
  _file="$PREFIX/.mediaforge-choices"
  [ -f "$_file" ] || return 0
  # Source in a subshell first to verify syntax before applying
  if ! ( . "$_file" ); then
    warn "$_file is malformed — ignoring"
    return 0
  fi
  # Apply only when CLI did not set
  . "$_file"
  : "${TLS_BACKEND:=$STORED_TLS_BACKEND}"
  : "${AAC_IMPL:=$STORED_AAC_IMPL}"
  : "${H264_IMPL:=$STORED_H264_IMPL}"
  : "${H265_IMPL:=$STORED_H265_IMPL}"
  : "${AV1_ENC_IMPL:=$STORED_AV1_ENC_IMPL}"
}

# Save resolved choices for next run.
save_stored_choices() {
  _file="$PREFIX/.mediaforge-choices"
  mkdir -p "$PREFIX"
  cat >"$_file" <<EOF
# Generated by mediaforge — edit at your own risk; --clean-choices removes this file.
STORED_TLS_BACKEND=$TLS_BACKEND
STORED_AAC_IMPL=$AAC_IMPL
STORED_H264_IMPL=$H264_IMPL
STORED_H265_IMPL=$H265_IMPL
STORED_AV1_ENC_IMPL=$AV1_ENC_IMPL
EOF
}
```

- [ ] **Step 2: Call them from `mediaforge.sh`**

In `mediaforge.sh:cmd_build`, find the line `DISABLE_PKGS_INPUT="$DISABLE_PKGS"` (added in Task C2). Insert directly **before** it:

```sh
  # Load stored choices from previous run (CLI flags still take precedence
  # because we only set values that are currently empty).
  load_stored_choices
```

After `resolve_choices`, add:

```sh
  save_stored_choices
```

- [ ] **Step 3: Add `--menu` skip-load behaviour**

Update `load_stored_choices` to skip when the menu flag is on. In `lib/resolve.sh`:

```sh
load_stored_choices() {
  [ "${USE_MENU:-false}" = true ] && return 0
  ...
```

(Define `USE_MENU=false` as a default near the top of `mediaforge.sh` for safety.)

- [ ] **Step 4: Run tests**

```sh
sh tests/run.sh
```

Expected: PASS.

- [ ] **Step 5: Manual smoke test**

```sh
./mediaforge.sh build --tls=mbedtls --dry-run --yes
cat workspace/.mediaforge-choices
./mediaforge.sh build --dry-run --yes 2>&1 | grep "Choices:"
```

Expected: second invocation shows `tls=mbedtls` even though `--tls=` was not passed.

- [ ] **Step 6: Commit**

```sh
git add lib/resolve.sh mediaforge.sh
git commit -m "resolve: persist and restore choice matrix in $PREFIX/.mediaforge-choices"
```

---

### Task E2: Add --clean-choices

**Files:**
- Modify: `mediaforge.sh`

- [ ] **Step 1: Add the parser arm and handler**

In `mediaforge.sh`, in the long-options block of `cmd_build`, add before `--)`:

```sh
      --clean-choices)     rm -f "$TOPDIR/workspace/.mediaforge-choices"; log "Cleared stored choices"; exit 0 ;;
```

(Note: this exits immediately — it is a maintenance subcommand, not a build modifier.)

- [ ] **Step 2: Update `cmd_help`**

```sh
  printf '      --clean-choices       Delete the stored choice matrix and exit\n'
```

- [ ] **Step 3: Manual smoke test**

```sh
./mediaforge.sh build --tls=mbedtls --dry-run --yes
ls workspace/.mediaforge-choices  # exists
./mediaforge.sh build --clean-choices
ls workspace/.mediaforge-choices  # not found
```

Expected: file disappears after `--clean-choices`.

- [ ] **Step 4: Commit**

```sh
git add mediaforge.sh
git commit -m "cli: --clean-choices removes the stored choice matrix"
```

**Stage E done.**

---

## Stage F — Smart prompts

### Task F1: Create lib/menu.sh with POSIX primitives

**Files:**
- Create: `lib/menu.sh`
- Modify: `mediaforge.sh`

- [ ] **Step 1: Write `lib/menu.sh`**

```sh
# Interactive menu primitives. Use whiptail when present; fall back to a pure
# POSIX read-loop otherwise. Both primitives echo the chosen tag(s) on stdout
# and exit 0 on success, 1 on cancel, 2 on error.

# menu_radiolist TITLE DEFAULT_TAG  TAG1 DESC1  TAG2 DESC2  ...
# Echoes one selected tag.
menu_radiolist() {
  _title=$1; shift
  _default=$1; shift

  if command -v whiptail >/dev/null 2>&1; then
    _args=""
    while [ $# -ge 2 ]; do
      _tag=$1; _desc=$2; shift 2
      _on=off
      [ "$_tag" = "$_default" ] && _on=on
      _args="$_args $_tag \"$_desc\" $_on"
    done
    eval whiptail --title "\"$_title\"" --radiolist "\"Select one\"" 20 70 12 $_args 3>&1 1>&2 2>&3
    return $?
  fi

  # POSIX fallback: numbered list + read
  printf '\n%s\n' "$_title" >&2
  _i=0
  _tags=""
  _default_idx=1
  while [ $# -ge 2 ]; do
    _tag=$1; _desc=$2; shift 2
    _i=$((_i + 1))
    [ "$_tag" = "$_default" ] && _default_idx=$_i
    printf '  %d) %s — %s\n' "$_i" "$_tag" "$_desc" >&2
    _tags="$_tags $_tag"
  done
  while :; do
    printf 'Enter choice [1-%d, default %d]: ' "$_i" "$_default_idx" >&2
    read -r _reply || return 1
    [ -z "$_reply" ] && _reply=$_default_idx
    case "$_reply" in
      ''|*[!0-9]*) printf 'Invalid input.\n' >&2; continue ;;
    esac
    [ "$_reply" -lt 1 ] || [ "$_reply" -gt "$_i" ] && {
      printf 'Out of range.\n' >&2; continue
    }
    _j=0
    for _t in $_tags; do
      _j=$((_j + 1))
      [ "$_j" = "$_reply" ] && { printf '%s\n' "$_t"; return 0; }
    done
  done
}

# menu_checklist TITLE  TAG1 DESC1 ON|OFF  TAG2 DESC2 ON|OFF  ...
# Echoes selected tags one per line.
menu_checklist() {
  _title=$1; shift

  if command -v whiptail >/dev/null 2>&1; then
    _args=""
    while [ $# -ge 3 ]; do
      _tag=$1; _desc=$2; _state=$3; shift 3
      _args="$_args $_tag \"$_desc\" $_state"
    done
    eval whiptail --title "\"$_title\"" --separate-output --checklist "\"Toggle items\"" 20 70 12 $_args 3>&1 1>&2 2>&3
    return $?
  fi

  # POSIX fallback: toggle loop
  printf '\n%s\n' "$_title" >&2
  _tags=""
  _states=""
  _i=0
  while [ $# -ge 3 ]; do
    _tag=$1; _desc=$2; _state=$3; shift 3
    _i=$((_i + 1))
    _tags="$_tags $_tag"
    _states="$_states $_state"
  done
  _menu_render() {
    _j=0
    for _t in $_tags; do
      _j=$((_j + 1))
      _s=$(printf '%s' "$_states" | awk -v n="$_j" '{print $n}')
      _mark="[ ]"
      [ "$_s" = "on" ] && _mark="[x]"
      printf '  %s %d) %s\n' "$_mark" "$_j" "$_t" >&2
    done
  }
  while :; do
    _menu_render
    printf 'Toggle [1-%d], or empty line to confirm: ' "$_i" >&2
    read -r _reply || return 1
    [ -z "$_reply" ] && break
    case "$_reply" in
      ''|*[!0-9]*) printf 'Invalid input.\n' >&2; continue ;;
    esac
    [ "$_reply" -lt 1 ] || [ "$_reply" -gt "$_i" ] && {
      printf 'Out of range.\n' >&2; continue
    }
    # Toggle position $_reply in $_states
    _new=""
    _j=0
    for _s in $_states; do
      _j=$((_j + 1))
      if [ "$_j" = "$_reply" ]; then
        [ "$_s" = "on" ] && _new="$_new off" || _new="$_new on"
      else
        _new="$_new $_s"
      fi
    done
    _states=$_new
  done
  _j=0
  for _t in $_tags; do
    _j=$((_j + 1))
    _s=$(printf '%s' "$_states" | awk -v n="$_j" '{print $n}')
    [ "$_s" = "on" ] && printf '%s\n' "$_t"
  done
  return 0
}
```

- [ ] **Step 2: Source it from `mediaforge.sh`**

Add to the source-libs block:

```sh
. "$SCRIPT_DIR/lib/menu.sh"
```

- [ ] **Step 3: Lint**

```sh
sh tests/shellcheck.sh
```

Expected: PASS. (Both primitives use only POSIX features: `read -r`, `awk`, `printf`. No Bash arrays, `[[`, or `+=`.)

- [ ] **Step 4: Commit**

```sh
git add lib/menu.sh mediaforge.sh
git commit -m "menu: POSIX/whiptail primitives menu_radiolist + menu_checklist"
```

---

### Task F2: Wire smart prompts into resolve_choices

**Files:**
- Modify: `lib/resolve.sh`
- Create: `tests/menu-stdin.sh`
- Modify: `tests/run.sh`

- [ ] **Step 1: Add an interactivity probe to `lib/utils.sh`**

If not already present, add to `lib/utils.sh`:

```sh
# Returns 0 if running interactively (TTY on stdin, --yes not set, $CI not set).
is_interactive() {
  [ "${AUTOINSTALL:-}" = "yes" ] && return 1
  [ -n "${CI:-}" ] && return 1
  [ -t 0 ] && return 0
  return 1
}
```

- [ ] **Step 2: Modify `resolve_choices` to prompt when explicit choice missing**

In `lib/resolve.sh:resolve_choices`, **before** the `: "${TLS_BACKEND:=...}"` block, insert:

```sh
  # Smart prompts: ask when the user did not pick and we are interactive.
  if is_interactive; then
    [ -z "$TLS_BACKEND" ] && TLS_BACKEND=$(menu_radiolist \
      "Pick a TLS backend" "$TLS_BACKEND_DEFAULT_BUILTIN" \
      gnutls   "GnuTLS — free, default" \
      openssl  "OpenSSL — Apache 2.0" \
      mbedtls  "mbedTLS — small footprint" \
      libressl "LibreSSL libtls" \
      none     "No TLS support") || die "TLS prompt cancelled"
    [ -z "$AAC_IMPL" ] && AAC_IMPL=$(menu_radiolist \
      "Pick an AAC encoder" "$AAC_IMPL_DEFAULT_BUILTIN" \
      native   "FFmpeg native AAC (always available)" \
      fdk_aac  "Fraunhofer FDK-AAC (requires --enable-nonfree)") || die "AAC prompt cancelled"
    if [ "$ENABLE_GPL" = true ]; then
      [ -z "$H264_IMPL" ] && H264_IMPL=$(menu_radiolist \
        "Pick an H.264 encoder" "$H264_IMPL_DEFAULT_BUILTIN" \
        x264     "x264 — GPL, de-facto standard" \
        openh264 "OpenH264 — BSD source, MPEG-LA royalties apply") || die "H.264 prompt cancelled"
      [ -z "$H265_IMPL" ] && H265_IMPL=$(menu_radiolist \
        "Pick an H.265 encoder" "$H265_IMPL_DEFAULT_BUILTIN" \
        x265    "x265 — GPL" \
        kvazaar "Kvazaar — LGPL") || die "H.265 prompt cancelled"
    fi
    [ -z "$AV1_ENC_IMPL" ] && AV1_ENC_IMPL=$(menu_radiolist \
      "Pick an AV1 encoder" "$AV1_ENC_IMPL_DEFAULT_BUILTIN" \
      svtav1 "SVT-AV1 — fastest, recommended" \
      rav1e  "rav1e — pure Rust" \
      av1    "libaom — reference encoder, slow") || die "AV1 prompt cancelled"
  fi
```

- [ ] **Step 3: Write the scripted-stdin test**

Create `tests/menu-stdin.sh`:

```sh
#!/bin/sh
# Verify the POSIX menu fallback by feeding numeric choices via stdin.
# Forces non-whiptail path by temporarily masking the binary.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# Hide whiptail from PATH for these tests
_BIN=$(mktemp -d)
trap 'rm -rf "$_BIN"' EXIT
printf '#!/bin/sh\nexit 127\n' >"$_BIN/whiptail"
chmod +x "$_BIN/whiptail"
PATH="$_BIN:$PATH"
export PATH

_fail=0

# Choose option 2 for TLS (openssl), default (empty) for the rest.
_input='2

'
_output=$(printf '%s' "$_input" | ./mediaforge.sh build --dry-run 2>&1) || true
if printf '%s' "$_output" | grep -q "tls=openssl"; then
  printf 'PASS [POSIX menu picks tls=openssl]\n'
else
  printf 'FAIL [POSIX menu]: did not pick openssl\n'
  printf '%s\n' "$_output"
  _fail=1
fi

exit "$_fail"
```

Make executable, add to `tests/run.sh`:

```sh
chmod +x tests/menu-stdin.sh
```

In `tests/run.sh`, add before the final `printf`:

```sh
sh tests/menu-stdin.sh
```

- [ ] **Step 4: Run tests**

```sh
sh tests/run.sh
```

Expected: PASS. The `menu-stdin.sh` script confirms the POSIX fallback path picks the right backend.

- [ ] **Step 5: Commit**

```sh
git add lib/resolve.sh lib/utils.sh tests/menu-stdin.sh tests/run.sh
git commit -m "resolve: smart prompts via menu primitives when interactive"
```

**Stage F done.**

---

## Stage G — Full --menu

### Task G1: Add --menu CLI flag and four-screen flow

**Files:**
- Modify: `mediaforge.sh`
- Modify: `lib/resolve.sh`

- [ ] **Step 1: Add the parser arm**

In `mediaforge.sh`, in the long-options `case`, add:

```sh
      --menu)              USE_MENU=true ;;
```

Add to the defaults block:
```sh
USE_MENU=false
```

- [ ] **Step 2: Add a `run_menu` function in `lib/resolve.sh`**

Append:

```sh
# Four-screen interactive menu. Sets ENABLE_GPL, ENABLE_NONFREE,
# the per-group choices, and adds to DISABLE_PKGS / ENABLE_PKGS.
run_menu() {
  if ! is_interactive; then
    die "--menu requires an interactive terminal"
  fi
  if [ "${AUTOINSTALL:-}" = "yes" ]; then
    die "--menu and --yes are mutually exclusive"
  fi

  # Screen 1 — licence tier
  _tier=$(menu_radiolist "Licence tier" "free" \
    free    "Free codecs only" \
    gpl     "GPL codecs (x264, x265, xvidcore, vid_stab)" \
    nonfree "GPL + non-free (fdk_aac, srt over openssl)") || die "Menu cancelled"
  case "$_tier" in
    free)    ENABLE_GPL=false; ENABLE_NONFREE=false ;;
    gpl)     ENABLE_GPL=true;  ENABLE_NONFREE=false ;;
    nonfree) ENABLE_GPL=true;  ENABLE_NONFREE=true ;;
  esac

  # Screen 2 — build options
  _opts=$(menu_checklist "Build options" \
    static  "Full static binary (Linux only)" off \
    small   "Minimal build" off \
    lv2     "LV2 audio plugin chain" on \
    rebuild "Rebuild outdated dependencies" off) || die "Menu cancelled"
  for _o in $_opts; do
    case "$_o" in
      static)  _enable_static=true ;;
      small)   _enable_small=true ;;
      lv2)     ;; # default-on; if missing, disable
      rebuild) REBUILD_OUTDATED=true ;;
    esac
  done
  case " $_opts " in
    *" lv2 "*) ;;
    *) DISABLE_PKGS="$DISABLE_PKGS lv2" ;;
  esac

  # Screen 3 — mutex group picks (radiolists)
  TLS_BACKEND=$(menu_radiolist "TLS backend" "${TLS_BACKEND:-gnutls}" \
    gnutls   "GnuTLS"        \
    openssl  "OpenSSL"       \
    mbedtls  "mbedTLS"       \
    libressl "LibreSSL"      \
    none     "No TLS")       || die "Menu cancelled"
  AAC_IMPL=$(menu_radiolist "AAC encoder" "${AAC_IMPL:-native}" \
    native   "FFmpeg native"             \
    fdk_aac  "FDK-AAC (nonfree)")        || die "Menu cancelled"
  if [ "$ENABLE_GPL" = true ]; then
    H264_IMPL=$(menu_radiolist "H.264 encoder" "${H264_IMPL:-x264}" \
      x264     "x264 (GPL)" \
      openh264 "OpenH264 (BSD source)") || die "Menu cancelled"
    H265_IMPL=$(menu_radiolist "H.265 encoder" "${H265_IMPL:-x265}" \
      x265    "x265 (GPL)" \
      kvazaar "Kvazaar (LGPL)") || die "Menu cancelled"
  fi
  AV1_ENC_IMPL=$(menu_radiolist "AV1 encoder" "${AV1_ENC_IMPL:-svtav1}" \
    svtav1 "SVT-AV1" \
    rav1e  "rav1e"   \
    av1    "libaom (slow reference)") || die "Menu cancelled"
}
```

- [ ] **Step 3: Call `run_menu` from `mediaforge.sh`**

In `cmd_build`, after the parser loop and after registry/`load_stored_choices`, but **before** `resolve_choices`, add:

```sh
  if [ "$USE_MENU" = true ]; then
    run_menu
  fi
```

- [ ] **Step 4: Update `cmd_help`**

```sh
  printf '      --menu                Interactive selector (whiptail or POSIX fallback)\n'
```

- [ ] **Step 5: Manual smoke test**

```sh
./mediaforge.sh build --menu --dry-run
```

Expected: a series of menus appears (whiptail if installed, otherwise numbered prompts). After confirming defaults at every screen, the dry-run proceeds.

- [ ] **Step 6: Lint and commit**

```sh
sh tests/run.sh
git add mediaforge.sh lib/resolve.sh
git commit -m "menu: --menu launches the four-screen interactive flow"
```

---

### Task G2: --menu rejects --yes and reads no stored choices

**Files:**
- Modify: `mediaforge.sh`

- [ ] **Step 1: Verify the rejection happens early**

In `mediaforge.sh`, after parser-loop completion but before `load_stored_choices`, add:

```sh
  if [ "$USE_MENU" = true ] && [ "$AUTOINSTALL" = "yes" ]; then
    die "--menu and --yes are mutually exclusive"
  fi
```

- [ ] **Step 2: Add a negative test**

In `tests/negative.sh`, append:

```sh
_run "--menu --yes is rejected" "mutually exclusive" \
  ./mediaforge.sh build --menu --yes
```

- [ ] **Step 3: Run tests**

```sh
sh tests/run.sh
```

Expected: PASS.

- [ ] **Step 4: Commit**

```sh
git add mediaforge.sh tests/negative.sh
git commit -m "menu: --menu and --yes are mutually exclusive"
```

**Stage G done.**

---

## Stage H — Profile defaults and documentation

### Task H1: Add commented *_DEFAULT lines to all four profiles

**Files:**
- Modify: `profiles/ffmpeg-8.0.1.conf`
- Modify: `profiles/ffmpeg-7.1.conf`
- Modify: `profiles/ffmpeg-7.0.conf`
- Modify: `profiles/ffmpeg-6.1.conf`

- [ ] **Step 1: Append a default-overrides block to each profile**

For each of the four profile files, append:

```sh
# --- Group defaults (uncomment to override the global defaults) ---
# TLS_BACKEND_DEFAULT=gnutls
# AAC_IMPL_DEFAULT=native
# H264_IMPL_DEFAULT=x264
# H265_IMPL_DEFAULT=x265
# AV1_ENC_IMPL_DEFAULT=svtav1
```

- [ ] **Step 2: Wire profile defaults into the resolver**

In `lib/resolve.sh:resolve_choices`, replace the section:
```sh
  : "${TLS_BACKEND:=$TLS_BACKEND_DEFAULT_BUILTIN}"
  : "${AAC_IMPL:=$AAC_IMPL_DEFAULT_BUILTIN}"
  : "${H264_IMPL:=$H264_IMPL_DEFAULT_BUILTIN}"
  : "${H265_IMPL:=$H265_IMPL_DEFAULT_BUILTIN}"
  : "${AV1_ENC_IMPL:=$AV1_ENC_IMPL_DEFAULT_BUILTIN}"
```

with:

```sh
  : "${TLS_BACKEND:=${TLS_BACKEND_DEFAULT:-$TLS_BACKEND_DEFAULT_BUILTIN}}"
  : "${AAC_IMPL:=${AAC_IMPL_DEFAULT:-$AAC_IMPL_DEFAULT_BUILTIN}}"
  : "${H264_IMPL:=${H264_IMPL_DEFAULT:-$H264_IMPL_DEFAULT_BUILTIN}}"
  : "${H265_IMPL:=${H265_IMPL_DEFAULT:-$H265_IMPL_DEFAULT_BUILTIN}}"
  : "${AV1_ENC_IMPL:=${AV1_ENC_IMPL_DEFAULT:-$AV1_ENC_IMPL_DEFAULT_BUILTIN}}"
```

The precedence ladder is now: CLI → menu → smart-prompt → stored choices → profile default → built-in default. (Stored choices already set values via `load_stored_choices` before this resolves; CLI sets values directly in the parser; menu sets values in `run_menu`.)

- [ ] **Step 3: Run tests**

```sh
sh tests/run.sh
```

Expected: PASS.

- [ ] **Step 4: Commit**

```sh
git add profiles/ lib/resolve.sh
git commit -m "profiles: optional *_DEFAULT overrides for group choices"
```

---

### Task H2: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add `PKG_MUTEX_GROUP` to the recipe-framework section**

In `CLAUDE.md` §"Recipe Framework", under "Key optional variables", add a new bullet:

```markdown
- `PKG_MUTEX_GROUP="tls"` — declare the recipe as a member of a mutex group;
  the resolver enforces at-most-one-active per group via `--tls=`, `--aac=`,
  `--h264=`, `--h265=`, `--av1-enc=`. See `docs/cli-flags.md`.
```

- [ ] **Step 2: Add the new flags to the CLI section**

In `CLAUDE.md` §"CLI Structure", append:

```markdown
**Group selectors:**
- `--tls=BACKEND` — `openssl|gnutls|mbedtls|libressl|none` (default: gnutls)
- `--aac=IMPL` — `fdk_aac|native` (default: native)
- `--h264=IMPL` — `x264|openh264` (default: x264)
- `--h265=IMPL` — `x265|kvazaar` (default: x265)
- `--av1-enc=IMPL` — `svtav1|rav1e|av1` (default: svtav1)

**Generic toggles:**
- `--enable=PKG` / `--disable=PKG` — repeatable, comma-separated. Validated
  against the recipe registry; typo suggestions on miss.
- `--list-pkgs` — print every recipe with category and mutex group.
- `--menu` — interactive whiptail (POSIX fallback) selector.
- `--clean-choices` — delete `$PREFIX/.mediaforge-choices`.
```

- [ ] **Step 3: Update the "Commands" example block**

Add to the existing list of example invocations:

```markdown
# Build with explicit TLS backend (e.g. for Rust BoringSSL link compatibility)
./mediaforge.sh build --tls=gnutls

# Build via interactive menu
./mediaforge.sh build --menu
```

- [ ] **Step 4: Commit**

```sh
git add CLAUDE.md
git commit -m "docs(CLAUDE): document PKG_MUTEX_GROUP and new CLI flags"
```

---

### Task H3: Create docs/cli-flags.md

**Files:**
- Create: `docs/cli-flags.md`

- [ ] **Step 1: Generate the recipe table**

```sh
./mediaforge.sh build --list-pkgs > /tmp/pkgs.tsv
```

- [ ] **Step 2: Write `docs/cli-flags.md`**

```markdown
# mediaforge CLI flags reference

This is a generated listing of every recipe and the CLI flags that affect it.

## Group selectors

| Flag | Allowed values | Default | Notes |
|---|---|---|---|
| `--tls=BACKEND` | `openssl`, `gnutls`, `mbedtls`, `libressl`, `none` | `gnutls` | mbedtls and libressl recipes are static-only. |
| `--aac=IMPL` | `fdk_aac`, `native` | `native` | `fdk_aac` requires `--enable-nonfree`. |
| `--h264=IMPL` | `x264`, `openh264` | `x264` (with `--enable-gpl`) | Both encoders require MPEG-LA patent licensing for redistribution. See "Patent caveat" below. |
| `--h265=IMPL` | `x265`, `kvazaar` | `x265` (with `--enable-gpl`) | x265 is GPL; Kvazaar is LGPL. Same patent caveat as H.264. |
| `--av1-enc=IMPL` | `svtav1`, `rav1e`, `av1` | `svtav1` | `av1` = libaom (reference encoder; slow). |

## Generic toggles

- `--enable=PKG` — force-enable a recipe that defaults to off. Does **not** override `--enable-gpl` / `--enable-nonfree` / platform guards.
- `--disable=PKG` — disable a recipe by name. Repeatable; commas accepted.
- `--list-pkgs` — print every recipe.
- `--menu` — interactive selector.
- `--clean-choices` — delete the persistent choice file.

## Patent caveat (H.264 / H.265)

Both `x264`/`openh264` and `x265`/`kvazaar` are patent-encumbered when
*built from source*. OpenH264's BSD-3 license covers the source code only;
Cisco's royalty-free distribution applies exclusively to their pre-built
binary download, which mediaforge does not consume. End users distributing
binaries built with these encoders remain liable for MPEG-LA royalties
unless they qualify for an exemption. Choosing between `x264` and
`openh264` (or `x265` and `kvazaar`) is a software-license trade-off, not
a patent trade-off.

## Recipe inventory

[The table below is the output of `./mediaforge.sh build --list-pkgs` —
regenerate at release time.]

| Recipe | Category | Mutex group | Flags |
|---|---|---|---|
```

- [ ] **Step 3: Append the generated table**

```sh
awk -F'\t' '{ printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4 }' /tmp/pkgs.tsv >> docs/cli-flags.md
```

- [ ] **Step 4: Commit**

```sh
git add docs/cli-flags.md
git commit -m "docs: cli-flags.md with full recipe inventory and patent caveat"
```

---

### Task H4: Create docs/menu.md

**Files:**
- Create: `docs/menu.md`

- [ ] **Step 1: Write `docs/menu.md`**

```markdown
# mediaforge interactive menu

Run `./mediaforge.sh build --menu` to launch a four-screen wizard. mediaforge
prefers `whiptail` when installed; otherwise it falls back to a numbered
text prompt that works on any POSIX shell.

## Screen 1 — Licence tier

```
+--------- Licence tier ---------+
| ( ) free                       |
| ( ) gpl                        |
| (*) nonfree                    |
+--------------------------------+
```

`free` enables only LGPL-compatible recipes. `gpl` adds x264/x265/xvidcore/
vid_stab. `nonfree` further adds fdk_aac and srt-over-openssl.

## Screen 2 — Build options

```
+--------- Build options --------+
| [ ] static                     |
| [ ] small                      |
| [x] lv2                        |
| [ ] rebuild                    |
+--------------------------------+
```

Untick `lv2` to skip the LV2 audio-plugin chain (faster build).

## Screen 3 — Mutex group picks

One radiolist per group. The default is highlighted.

```
+--------- TLS backend ----------+
| (*) gnutls                     |
| ( ) openssl                    |
| ( ) mbedtls                    |
| ( ) libressl                   |
| ( ) none                       |
+--------------------------------+
```

Same pattern for AAC, H.264, H.265, AV1 encoder. The H.264 and H.265
screens appear only when `gpl` or `nonfree` was chosen on Screen 1.

## Cancel handling

Pressing **Esc** or **Cancel** at any screen aborts the build with
`menu cancelled`. Pressing **OK** with no items ticked (Screen 2) is
treated as "no overrides for this screen" — the build continues with
defaults.

## POSIX fallback

When `whiptail` is absent, the same four screens are rendered as
numbered lists. Type the number of the choice and press Enter; press
Enter on an empty line to confirm a checklist with current ticks. Empty
input on a radiolist accepts the default.
```

- [ ] **Step 2: Commit**

```sh
git add docs/menu.md
git commit -m "docs: menu.md walkthrough of the four-screen interactive flow"
```

**Stage H done.**

---

## Final verification

### Task FV: End-to-end smoke run

- [ ] **Step 1: Lint**

```sh
sh tests/run.sh
```

Expected: every test passes.

- [ ] **Step 2: Verify default dry-run**

```sh
./mediaforge.sh build --dry-run --yes 2>&1 | tail -20
```

Expected: `Choices: tls=gnutls aac=native h264=x264 h265=x265 av1-enc=svtav1`, then a normal recipe loop.

- [ ] **Step 3: Verify rdlp-unblocking invocation**

```sh
./mediaforge.sh build --tls=gnutls --enable-nonfree --dry-run --yes 2>&1 | grep -E "Skipping (openssl|gnutls)"
```

Expected: `Skipping openssl (disabled via CLI)` — gnutls is **not** skipped.

- [ ] **Step 4: Verify --menu launches**

```sh
./mediaforge.sh build --menu --dry-run
```

Expected: interactive prompts appear; accepting all defaults completes the dry-run.

- [ ] **Step 5: Run shellcheck on the entire tree (no exclusions)**

```sh
shellcheck -s sh -e SC1090,SC1091,SC2034 mediaforge.sh lib/*.sh tests/*.sh recipes/*/*.sh
```

Expected: no warnings.

- [ ] **Step 6: Update the rdlp memory note**

After confirming a real build works (you'll do this manually outside this
plan, since it requires network + an hour of compile time), update
`~/.claude/projects/-home-matte-dev-rust-rdlp/memory/project_mediaforge-ffmpeg-openssl.md`
to reflect that `--tls=gnutls` is now the supported one-flag fix and the
spec/plan paths exist in mediaforge.

---

## Summary of commits expected

In total, this plan produces ~25 commits along the feature branch:

- A1: test harness
- A2–A4: framework foundation (3)
- B1–B3: registry + generic flags (3)
- C1–C7: TLS backend selector (7)
- D1–D2: other mutex groups (2)
- E1–E2: persistence (2)
- F1–F2: smart prompts (2)
- G1–G2: full menu (2)
- H1–H4: profiles + docs (4)
- FV: final verification (no new commits, only a memory update)

Each commit is independently `sh -n` clean and (from C1 onward) passes the
dry-run matrix.

When all tasks are complete, invoke `superpowers:requesting-code-review`,
then `superpowers:finishing-a-development-branch` to merge into `develop`.
