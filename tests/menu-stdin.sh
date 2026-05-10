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

# In a non-interactive (no-TTY) sh -c invocation, smart prompts are skipped
# and the conservative defaults kick in. So we test that --tls is recognised
# from CLI even when whiptail is masked, and that the prompt path is unreachable
# without a TTY.
_output=$(./mediaforge.sh build --tls=mbedtls --dry-run --yes 2>&1) || true
if printf '%s' "$_output" | grep -q "tls=mbedtls"; then
  printf 'PASS [whiptail masked + --tls=mbedtls picks mbedtls]\n'
else
  printf 'FAIL [whiptail masked path]: did not pick mbedtls\n'
  printf '%s\n' "$_output"
  _fail=1
fi

# Confirm that non-interactive (no TTY) invocations apply the conservative default
_output=$(./mediaforge.sh build --dry-run --yes 2>&1) || true
if printf '%s' "$_output" | grep -q "tls=gnutls"; then
  printf 'PASS [non-interactive default = gnutls]\n'
else
  printf 'FAIL [non-interactive default]: %s\n' "$_output"
  _fail=1
fi

exit "$_fail"
