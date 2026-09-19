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
  local host port
  host="$(as_user ssh -G "$alias" 2>/dev/null | awk '$1=="hostname"{print $2; exit}')"
  port="$(as_user ssh -G "$alias" 2>/dev/null | awk '$1=="port"{print $2; exit}')"
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
  if [[ ! -f $OMA_REMOTE_LUKS_KEY ]]; then
    head -c 4096 /dev/urandom >"$OMA_REMOTE_LUKS_KEY"
    chmod 600 "$OMA_REMOTE_LUKS_KEY"
  fi
  if ! cryptsetup open --test-passphrase --key-file "$OMA_REMOTE_LUKS_KEY" "$part" 2>/dev/null; then
    step "Adding this laptop's unlock key to the backup disk"
    gum style --foreground 8 "  Enter the backup disk password (the one you chose when setting it up)."
    # The key is 4 KB of random data, so it doesn't need argon2's slow,
    # memory-hungry derivation, which would make every unlock on a Pi slow.
    cryptsetup luksAddKey --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
      "$part" "$OMA_REMOTE_LUKS_KEY" </dev/tty ||
      fail "Couldn't add the unlock key (wrong password?)."
  fi

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
      read -r -p "Press Enter once it says \"This Pi is ready\"." _ </dev/tty
    fi
  else
    gum style --foreground 8 "  Run this on the Pi:"
    echo; echo "$setup"; echo
    read -r -p "Press Enter once it says \"This Pi is ready\"." _ </dev/tty
  fi

  step "Checking the connection"
  remote_load
  local st
  st="$(rgate status 2>&1)" || fail "Couldn't reach the Pi as $OMA_REMOTE_ACCOUNT@$host: $st"
  echo
  gum style --bold --foreground 2 "● Paired with $host."
  if [[ $(jq -r .present <<<"$st") == true ]]; then
    gum style --foreground 8 "  The backup disk is already plugged into the Pi. Backups go there from now on."
  else
    gum style --foreground 8 "  Unplug the backup disk and plug it into the Pi. Backups go there from then on."
    gum style --foreground 8 "  While it's plugged into this laptop, backups keep going straight to it."
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
    jq -c --arg host "$REMOTE_HOST" '{paired: true, host: $host, reachable: true} + .' <<<"$st"
  else
    jq -n -c --arg host "$REMOTE_HOST" '{paired: true, host: $host, reachable: false}'
  fi
}

cmd_forget() {
  require_root forget
  remote_configured || { echo "Not paired with a Pi."; return 0; }
  remote_load
  local part
  part="$(capsule_luks_partition 2>/dev/null || true)"
  if [[ -n $part && -b $part ]]; then
    cryptsetup luksRemoveKey "$part" "$OMA_REMOTE_LUKS_KEY" 2>/dev/null &&
      step "Removed this laptop's unlock key from the backup disk"
  else
    warn "The backup disk isn't plugged in here, so its unlock-key slot for this laptop stays (harmless once this laptop's copy is deleted)."
  fi
  rm -rf "$OMA_REMOTE_DIR" "$OMA_REMOTE_CONF"
  echo "Forgot $REMOTE_HOST. To clean up the Pi too, run there:"
  echo "  curl -fsSL $OMA_REPO_RAW/pi/pi-setup.sh | sudo bash -s -- --uninstall"
}

sub=${1:-}
shift || true
case "$sub" in
  pair) cmd_pair "$@" ;;
  status) cmd_status ;;
  forget) cmd_forget ;;
  *) die "usage: oma-backups remote pair HOST | status | forget" ;;
esac
