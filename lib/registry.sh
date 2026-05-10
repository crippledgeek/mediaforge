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
