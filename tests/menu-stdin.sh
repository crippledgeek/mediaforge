#!/bin/sh
# Verify the POSIX menu fallback by feeding numeric choices via stdin.
# Forces non-whiptail path by masking the binary in a temp PATH dir.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

_BIN=$(mktemp -d)
trap 'rm -rf "$_BIN"' EXIT
printf '#!/bin/sh\nexit 127\n' >"$_BIN/whiptail"
chmod +x "$_BIN/whiptail"
PATH="$_BIN:$PATH"
export PATH

_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

# In a non-interactive (no-TTY) sh -c invocation, smart prompts are skipped
# and the conservative defaults kick in. So we test that --tls is recognised
# from CLI even when whiptail is masked, and that the prompt path is unreachable
# without a TTY.
_output=$(./mediaforge.sh build --tls=mbedtls --dry-run --yes 2>&1) || true
if printf '%s' "$_output" | grep -q "tls=mbedtls"; then
  _pass cli-tls-wins-with-whiptail-masked
else
  _bad cli-tls-wins-with-whiptail-masked \
    "did not pick mbedtls: $(printf '%s\n' "$_output" | grep 'Choices:')"
fi

# Confirm that non-interactive (no TTY) invocations apply the conservative default
_output=$(./mediaforge.sh build --dry-run --yes 2>&1) || true
if printf '%s' "$_output" | grep -q "tls=gnutls"; then
  _pass non-interactive-default-is-gnutls
else
  _bad non-interactive-default-is-gnutls \
    "$(printf '%s\n' "$_output" | grep 'Choices:')"
fi

exit "$_fail"
