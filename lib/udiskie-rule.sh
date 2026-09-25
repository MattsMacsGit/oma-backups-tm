#!/usr/bin/env bash
# Stops udiskie (Omarchy's USB auto-mounter) asking for the backup disk's
# password the moment it is plugged in.
#
# share/99-oma-backups.rules already marks our partitions "don't open this on
# its own" (UDISKS_AUTO=0), and the file manager honours that. udiskie doesn't:
# it only honours "hide it completely", so it mounted the rescue partition and
# popped up an unlock window for the backups one. This rule makes it honour
# the mark as well. Only our partitions carry it — an ordinary USB stick
# doesn't, and still mounts exactly as before. The disk stays in the file
# manager; OmaBackups unlocks it when it needs it.
#
#   udiskie-rule.sh install   add the rule (and restart udiskie if it changed)
#   udiskie-rule.sh remove    take it out again
#
# The user's own udiskie settings are never overwritten: the rule is added as
# its own marked block, and where that can't be done safely, it says so.
set -euo pipefail

DIR="${XDG_CONFIG_HOME:-$HOME/.config}/udiskie"
CONF="$DIR/config.yml"
BEGIN="# >>> OmaBackups"
END="# <<< OmaBackups"

block() {
  cat <<EOF
$BEGIN
# Don't open or ask to unlock a disk the system marks "not on its own"
# (UDISKS_AUTO=0). OmaBackups marks only its own partitions that way.
# Added by OmaBackups' install.sh; removed by its uninstall.sh.
device_config:
  - should_automount: false
    automount: false
$END
EOF
}

# udiskie reads its settings once, at start. Relaunch it the way it was
# started, so the rule applies now rather than at the next login.
restart_udiskie() {
  local pid args=()
  pid="$(pgrep -x -u "$(id -u)" udiskie | head -1 || true)"
  [[ -n $pid && -r /proc/$pid/cmdline ]] || return 0
  mapfile -d '' args <"/proc/$pid/cmdline"
  # A Python script's command line starts with the interpreter.
  [[ ${args[0]##*/} == python* ]] && args=("${args[@]:1}")
  ((${#args[@]})) || return 0
  kill "$pid" 2>/dev/null || return 0
  # Detached either way: uwsm-app (how Omarchy starts it) runs the program in
  # the foreground, and this script would sit waiting on udiskie for ever.
  if command -v uwsm-app >/dev/null 2>&1; then
    setsid -f uwsm-app -- "${args[@]}" >/dev/null 2>&1 </dev/null
  else
    setsid -f "${args[@]}" >/dev/null 2>&1 </dev/null
  fi
}

install_rule() {
  if [[ -f $CONF ]] && grep -qxF "$BEGIN" "$CONF"; then
    return 0
  fi
  if [[ -f $DIR/config.json ]] || { [[ -f $CONF ]] && grep -q '^device_config:' "$CONF"; }; then
    echo "Note: you have your own udiskie settings, so they were left alone. To stop"
    echo "  it asking for the backup disk's password when it's plugged in, add this"
    echo "  to the device_config list in $CONF:"
    echo "    - should_automount: false"
    echo "      automount: false"
    return 0
  fi
  mkdir -p "$DIR"
  if [[ -s $CONF ]]; then
    { printf '\n'; block; } >>"$CONF"
  else
    block >"$CONF"
  fi
  restart_udiskie
}

remove_rule() {
  [[ -f $CONF ]] && grep -qxF "$BEGIN" "$CONF" || return 0
  sed -i "/^$BEGIN\$/,/^$END\$/d" "$CONF"
  # Nothing of the user's was in it: it was ours alone.
  if ! grep -q '[^[:space:]]' "$CONF"; then
    rm -f "$CONF"
    rmdir "$DIR" 2>/dev/null || true
  fi
  restart_udiskie
}

case "${1:-}" in
  install) install_rule ;;
  remove) remove_rule ;;
  *)
    echo "usage: $0 install|remove" >&2
    exit 2
    ;;
esac
