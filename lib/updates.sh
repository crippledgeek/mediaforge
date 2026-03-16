#!/bin/sh
# GitHub-based dependency update checker

# Strip common tag prefixes to get bare version string
# e.g., "v1.2.3" -> "1.2.3", "n8.0.1" -> "8.0.1", "release-1.0" -> "1.0"
_strip_tag_prefix() {
  printf '%s\n' "$1" | sed -e 's/^v//' -e 's/^n//' -e 's/^release-//' -e 's/^R//'
}

# Query GitHub API for the latest release tag of a repo
# Returns stripped version string, or empty string on failure
_github_latest() {
  _repo="$1"
  _auth_header=""
  if [ -n "$GITHUB_TOKEN" ]; then
    _auth_header="Authorization: Bearer $GITHUB_TOKEN"
  fi

  _response=$(curl -sf -H "Accept: application/vnd.github.v3+json" \
    ${_auth_header:+-H "$_auth_header"} \
    "https://api.github.com/repos/${_repo}/releases/latest" 2>/dev/null)

  if [ -z "$_response" ]; then
    # Try tags endpoint as fallback (some repos don't use releases)
    _response=$(curl -sf -H "Accept: application/vnd.github.v3+json" \
      ${_auth_header:+-H "$_auth_header"} \
      "https://api.github.com/repos/${_repo}/tags?per_page=1" 2>/dev/null)
    if [ -n "$_response" ]; then
      _tag=$(printf '%s\n' "$_response" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
      _strip_tag_prefix "$_tag"
      return
    fi
    return 1
  fi

  _tag=$(printf '%s\n' "$_response" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  if [ -n "$_tag" ]; then
    _strip_tag_prefix "$_tag"
  fi
}

# Main update check — iterates _order.conf, sources each recipe, queries GitHub
check_updates() {
  _profile_label="no profile — using recipe defaults"
  if [ -n "$PROFILE_NAME" ]; then
    _profile_label="profile: ffmpeg-${PROFILE_NAME}"
  fi

  printf 'Version Check (%s)\n' "$_profile_label"
  printf '%-20s %-15s %-15s %s\n' "Package" "Current" "Latest" "Status"
  printf '%-20s %-15s %-15s %s\n' "-------" "-------" "------" "------"

  _updates_found=0

  while IFS= read -r _recipe || [ -n "$_recipe" ]; do
    case "$_recipe" in
      ""|\#*) continue ;;
    esac

    _recipe_path="$SCRIPT_DIR/$_recipe"
    [ -f "$_recipe_path" ] || continue

    # Reset and source recipe to get its variables
    reset_recipe
    . "$_recipe_path"

    if [ -z "$PKG_NAME" ] || [ -z "$PKG_VERSION" ]; then
      continue
    fi

    if [ -z "$PKG_GITHUB_REPO" ]; then
      printf '%-20s %-15s %-15s %s\n' "$PKG_NAME" "$PKG_VERSION" "N/A" "(not on GitHub)"
      continue
    fi

    _latest=$(_github_latest "$PKG_GITHUB_REPO")
    if [ -z "$_latest" ]; then
      printf '%-20s %-15s %-15s %s\n' "$PKG_NAME" "$PKG_VERSION" "error" "(API query failed)"
      continue
    fi

    _current=$(_strip_tag_prefix "$PKG_VERSION")
    if [ "$_current" = "$_latest" ]; then
      printf '%-20s %-15s %-15s %s\n' "$PKG_NAME" "$_current" "$_latest" "up to date"
    else
      printf '%-20s %-15s %-15s %s\n' "$PKG_NAME" "$_current" "$_latest" "UPDATE AVAILABLE"
      _updates_found=$((_updates_found + 1))
    fi
  done < "$SCRIPT_DIR/recipes/_order.conf"

  printf '\n'
  if [ "$_updates_found" -gt 0 ]; then
    printf '%d update(s) available.\n' "$_updates_found"
  else
    printf 'All packages are up to date.\n'
  fi
}
