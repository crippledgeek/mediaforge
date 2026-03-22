# Contributing to mediaforge

## Getting Started

1. Fork the repository
2. Create a feature branch from `develop`
3. Make your changes
4. Run syntax checks: `for f in lib/*.sh recipes/**/*.sh; do sh -n "$f"; done`
5. Test a full build: `./mediaforge.sh build --enable-nonfree`
6. Submit a pull request targeting `develop`

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
| `PKG_CONFIGURE_FLAGS` | No | Extra configure flags |
| `PKG_REQUIRES_CMD` | No | Space-separated list of required commands |
| `PKG_REQUIRES_MESON` | No | Set `true` to require meson + ninja |
| `PKG_LINUX_ONLY` | No | Set `true` to skip on non-Linux |
| `PKG_SKIP_ON_ARCH` | No | Architecture to skip (e.g., `arm64`) |
| `PKG_FILENAME` | No | Override tarball filename |
| `PKG_DIRNAME` | No | Override extracted directory name |
| `PKG_SKIP_EXTRACT` | No | Set `true` for header-only packages |
| `PKG_GITHUB_REPO` | No | `owner/repo` for update checking |

### Phase Functions

Override any subset — unoverridden phases use defaults:

| Phase | Default | Purpose |
|---|---|---|
| `pkg_prepare()` | no-op | Patches, env setup |
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
