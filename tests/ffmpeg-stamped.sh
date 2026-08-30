#!/bin/sh
# FFmpeg's own install is staged and stamped like every recipe's (GH-77).
#
# It was the one package writing into the workspace with no manifest behind it,
# because cmd_build sources recipes/ffmpeg.sh directly instead of running it
# through run_recipe, and the staging window lives in run_recipe. Measured on a
# full build before this: 9954 files in the prefix, 9706 claimed by a stamp, and
# every one of the 248 unclaimed was FFmpeg's own. That gap is why a prefix-side
# orphan audit had to be advisory -- with FFmpeg accounted for, the remainder is
# empty and the audit can be a gate.
#
# Asserted by reading the source rather than by building: driving this file means
# fetching and compiling FFmpeg. What that buys is still the load-bearing part,
# because all three claims are about ORDER, and order is what a green build
# cannot check -- the binary would be installed correctly either way.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd); cd "$ROOT"
_fail=0
# shellcheck source=tests/lib-assert.sh
. "$ROOT/tests/lib-assert.sh"

_code=$(_code_only recipes/ffmpeg.sh)
_line() { printf '%s\n' "$_code" | grep -nE "$1" | head -1 | cut -d: -f1; }

_begin=$(_line '^[[:space:]]*mf_stage_begin[[:space:]]*$')
_inst=$(_line '^[[:space:]]*run make install')
_stamp=$(_line '^[[:space:]]*stamp_write[[:space:]]+"ffmpeg"')
_end=$(_line '^[[:space:]]*mf_stage_end[[:space:]]*$')
_read=$(_line 'file "[$]PREFIX/bin/ffmpeg"')

# 1. The window exists at all, and wraps the install.
_reasons=""
[ -n "$_begin" ] || _reasons=" no mf_stage_begin, so make install writes straight to the live prefix and nothing records it."
[ -n "$_stamp" ] || _reasons="$_reasons no stamp_write for ffmpeg, so its 248 files are claimed by nobody."
[ -n "$_end" ]   || _reasons="$_reasons no mf_stage_end, so DESTDIR stays set past the install."
if [ -n "$_begin" ] && [ -n "$_inst" ] && [ -n "$_stamp" ] && [ -n "$_end" ]; then
  [ "$_begin" -lt "$_inst" ] && [ "$_inst" -lt "$_stamp" ] && [ "$_stamp" -lt "$_end" ] \
    || _reasons="$_reasons out of order (begin=$_begin install=$_inst stamp=$_stamp end=$_end)."
fi
_verdict ffmpeg-install-is-staged-and-stamped "$_reasons"

# 2. The merge precedes the read-back. stamp_write commits, and the `file` probe
#    below it reads $PREFIX -- so a stamp written after that probe would leave it
#    inspecting a path still in the stage. Ordering, again, not presence.
_reasons=""
if [ -z "$_read" ]; then
  _reasons=" nothing reads back \$PREFIX/bin/ffmpeg any more, so this assertion no longer guards what it names."
elif [ -z "$_stamp" ] || [ "$_stamp" -gt "$_read" ]; then
  _reasons=" the stamp (line ${_stamp:-none}) does not precede the read-back at line $_read, so the file(1) probe inspects a path still in the stage."
fi
_verdict ffmpeg-merges-before-it-reads-back "$_reasons"

# 3. DESTDIR on the COMMAND LINE, the form the GNU Coding Standards document and
#    the one default_install uses. FFmpeg honours the environment today, so the
#    environment-only form works -- until an upstream starts assigning DESTDIR in
#    a makefile, which beats the environment and fails silently, staging nothing
#    while installing correctly (lib/stage.sh, property 1; xvidcore is the
#    in-tree precedent at 0 files staged versus 3).
_reasons=""
printf '%s\n' "$_code" | grep -qE '^[[:space:]]*run make install DESTDIR="[$]DESTDIR"' \
  || _reasons=" make install does not pass DESTDIR on the command line, so a makefile that assigns it would silently stage nothing."
_verdict ffmpeg-passes-destdir-on-the-command-line "$_reasons"

# 4. And it must NOT gate. FFmpeg is the final target, and the stamp is keyed on
#    the version alone while its configure line changes with --enable-gpl,
#    --tls= and every other selector -- so skipping on it would ignore the flags
#    the operator just changed. Paired with the write above in ONE assertion,
#    because "does not call stamp_check" is true of the merge base too and would
#    otherwise pass there having verified nothing.
_reasons=""
[ -n "$_stamp" ] || _reasons=" ffmpeg writes no stamp at all."
printf '%s\n' "$_code" | grep -qE '(^|[^_[:alnum:]])stamp_check' \
  && _reasons="$_reasons it gates on a stamp, so changing --enable-gpl or --tls= would skip the rebuild that change asks for."
_verdict ffmpeg-stamp-is-evidence-not-a-gate "$_reasons"

# 5. The help text must not promise a skip that does not happen for FFmpeg.
_reasons=""
grep -qF 'FFmpeg is the exception' mediaforge.sh \
  || _reasons=" reconcile's help still tells the reader a drifted stamp means the recipe is skipped, which is false for the one stamp nothing gates on."
_verdict reconcile-help-names-the-ungated-stamp "$_reasons"

printf 'DONE: ffmpeg-stamped\n'
exit "$_fail"
