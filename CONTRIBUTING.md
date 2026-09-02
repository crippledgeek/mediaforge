# Contributing to mediaforge

## Getting Started

1. Fork the repository
2. Register the repo's git hooks: `git config core.hooksPath .githooks` (see [Git Hooks](#git-hooks))
3. Create a feature branch from `develop`
4. Make your changes
5. Run the lint gate: `./tests/shellcheck.sh`
6. Run the test suite: `sh tests/run.sh`
7. Test a full build: `./mediaforge.sh build --enable-nonfree`
8. Submit a pull request targeting `develop`

## Git Hooks

`.githooks/pre-push` runs `tests/shellcheck.sh` and refuses the push if it fails.

Git does not install hooks from a checkout, so cloning does not enable it. Each
clone opts in once:

```sh
git config core.hooksPath .githooks
```

`core.hooksPath` replaces the hook directory **for every hook type**, not just
`pre-push`. If you keep personal hooks in `.git/hooks/` for this repo, move them
into `.githooks/` (or expect them to stop firing — silently, with no error).

Things worth knowing about what the hook checks:

- It lints the **working tree**, not the commits being pushed. Pushing from a
  clean tree makes those the same thing; pushing with unrelated dirty edits does
  not.
- A **deletion-only** push (`git push origin --delete <branch>`) ships no content
  and is let through, so a lint failure that predates the deletion cannot block
  the branch cleanup this workflow expects.
- It sets `REQUIRE_SHELLCHECK=1`, so the gate **refuses to report a pass** when
  `shellcheck` is not installed. An ad-hoc `./tests/shellcheck.sh` still degrades
  to the `sh -n` half and says so; a gate that blocks a push does not get to.
- The gate covers every executable file under `.githooks/` — checked first, so
  a hook you just broke is reported in a fraction of a second — plus
  `mediaforge.sh` itself and every `.sh` file under `lib/`, `recipes/`, and
  `tests/`. A syntax error in the hook would otherwise block every push with a
  failure nothing lints.
- It refuses a linter that only *resolves*: `SHELLCHECK=` may name the binary,
  but the binary must identify itself as ShellCheck. A no-op shim would
  otherwise report every file clean, in silence.
- It fails if `mediaforge.sh` or `tests/shellcheck.sh` has lost its executable
  bit. Those are the two commands documented here as `./path`, and nothing else
  in the tree depends on their mode — so if you see that error after a fresh
  clone on a filesystem that drops modes (a zip export, a Windows checkout, a
  copy over CIFS), it is this rule firing, not a broken checkout: `chmod +x`
  them.

Do not push past a failing hook with `--no-verify`; fix the findings.

**Reviewing changes to `.githooks/`.** This is the one directory whose contents
run automatically, on a contributor's machine, outside CI. The project already
executes in-repo shell freely — every recipe is sourced during a build — so this
is not a new class of trust, but a diff that touches `.githooks/` deserves the
same attention as one that touches a recipe's `pkg_install`.

## Shell Style

All code must be **POSIX sh** — no Bashisms.

- `[ "$var" = value ]` not `[[ ]]`
- `command -v` not `which`
- `printf` not `echo` (where output matters)
- No arrays, no `local`, no `+=`, no `=~`, no process substitution
- Prefix local-scope variables with `_` (e.g., `_pkg`, `_ver`)
- `sed ... > tmp && mv tmp orig` not `sed -i`
- Prefer `awk` over `sed` for field-based edits
- Use `patch -p1` for complex multi-line source fixes (store in `patches/`)
- **Shell source is ASCII** — write `--`, not an em-dash (this file is Markdown, and prose may use whatever it likes)

`tests/output-and-startup-hygiene.sh` fails on any byte outside printable ASCII
in a `.sh` file, because two separate paths damage such a byte and neither is
obvious from the source. `log`/`warn`/`die` run their text through
`mf_printable`, which filters in the C locale where `[:print:]` is 0x20-0x7E, so
a multibyte character is deleted outright and the message reaches the operator
with a gap where the author wrote a dash. whiptail takes the other path: it is
an ncursesw front end whose multibyte decoding is gated on `LC_CTYPE`, so under
`LC_ALL=C` a menu label's em-dash renders as `\342<80><94>` — the lead byte raw
and its continuations in escape notation, eight columns where one dash was
meant. Nothing filters that path at all.

This is the convention the tools mediaforge sits between already follow. GNU's
coding standards make it normative — in the C locale, output sticks to plain
ASCII, and non-ASCII is permitted only once a program has positively detected a
non-C locale — and FFmpeg's own `configure`, the script mediaforge wraps, holds
no non-ASCII byte at all.

## Adding a Recipe

1. Create `recipes/<category>/<name>.sh`:

```sh
PKG_NAME="mylib"
PKG_VERSION="${PKG_VERSION_MYLIB:-1.0.0}"
PKG_URL="https://example.com/mylib-${PKG_VERSION}.tar.gz"
PKG_FFMPEG_OPT="--enable-mylib"

# Override phases as needed
pkg_configure() {
  run ./configure --prefix="$PREFIX" --disable-shared --enable-static
}
```

2. Add the recipe path to `recipes/_order.conf` (respecting dependency order)
3. Add a version pin to each profile in `profiles/ffmpeg-*.conf`:
   ```
   PKG_VERSION_MYLIB="1.0.0"
   ```
4. Test: `./mediaforge.sh build`

### Recipe Variables

| Variable | Required | Description |
|---|---|---|
| `PKG_NAME` | Yes | Package identifier |
| `PKG_VERSION` | Yes | Version string (use `${PKG_VERSION_NAME:-default}` for profile support) |
| `PKG_URL` | Yes* | Download URL (*not required if `PKG_SKIP_EXTRACT=true`) |
| `PKG_FFMPEG_OPT` | No | FFmpeg configure flag to accumulate |
| `PKG_GPL` | No | Set `true` to require `--enable-gpl` |
| `PKG_NONFREE` | No | Set `true` to require `--enable-nonfree` |
| `PKG_CMAKE` | No | Set `true` to use cmake instead of autoconf |
| `PKG_CMAKE_FLAGS` | No | Extra cmake flags |
| `PKG_COMMIT` | No | Git commit to pin when fetching from a repo rather than a tarball |
| `PKG_DISABLED` | No | Set `true` to skip the recipe entirely (used by version guards) |
| `PKG_HASH_FILE` | No | Digest sidecar path, when it is not `<recipe>.hash` |
| `PKG_MUTEX_GROUP` | No | Names the selector group this recipe competes in (tls, aac, h264, ...) |
| `PKG_PC_FILES` | No | The .pc files this recipe drops, when they are not named after it |
| `PKG_TRANSITIVE_UTIL` | No | Set `true` if its .pc files are transitive utilities: kept in the workspace, excluded from the install prefix |
| `PKG_CMAKE_BUILD_TYPE` | No | cmake build type (e.g. `Release`). Empty means none is passed — do NOT write `-DCMAKE_BUILD_TYPE` yourself |
| `PKG_MESON_BUILDTYPE` | No | meson buildtype; defaults to `release` when unset |
| `PKG_C_STD` | No | C standard this source needs (e.g. `gnu11`). The framework appends `-std=` for this recipe only |
| `PKG_CONFIGURE_FLAGS` | No | Extra configure flags |
| `PKG_REQUIRES_CMD` | No | Space-separated list of required commands |
| `PKG_REQUIRES_MESON` | No | Set `true` to require meson + ninja |
| `PKG_LINUX_ONLY` | No | Set `true` to skip on non-Linux |
| `PKG_SKIP_ON_ARCH` | No | Architecture to skip (e.g., `arm64`) |
| `PKG_FILENAME` | No | Override tarball filename |
| `PKG_DIRNAME` | No | Override extracted directory name |
| `PKG_SKIP_EXTRACT` | No | Set `true` for header-only packages |
| `PKG_GITHUB_REPO` | No | `owner/repo` for update checking |

### Invoking cmake and meson

Recipes never call `run cmake` or `run meson setup` directly — use the framework
helpers, which supply the install prefix and the build type from the variables
above so those settings have exactly one spelling tree-wide:

```sh
mf_cmake -DFOO=ON .              # adds -DCMAKE_INSTALL_PREFIX and, if set, -DCMAKE_BUILD_TYPE
mf_meson build -Dbar=false       # adds --prefix, --buildtype, --default-library=static, --libdir
```

`cmake --build` / `cmake --install` and `meson compile` / `meson install` act on
an already-configured tree and are called directly as before.

`tests/cmake-single-entry.sh` and `tests/meson-single-entry.sh` enforce this, so
a hand-written invocation fails the suite rather than drifting quietly.

### Phase Functions

Override any subset — unoverridden phases use defaults:

| Phase | Default | Purpose |
|---|---|---|
| `pkg_prepare()` | no-op | Patches, source fixups. For a C standard use `PKG_C_STD`, not a `CFLAGS` append |
| `pkg_configure()` | `./configure` or `cmake` | Configure build |
| `pkg_build()` | `make -j $MJOBS` | Compile |
| `pkg_install()` | `make install` | Install to `$PREFIX` |
| `pkg_post_install()` | no-op | pkgconfig fixups, extra flags |

## Adding a Patch

For complex multi-line source fixes, use patch files instead of inline sed/awk:

1. Extract the clean source tarball
2. Copy the target file
3. Make your fix
4. Generate the patch: `diff -u original fixed > patches/<name>.patch`
5. Apply in `pkg_prepare()`: `patch -p1 < "$SCRIPT_DIR/patches/<name>.patch"`

## Commit Messages

Use conventional commits:

- `feat:` new recipe or feature
- `fix:` bug fix
- `refactor:` code change that doesn't add features or fix bugs
- `docs:` documentation only
- `chore:` maintenance (deps, CI, tooling)

## Branch Policy

- `main` — stable releases
- `develop` — integration branch
- `feature/*` — new features (branch from `develop`)
- `bugfix/*` — bug fixes (branch from `develop`)
- `hotfix/*` — production fixes (branch from `main`)
