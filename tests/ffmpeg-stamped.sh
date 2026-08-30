#!/bin/sh
# FFmpeg's own install is staged and stamped like every recipe's (GH-77).
#
# It was the one package writing into the workspace with no manifest behind it,
# because cmd_build sources recipes/ffmpeg.sh directly instead of running it
# through run_recipe, and the staging window lives in run_recipe. FFmpeg's stamp
# now carries 248 paths that nothing recorded before.
#
# It does NOT make the prefix wholly accounted for, and an earlier draft of this
# comment claimed it did. Measured after a full rebuild of all 110 recipes, with
# $PREFIX's own dotfile state excluded: 153 paths are still claimed by no stamp
# -- 151 meson bytecode caches, written when meson RUNS rather than when it is
# installed, and 2 stale lv2 plugin UIs from a configuration that no longer
# builds them. What this closes is the largest single class, not the last one
# (GH-77).
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

_recipe=recipes/ffmpeg.sh
_begin=$(_code_line "$_recipe" '^[[:space:]]*mf_stage_begin[[:space:]]*$')
_inst=$(_code_line "$_recipe" '^[[:space:]]*run make install')
_stamp=$(_code_line "$_recipe" '^[[:space:]]*stamp_write[[:space:]]+"ffmpeg"')
_end=$(_code_line "$_recipe" '^[[:space:]]*mf_stage_end[[:space:]]*$')
_read=$(_code_line "$_recipe" 'file "[$]PREFIX/bin/ffmpeg"')

# 1. The window exists at all, and wraps the install.
_reasons=""
[ -n "$_begin" ] || _reasons=" no mf_stage_begin, so make install writes straight to the live prefix and nothing records it."
[ -n "$_inst" ]  || _reasons="$_reasons no install line inside the window, so the assertion would pass over a recipe that installs nothing."
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
_code_only "$_recipe" | grep -qE '^[[:space:]]*run make install DESTDIR="[$]DESTDIR"' \
  || _reasons=" make install does not pass DESTDIR on the command line, so a makefile that assigns it would silently stage nothing."
_verdict ffmpeg-passes-destdir-on-the-command-line "$_reasons"

# 4. And it must NOT gate. FFmpeg is the final target, and the stamp is keyed on
#    the version alone while its configure line changes with --enable-gpl,
#    --tls= and every other selector -- so skipping on it would ignore the flags
#    the operator just changed. Paired with the write above in ONE assertion,
#    because "does not call stamp_check" is true of the merge base too and would
#    otherwise pass there having verified nothing.
#    THREE scopes, because the recipe is the least likely of them: cmd_build
#    owns the line that sources it and already short-circuits above that line
#    for --dry-run, and lib/framework.sh is where run_recipe's own stamp_check
#    already lives. A recipe-only grep would go blind on either.
#
#    Folded through _logical_lines first: grep is line-oriented, and a gate
#    split over a backslash continuation evaded this needle until it was. The
#    needle stops at `)` rather than `(` so that a computed name --
#    stamp_check "$(pkg_name)" ffmpeg -- does not slip past on the paren.
_reasons=""
[ -n "$_stamp" ] || _reasons=" ffmpeg writes no stamp at all."
{ _code_only "$_recipe"; _code_only mediaforge.sh; _lib_code; } \
  | _logical_lines - \
  | grep -qE '(^|[^_[:alnum:]])stamp_check[^)]*ffmpeg' \
  && _reasons="$_reasons it gates on a stamp, so changing --enable-gpl or --tls= would skip the rebuild that change asks for."
_verdict ffmpeg-stamp-is-evidence-not-a-gate "$_reasons"

# 5. The help text must not promise a skip that does not happen for FFmpeg.
#    Read through _code_only and anchored on the printf, so the phrase counts
#    only where it is PRINTED -- a mention in a comment is not help text. The
#    coupling to the exact wording is deliberate and is the cost of pinning
#    prose: reword the help and this assertion asks you to confirm the claim
#    still holds.
_reasons=""
_fn_body mediaforge.sh cmd_reconcile | grep -qE "^[[:space:]]*printf '.*FFmpeg is the exception" \
  || _reasons=" reconcile's help no longer tells the reader that the one stamp nothing gates on is exempt from the skip it promises."
_verdict reconcile-help-names-the-ungated-stamp "$_reasons"

printf 'DONE: ffmpeg-stamped\n'
exit "$_fail"
