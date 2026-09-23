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
  [[ -r /dev/tty ]] && read -r -p "Press Enter once it says \"This Pi is ready\"." _ </dev/tty || true
}

fail() {
  echo
  gum style --bold --foreground 1 "Pairing failed."
  gum style --foreground 8 "$*"
  press_enter
  exit 1
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

  local part uuid
  part="$(capsule_luks_partition 2>/dev/null || true)"
  [[ -n $part && -b $part ]] ||
    fail "Plug the backup disk into this laptop first. Pairing adds this laptop's unlock key to it; it moves to the Pi afterwards."
  uuid="$(luks_uuid_of "$part")"
  [[ -n $uuid ]] || fail "Couldn't read the backup disk's encryption ID."

  install -d -m 700 "$OMA_REMOTE_DIR"
  if [[ ! -f $OMA_REMOTE_KEY ]]; then
    step "Creating this laptop's backup key"
    ssh-keygen -q -t ed25519 -N "" -C "oma-backups@$(hostname)" -f "$OMA_REMOTE_KEY"
  fi
  ensure_capsule_key "$part" || fail "Couldn't add the unlock key (wrong password?)."

  jq -n --arg host "$host" --argjson port "$port" --arg uuid "$uuid" --arg laptop "$(hostname)" --arg at "$(ts)" \
    '{host: $host, port: $port, luks_uuid: $uuid, laptop: $laptop, paired_at: $at}' >"$OMA_REMOTE_CONF.tmp"
  chmod 644 "$OMA_REMOTE_CONF.tmp"
  mv "$OMA_REMOTE_CONF.tmp" "$OMA_REMOTE_CONF"
  rm -f "$OMA_REMOTE_KNOWN"

  local setup
  setup="curl -fsSL $OMA_REPO_RAW/pi/pi-setup.sh | sudo bash -s -- --uuid $uuid --key '$(cat "$OMA_REMOTE_KEY.pub")'"
  echo
  step "Next, the Pi needs a one-time setup."
  if gum confirm "Set up $host now? You'll log in to it as usual and type its sudo password."; then
    if ! as_user ssh -t "$login" "$setup"; then
      warn "That didn't work. Run this on the Pi yourself instead:"
      echo; echo "$setup"; echo
      press_ready
    fi
  else
    gum style --foreground 8 "  Run this on the Pi:"
    echo; echo "$setup"; echo
    press_ready
  fi

  step "Checking the connection"
  remote_load
  local st
  st="$(rgate status 2>&1)" || fail "Couldn't reach the Pi as $OMA_REMOTE_ACCOUNT@$host: $st"
  note_pi_gate "$(jq -r '.version // 0' <<<"$st")"
  # Remember where the Pi lives on the local network, so backups at home can
  # go straight there instead of round through Tailscale.
  remote_refresh_addresses || true
  "$OMARCHY_TM_ROOT/link.sh" --quiet || warn "Couldn't link this laptop; backups will ask for your password. Try: oma-backups link"
  # It's about to be unplugged; pulling it while mounted leaves a dead mount.
  "$OMARCHY_TM_ROOT/mount.sh" umount >/dev/null 2>&1 || true
  echo
  gum style --bold --foreground 2 "● Paired with $host."
  if [[ $(jq -r .present <<<"$st") == true ]]; then
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
