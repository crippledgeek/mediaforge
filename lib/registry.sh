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

# recipe_key
# The registry identity of the recipe currently loaded: its filename without
# the .sh suffix. Prints nothing and returns 1 when there is no loaded recipe
# to name, so a caller can tell "no key" from "the empty key" -- an empty key
# is not a recipe, and treating one as a name matches things it should not.
#
# THIS, NOT PKG_NAME, IS WHAT EVERY CLI-FACING RECIPE NAME MEANS. The registry
# above is built from _order.conf paths, so --disable=/--enable=/--skip-checksum=
# are all validated against filenames, and lib/resolve.sh writes its mutex
# exclusions into DISABLE_PKGS by filename too. PKG_NAME is a DISPLAY name and
# three recipes deliberately diverge -- vapoursynth/VapourSynth,
# freetype2/FreeType2, freetype2-harfbuzz/FreeType2-hb -- so matching a user's
# name against PKG_NAME accepted `--disable=vapoursynth`, warned nothing, and
# did nothing. Renaming those three the other way is the riskier direction:
# PKG_NAME reaches log output and the stamp filenames a built workspace
# already carries.
#
# Derived from PKG_HASH_FILE, which load_recipe (lib/framework.sh) sets from
# the recipe's own path for every recipe, recipes/ffmpeg.sh sets explicitly,
# and a nested fetch() inherits unchanged -- so it is always present and always
# agrees with the registry, which PKG_NAME is not.
recipe_key() {
  _rk="${PKG_HASH_FILE:-}"
  [ -n "$_rk" ] || return 1
  _rk="${_rk##*/}"
  _rk="${_rk%.hash}"
  [ -n "$_rk" ] || return 1
  printf '%s' "$_rk"
}

# Return 0 if $1 is a known recipe name.
is_known_pkg() {
  registry_init
  for _r in $_REGISTRY_NAMES; do
    [ "$_r" = "$1" ] && return 0
  done
  return 1
}

# validate_pkg_names LIST [EXTRA]
# Die on the first name in LIST that is neither a recipe in the registry nor
# one of the whitespace-separated names in EXTRA, naming near matches.
#
# One implementation for all three call sites (cmd_build's --disable=/--enable=,
# cmd_build's --skip-checksum=, cmd_makesum's package filter). Those three were
# served by TWO byte-identical copies of this loop, not three -- cmd_build's
# single loop covered both of its own flags -- and a copy is where the
# suggestion text and the die wording drift apart.
validate_pkg_names() {
  _vpn_extra="${2:-}"
  registry_init
  for _vpn in $1; do
    is_known_pkg "$_vpn" && continue
    for _vpn_e in $_vpn_extra; do
      [ "$_vpn_e" = "$_vpn" ] && continue 2
    done
    _vpn_hint=$(suggest_pkg "$_vpn")
    if [ -n "$_vpn_hint" ]; then
      die "Unknown package: $_vpn. Did you mean: $_vpn_hint ?"
    else
      die "Unknown package: $_vpn. Run '$PROGNAME build --list-pkgs' to see all."
    fi
  done
}

# Print substring-matching recipe names, comma-separated, max 3.
suggest_pkg() {
  registry_init
  # SC2086: intentional word-split. $_REGISTRY_NAMES is a whitespace-separated
  # name list used as a POSIX faux-array; printf '%s\n' splits it into rows.
  # shellcheck disable=SC2086
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
