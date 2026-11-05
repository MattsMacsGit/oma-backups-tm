#!/usr/bin/env bash
# Pair the backup USB with an always-on Pi (see pi/pi-setup.sh and pi/oma-gate).
#
#   oma-backups remote pair HOST     HOST = Tailscale name, IP, or ssh alias;
#                                    "user@HOST" picks the login for setup
#   oma-backups remote status
#   oma-backups remote forget
set -euo pipefail

OMARCHY_TM_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export OMARCHY_TM_ROOT
# shellcheck source=lib/common.sh
source "$OMARCHY_TM_ROOT/lib/common.sh"
# shellcheck source=lib/remote.sh
source "$OMARCHY_TM_ROOT/lib/remote.sh"

as_user() {
  if [[ -n ${SUDO_USER:-} ]]; then sudo -u "$SUDO_USER" "$@"; else "$@"; fi
}

press_enter() {
  [[ -r /dev/tty ]] && read -r -p "Press Enter to close." _ </dev/tty || true
}

# Guarded like press_enter. Unguarded, these two prompts killed the whole
# command when there was no terminal — after remote.json had already been
# written, so the laptop was left thinking it had a Pi it had never checked.
press_ready() {
  local done=${PI_DONE_TEXT:-This Pi is ready}
  [[ -r /dev/tty ]] && read -r -p "Press Enter once it says \"$done\"." _ </dev/tty || true
}

fail() {
  echo
  gum style --bold --foreground 1 "Pairing failed."
  gum style --foreground 8 "$*"
  press_enter
  exit 1
}

# Pairing over the network, after the Pi has let this laptop in: learn the
# backup disk's ID from the Pi, and have the Pi add this laptop's unlock key
# to it. The disk password proves it; cryptsetup on the Pi checks it. The
# password and the key go through ssh on stdin and are never kept.
pair_network_key() {
  local st=$1 ver uuid pass n tries=0
  ver="$(jq -r '.version // 0' <<<"$st")"
  ((ver >= 14)) ||
    fail "The Pi's gatekeeper (version $ver) is too old to pair over the network. Update it on the Pi: $(pi_update_cmd)"
  [[ $(jq -r '.present' <<<"$st") == true ]] ||
    fail "The backup disk isn't plugged into $host (or it's not powered). Plug it in there, then pair again."
  uuid="$(jq -r '.uuid // ""' <<<"$st")"
  [[ $uuid =~ ^[0-9a-fA-F-]{36}$ ]] || fail "The Pi didn't say which backup disk it has."
  jq --arg u "$uuid" '.luks_uuid = $u' "$OMA_REMOTE_CONF" >"$OMA_REMOTE_CONF.tmp" && mv "$OMA_REMOTE_CONF.tmp" "$OMA_REMOTE_CONF"
  chmod 644 "$OMA_REMOTE_CONF"
  if rgate check-pass <"$OMA_CAPSULE_KEY" >/dev/null 2>&1; then
    step "This laptop's unlock key already opens the backup disk"
    return 0
  fi
  step "Adding this laptop's unlock key to the backup disk on $host"
  while :; do
    gum style --foreground 8 "  Enter the backup disk password (the one you chose when setting it up)."
    pass="$(gum input --password --placeholder "Backup disk password" </dev/tty)" || fail "Pairing stopped."
    [[ -n $pass ]] || continue
    n="$(printf '%s' "$pass" | wc -c)"
    if { printf '%d\n' "$n"; printf '%s' "$pass"; cat "$OMA_CAPSULE_KEY"; } | rgate add-unlock-key >/dev/null 2>>"$OMARCHY_TM_LOG"; then
      break
    fi
    tries=$((tries + 1))
    ((tries < 3)) || { pass=""; fail "That password didn't open the backup disk. Pair again when you have it."; }
    warn "That password didn't open the backup disk. Try again."
  done
  pass=""
  rgate check-pass <"$OMA_CAPSULE_KEY" >/dev/null 2>>"$OMARCHY_TM_LOG" ||
    fail "The Pi added the key, but it doesn't open the disk. Pair again; if it keeps happening, see $OMARCHY_TM_LOG."
}

# Put back what this laptop had before a pairing that didn't finish.
pair_undo() {
  [[ ${PAIR_DONE:-1} == 1 ]] && return 0
  if [[ -n ${PAIR_PREV:-} ]]; then mv -f "$PAIR_PREV" "$OMA_REMOTE_CONF"; else rm -f "$OMA_REMOTE_CONF"; fi
  [[ -n ${PAIR_PREV_KNOWN:-} ]] && mv -f "$PAIR_PREV_KNOWN" "$OMA_REMOTE_KNOWN"
  PAIR_DONE=1
}

# The command for the Pi, on screen and in a file, so closing the window
# doesn't lose it.
show_pi_command() {
  # Where the user can open it (the remote folder holds the private key: root only).
  local f="$OMARCHY_TM_STATE/pi-setup-command.txt"
  mkdir -p "$OMARCHY_TM_STATE" 2>/dev/null || true
  if printf '%s\n' "$1" >"$f" 2>/dev/null; then
    chmod 644 "$f" 2>/dev/null || true
    [[ -n ${SUDO_USER:-} ]] && chown "$SUDO_USER:" "$f" 2>/dev/null || true
  else
    f=""
  fi
  echo; echo "$1"; echo
  [[ -n $f ]] && gum style --foreground 8 "  (Also saved in $f)"
  return 0
}

cmd_pair() {
  local login=${1:-}
  [[ -n $login ]] || die "usage: oma-backups remote pair HOST"
  require_root pair "$login"
  local alias=${login#*@}

  # Backups run as root, which can't see the user's ~/.ssh/config: store the
  # real hostname and port that the user's alias points at.
  local host port cfg
  cfg="$(as_user ssh -G "$alias" 2>/dev/null || true)"
  host="$(awk '$1=="hostname"{print $2; exit}' <<<"$cfg")"
  port="$(awk '$1=="port"{print $2; exit}' <<<"$cfg")"
  host=${host:-$alias} port=${port:-22}
  [[ $host =~ ^[A-Za-z0-9._:-]+$ ]] || fail "\"$alias\" doesn't look like a host name."

  echo
  gum style --bold "Pair the backup disk with $host"
  echo

  # Can it be reached at all? Checked before anything is written, so a name
  # this computer doesn't know yet (a Tailscale name on a fresh install,
  # before Tailscale is back) can simply be typed again.
  step "Looking for $host on the network"
  if ! timeout 8 bash -c ': </dev/tcp/"$1"/"$2"' _ "$host" "$port" 2>/dev/null; then
    fail "Couldn't reach \"$host\" (port $port). Check the Pi is switched on and on the same network.
On a fresh install a Tailscale name doesn't work until Tailscale is set up again: use the Pi's
address on your home network instead, for example 192.168.1.50 (your router's app lists it).
Nothing was changed, so you can try again straight away."
  fi

  # The backup disk plugged into this laptop: its unlock key goes on here,
  # and the disk moves to the Pi afterwards. Not plugged in: pair over the
  # network with a Pi that already has it (a fresh install, or another
  # laptop) -- the Pi adds the key itself, once given the disk password.
  local part uuid="" network=0
  part="$(capsule_luks_partition 2>/dev/null || true)"
  if [[ -n $part && -b $part ]]; then
    uuid="$(luks_uuid_of "$part")"
    [[ -n $uuid ]] || fail "Couldn't read the backup disk's encryption ID."
  else
    network=1
    gum style --foreground 8 "  The backup disk isn't plugged in here, so this pairs over the network"
    gum style --foreground 8 "  with a Pi that already has it."
  fi

  install -d -m 700 "$OMA_REMOTE_DIR"
  if [[ ! -f $OMA_REMOTE_KEY ]]; then
    step "Creating this laptop's backup key"
    ssh-keygen -q -t ed25519 -N "" -C "oma-backups@$(hostname)" -f "$OMA_REMOTE_KEY"
  fi
  if ((network)); then
    create_capsule_key
  else
    ensure_capsule_key "$part" || fail "Couldn't add the unlock key (wrong password?)."
  fi

  # Over the network the disk's ID comes from the Pi a few steps on. Until
  # then keep the one already known for this Pi, so a pairing that stops
  # half way doesn't leave the backups without it.
  ((network)) && [[ -z $uuid ]] &&
    uuid="$(jq -r --arg h "$host" 'select(.host == $h) | .luks_uuid // ""' "$OMA_REMOTE_CONF" 2>/dev/null || true)"
  # Until the Pi has answered, this pairing is only a try: if anything below
  # fails, the Pi this laptop had before (or none) is put back, so the next
  # try starts clean instead of thinking it's already paired.
  PAIR_PREV="" PAIR_PREV_KNOWN="" PAIR_DONE=0
  if [[ -f $OMA_REMOTE_CONF ]]; then PAIR_PREV="$(mktemp)"; cp -p "$OMA_REMOTE_CONF" "$PAIR_PREV"; fi
  if [[ -f $OMA_REMOTE_KNOWN ]]; then PAIR_PREV_KNOWN="$(mktemp)"; cp -p "$OMA_REMOTE_KNOWN" "$PAIR_PREV_KNOWN"; fi
  trap pair_undo EXIT
  jq -n --arg host "$host" --argjson port "$port" --arg uuid "$uuid" --arg laptop "$(hostname)" --arg at "$(ts)" \
    '{host: $host, port: $port, luks_uuid: $uuid, laptop: $laptop, paired_at: $at}' >"$OMA_REMOTE_CONF.tmp"
  chmod 644 "$OMA_REMOTE_CONF.tmp"
  mv "$OMA_REMOTE_CONF.tmp" "$OMA_REMOTE_CONF"
  rm -f "$OMA_REMOTE_KNOWN"

  local setup ask PI_DONE_TEXT="This Pi is ready"
  if ((network)); then
    PI_DONE_TEXT="Done. Gatekeeper version"
    setup="curl -fsSL $OMA_REPO_RAW/pi/pi-setup.sh | sudo bash -s -- --repo $OMA_REPO_RAW --add-key '$(cat "$OMA_REMOTE_KEY.pub")'"
    ask="Let this laptop in on $host now? You'll log in to it as usual and type its sudo password."
    echo
    step "Next, the Pi needs to let this laptop in."
  else
    setup="curl -fsSL $OMA_REPO_RAW/pi/pi-setup.sh | sudo bash -s -- --repo $OMA_REPO_RAW --uuid $uuid --key '$(cat "$OMA_REMOTE_KEY.pub")'"
    ask="Set up $host now? You'll log in to it as usual and type its sudo password."
    echo
    step "Next, the Pi needs a one-time setup."
  fi
  if gum confirm "$ask"; then
    if ! as_user ssh -t "$login" "$setup"; then
      warn "That didn't work. Run this on the Pi yourself instead:"
      show_pi_command "$setup"
      press_ready
    fi
  else
    gum style --foreground 8 "  Run this on the Pi:"
    show_pi_command "$setup"
    press_ready
  fi

  step "Checking the connection"
  remote_load
  local st
  st="$(rgate status 2>&1)" || fail "Couldn't reach the Pi as $OMA_REMOTE_ACCOUNT@$host: $st"
  note_pi_gate "$(jq -r '.version // 0' <<<"$st")"
  ((network)) && pair_network_key "$st"
  # Remember where the Pi lives on the local network, so backups at home can
  # go straight there instead of round through Tailscale.
  remote_refresh_addresses || true
  "$OMARCHY_TM_ROOT/link.sh" --quiet || warn "Couldn't link this laptop; backups will ask for your password. Try: oma-backups link"
  # It's about to be unplugged; pulling it while mounted leaves a dead mount.
  ((network)) || "$OMARCHY_TM_ROOT/mount.sh" umount >/dev/null 2>&1 || true
  PAIR_DONE=1
  rm -f "$OMARCHY_TM_STATE/pi-setup-command.txt"
  echo
  gum style --bold --foreground 2 "● Paired with $host."
  if ((network)); then
    gum style --foreground 8 "  Backups go to the backup disk on the Pi from now on."
  elif [[ $(jq -r .present <<<"$st") == true ]]; then
    gum style --foreground 8 "  The backup disk is already plugged into the Pi. Backups go there from now on."
  else
    gum style --foreground 8 "  The backup disk is locked and safe to unplug. Plug it into the Pi;"
    gum style --foreground 8 "  backups go there from then on. While it's plugged into this laptop,"
    gum style --foreground 8 "  backups keep going straight to it."
  fi
  press_enter
}

cmd_status() {
  if [[ ! -f $OMA_REMOTE_CONF ]]; then
    jq -n -c '{paired: false}'
    return 0
  fi
  # Only root can use the key; everyone else gets the pairing details alone.
  if [[ $EUID -ne 0 ]] || ! remote_configured; then
    jq -c '{paired: true, host, reachable: null}' "$OMA_REMOTE_CONF"
    return 0
  fi
  remote_load
  local st
  if st="$(rgate status 2>/dev/null)"; then
    note_pi_gate "$(jq -r '.version // 0' <<<"$st")"
    jq -c --arg host "$REMOTE_HOST" --arg addr "$REMOTE_ADDR" \
      '{paired: true, host: $host, address: $addr, reachable: true} + .' <<<"$st"
  else
    jq -n -c --arg host "$REMOTE_HOST" '{paired: true, host: $host, reachable: false}'
  fi
}

cmd_forget() {
  require_root forget
  [[ -f $OMA_REMOTE_CONF ]] || { echo "Not paired with a Pi."; return 0; }
  remote_load
  # Not a no-op: on setups from before the key moved, this migrates it out of
  # $OMA_REMOTE_DIR — which the next line deletes. Scheduled backups to the USB
  # still need that key, so unpairing must not take it with it.
  capsule_key_present || true
  rm -rf "$OMA_REMOTE_DIR" "$OMA_REMOTE_CONF"
  echo
  gum style --bold "Unpaired from $REMOTE_HOST."
  gum style --foreground 8 "  To clean up the Pi too, run this on it:"
  echo "  $(pi_update_cmd --uninstall)"
  press_enter
}

sub=${1:-}
shift || true
case "$sub" in
  pair) cmd_pair "$@" ;;
  status) cmd_status ;;
  forget) cmd_forget ;;
  *) die "usage: oma-backups remote pair HOST | status | forget" ;;
esac
