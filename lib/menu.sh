#!/bin/sh
# Interactive menu primitives. Use whiptail when present; fall back to a pure
# POSIX read-loop otherwise. Both primitives echo the chosen tag(s) on stdout
# and exit 0 on success, 1 on cancel.

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
    if [ "$_reply" -lt 1 ] || [ "$_reply" -gt "$_i" ]; then
      printf 'Out of range.\n' >&2
      continue
    fi
    _j=0
    for _t in $_tags; do
      _j=$((_j + 1))
      if [ "$_j" = "$_reply" ]; then
        printf '%s\n' "$_t"
        return 0
      fi
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
    # Suppress unused-var warning — _desc reserved for future expansion
    : "$_desc"
  done
  _menu_render_checklist() {
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
    _menu_render_checklist
    printf 'Toggle [1-%d], or empty line to confirm: ' "$_i" >&2
    read -r _reply || return 1
    [ -z "$_reply" ] && break
    case "$_reply" in
      ''|*[!0-9]*) printf 'Invalid input.\n' >&2; continue ;;
    esac
    if [ "$_reply" -lt 1 ] || [ "$_reply" -gt "$_i" ]; then
      printf 'Out of range.\n' >&2
      continue
    fi
    # Toggle position $_reply in $_states
    _new=""
    _j=0
    for _s in $_states; do
      _j=$((_j + 1))
      if [ "$_j" = "$_reply" ]; then
        if [ "$_s" = "on" ]; then
          _new="$_new off"
        else
          _new="$_new on"
        fi
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
