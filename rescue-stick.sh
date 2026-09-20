#!/usr/bin/env bash
# Make a network rescue stick: a USB that boots the same Omarchy rescue +
# restore wizard as the backup disk, but restores from the paired Pi.
#
# GPT:
#   1. 512M FAT32  OMANETBOOT    Limine + Omarchy ISO kernel
#   2. rest ext4   OmaNetRescue  Omarchy ISO + restore scripts (+ Tailscale)
#   3. 64M LUKS2   OmaNetKeys    the Pi's address + key and this stick's SSH key
#
# The keys partition uses the backup disk's password, so one password at boot
# opens the stick and (sent to the Pi) the backup disk. The stick's key can
# only use the gatekeeper's read-only rescue mode, and making a new stick
# switches the old one's key off.
set -euo pipefail

OMARCHY_TM_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export OMARCHY_TM_ROOT
# shellcheck source=lib/common.sh
source "$OMARCHY_TM_ROOT/lib/common.sh"
# shellcheck source=lib/remote.sh
source "$OMARCHY_TM_ROOT/lib/remote.sh"
# shellcheck source=lib/install-rescue.sh
source "$OMARCHY_TM_ROOT/lib/install-rescue.sh"

# The panel's progress bar is for backups; this has its own narration.
progress() { :; }

EFI_LABEL=OMANETBOOT
LIVE_LABEL=OmaNetRescue
KEYS_LABEL=OmaNetKeys
KEYS_MAPPER=oma-netkeys-new
HOST_ALIAS=oma-pi
# Track the current stable gatekeeper rather than the oldest that would work:
# one number for the README and the code to agree on. `pi-setup.sh --update`
# brings an older Pi up to it without disturbing the pairing.
MIN_GATE=7

usage() {
  cat <<'EOF'
Usage: oma-backups rescue-stick /dev/sdX [--iso PATH]

Erases the USB and makes it a network rescue stick for the paired Pi.
EOF
}

DISK=""
ORIG_ARGS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --iso)
      [[ -n ${2:-} ]] || die "--iso needs a path"
      export OMARCHY_TM_ISO="$2"
      shift 2
      ;;
    --*) die "unknown flag: $1" ;;
    *)
      if [[ -z $DISK ]]; then DISK=$1; shift; else die "unexpected argument: $1"; fi
      ;;
  esac
done
[[ -n $DISK ]] || { usage >&2; exit 1; }

PAUSED=0 WORK=""
press_enter() {
  PAUSED=1
  [[ -r /dev/tty ]] && read -r -p "Press Enter to close." _ </dev/tty || true
}

cleanup() {
  [[ -n $WORK ]] || return 0
  local m
  for m in "$WORK/keys" "$WORK/efi" "$WORK/live"; do
    mountpoint -q "$m" 2>/dev/null && umount "$m" 2>/dev/null
    rmdir "$m" 2>/dev/null
  done
  [[ -e /dev/mapper/$KEYS_MAPPER ]] && cryptsetup close "$KEYS_MAPPER" 2>/dev/null
  rmdir "$WORK" 2>/dev/null
  return 0
}

# Errors from the shared checks (die) end the script too; keep the terminal
# open so they can be read.
on_exit() {
  local rc=$?
  cleanup
  ((rc == 0 || PAUSED)) || press_enter
}
trap on_exit EXIT

fail() {
  unset PASS || true
  echo
  gum style --bold --foreground 1 "Couldn't make the rescue stick."
  gum style --foreground 8 "$*"
  press_enter
  exit 1
}

load_config_json
require_supported
require_root "${ORIG_ARGS[@]}"
ensure_deps wipefs cryptsetup mkfs.fat mkfs.ext4 sgdisk jq gum bsdtar unsquashfs mksquashfs rsync

echo
gum style --bold "Make a network rescue stick"
echo

# —— Checks, before anything is erased ——
[[ -f $OMA_REMOTE_CONF && -f $OMA_REMOTE_KEY ]] || fail "Pair this laptop with a Pi first (Settings → Back up to a Pi)."
remote_load

refuse_dangerous_disk "$DISK" "erase"
require_usb_or_allow "$DISK" "erase"
disk_real="$(real_dev "$DISK")"
is_capsule="$(printf '%s' "$DETECT_JSON" | jq -r --arg p "$disk_real" --arg n "$DISK" \
  '.disks[] | select(.path == $p or .path == $n) | .capsule // empty | tostring')"
[[ -z $is_capsule ]] || fail "$DISK is a backup disk. Use a different USB for the rescue stick."

# Plain call, not a command substitution: the ISO-verified cache it sets would
# not survive a subshell, and it is checked again when the image is built.
ensure_omarchy_iso >/dev/null
iso="$OMARCHY_ISO_FOUND"
iso_bytes=$(stat -c %s "$iso")
disk_bytes=$(lsblk -n -b -d -o SIZE "$DISK")
# ISO + 10% for the filesystem and the repacked image, + the two small partitions.
need=$((iso_bytes * 11 / 10 + 600 * 1024 * 1024))
((disk_bytes >= need)) ||
  fail "$DISK is too small: it needs about $((need / 1000000000 + 1)) GB (the Omarchy ISO alone is $((iso_bytes / 1000000000)) GB)."

step "Checking the Pi"
st="$(rgate status 2>&1)" || fail "Can't reach $REMOTE_HOST. Is it switched on and on the network (or Tailscale)?"
gate_ver="$(rgate version 2>/dev/null || echo 0)"
((gate_ver >= MIN_GATE)) || fail "The Pi's OmaBackups is too old for rescue sticks. Update it by running this on the Pi:

  curl -fsSL $OMA_REPO_RAW/pi/pi-setup.sh | sudo bash -s -- --update"

# The password is checked against the backup disk wherever it is right now.
local_part="$(capsule_luks_partition 2>/dev/null || true)"
if [[ -z $local_part && $(jq -r .present <<<"$st") != true ]]; then
  fail "The backup disk isn't plugged into $REMOTE_HOST (or this laptop). Plug it in and try again."
fi

pi_known="$(ssh-keygen -F "$REMOTE_HOST" -f "$OMA_REMOTE_KNOWN" 2>/dev/null | grep -v '^#' || true)"
[[ -n $pi_known ]] ||
  pi_known="$(ssh-keygen -F "[$REMOTE_HOST]:$(jq -r '.port // 22' "$OMA_REMOTE_CONF")" -f "$OMA_REMOTE_KNOWN" 2>/dev/null | grep -v '^#' || true)"
[[ -n $pi_known ]] || fail "This laptop hasn't saved $REMOTE_HOST's fingerprint yet. Run a backup to the Pi once, then try again."
addresses="$(rgate addresses 2>/dev/null || echo '[]')"
jq -e 'type == "array"' <<<"$addresses" >/dev/null || addresses='[]'

ts_bin="" tsd_bin=""
if command -v tailscale >/dev/null && command -v tailscaled >/dev/null; then
  ts_bin="$(command -v tailscale)" tsd_bin="$(command -v tailscaled)"
fi

P1="$(partition_path "$DISK" 1)"
P2="$(partition_path "$DISK" 2)"
P3="$(partition_path "$DISK" 3)"

gum style --foreground 8 "  $DISK  $(lsblk -n -d -o SIZE,MODEL "$DISK" 2>/dev/null || true)"
gum style --foreground 8 "  Restores from: $REMOTE_HOST"
gum style --foreground 8 "  Omarchy ISO:   $(basename "$iso")"
if [[ -n $ts_bin ]]; then
  gum style --foreground 8 "  Tailscale:     included (log in from your phone when it boots)"
else
  gum style --foreground 8 "  Tailscale:     not installed here, so the stick only finds the Pi on your home network"
fi
echo
gum style --bold --foreground 1 "This erases $DISK."
gum style --foreground 8 "Making a new stick switches off any older rescue stick for this Pi."
echo
confirm "Erase $DISK and make it a network rescue stick?"

# —— The backup disk's password (checked, never stored) ——
echo
gum style --foreground 8 "Enter the backup disk's password. At boot, the stick asks for it to open"
gum style --foreground 8 "itself and the backup disk on the Pi."
PASS=""
for _ in 1 2 3; do
  PASS=$(gum input --password --header "Backup disk password") || fail "Cancelled. Nothing was erased."
  [[ -n $PASS ]] || continue
  if [[ -n $local_part ]]; then
    printf '%s' "$PASS" | cryptsetup open --test-passphrase --key-file=- "$local_part" 2>/dev/null && break
  else
    printf '%s' "$PASS" | rgate check-pass 2>/dev/null && break
  fi
  gum style --foreground 3 "  That password doesn't open the backup disk."
  PASS=""
done
[[ -n $PASS ]] || fail "Wrong password three times. Nothing was erased."

# —— Build it ——
WORK="$(mktemp -d /run/oma-stick.XXXXXX)"
EFI_MNT=$WORK/efi LIVE_MNT=$WORK/live KEYS_MNT=$WORK/keys
trap 'fail "Something went wrong partway through. Details: $OMARCHY_TM_LOG"' ERR

echo
step "Erasing $DISK"
close_crypt_on_disk "$DISK"
while read -r mp; do
  [[ -n $mp ]] && umount "$mp" 2>/dev/null || true
done < <(lsblk -n -o MOUNTPOINTS "$DISK" | awk 'NF')
run_quiet wipefs -a "$DISK"
run_quiet sgdisk --zap-all "$DISK"
run_quiet sgdisk \
  -n 1:0:+512M -t 1:ef00 -c 1:"$EFI_LABEL" \
  -n 2:0:-64M -t 2:8300 -c 2:"$LIVE_LABEL" \
  -n 3:0:0 -t 3:8309 -c 3:"$KEYS_LABEL" \
  "$DISK"
run_quiet partprobe "$DISK" || true
udevadm settle || true
sleep 1
[[ -b $P1 && -b $P2 && -b $P3 ]] || fail "The new partitions didn't appear. Unplug the USB, plug it back in, and try again."
run_quiet mkfs.fat -F32 -n "$EFI_LABEL" "$P1"
run_quiet mkfs.ext4 -F -L "$LIVE_LABEL" "$P2"

step "Locking the stick's keys with the backup disk's password"
printf '%s' "$PASS" | cryptsetup luksFormat --type luks2 --batch-mode --label "$KEYS_LABEL" --key-file=- "$P3" >>"$OMARCHY_TM_LOG" 2>&1
printf '%s' "$PASS" | cryptsetup open --key-file=- "$P3" "$KEYS_MAPPER"
unset PASS
run_quiet mkfs.ext4 -F -q -L oma-netkeys "/dev/mapper/$KEYS_MAPPER"
mkdir -p "$KEYS_MNT" "$EFI_MNT" "$LIVE_MNT"
mount "/dev/mapper/$KEYS_MAPPER" "$KEYS_MNT"
chmod 700 "$KEYS_MNT"
(umask 077
  ssh-keygen -q -t ed25519 -N "" -C oma-rescue -f "$KEYS_MNT/id_ed25519"
  # The stick reaches the Pi by whichever address answers, so its key is
  # pinned under one name (see remote_load's host_key_alias).
  awk -v a="$HOST_ALIAS" '{ $1 = a; print }' <<<"$pi_known" >"$KEYS_MNT/known_hosts"
  jq -n --arg host "$REMOTE_HOST" --argjson port "$(jq '.port // 22' "$OMA_REMOTE_CONF")" \
    --argjson addrs "$addresses" --arg laptop "$(hostname)" --arg at "$(ts)" --arg alias "$HOST_ALIAS" \
    '{host: $host, port: $port, addresses: $addrs, host_key_alias: $alias, laptop: $laptop, created_at: $at}' \
    >"$KEYS_MNT/rescue.json")
STICK_PUB="$(cut -d' ' -f1,2 "$KEYS_MNT/id_ed25519.pub")"
umount "$KEYS_MNT"
cryptsetup close "$KEYS_MAPPER"

mount "$P2" "$LIVE_MNT"
mount "$P1" "$EFI_MNT"
install_archiso_rescue "$LIVE_MNT" "$EFI_MNT"
install_rescue_limine "$DISK" "$EFI_MNT" "$LIVE_LABEL" "Network Rescue"
# Tells the wizard to restore from the Pi. Nothing secret on this partition.
echo '{"network": true}' >"$LIVE_MNT/oma-backups/network-rescue.json"
if [[ -n $ts_bin ]]; then
  step "Adding Tailscale"
  install -D -m 755 "$ts_bin" "$LIVE_MNT/oma-extra/usr/bin/tailscale"
  install -D -m 755 "$tsd_bin" "$LIVE_MNT/oma-extra/usr/bin/tailscaled"
fi
step "Writing everything to the stick (can take a few minutes)"
sync
umount "$EFI_MNT" "$LIVE_MNT"

step "Letting the stick in on $REMOTE_HOST (read-only)"
rgate set-rescue-key <<<"$STICK_PUB" 2>>"$OMARCHY_TM_LOG" ||
  fail "The stick is written, but $REMOTE_HOST didn't accept its key. Try again when the Pi is reachable."
trap - ERR

echo
gum style --bold --foreground 2 "● Network rescue stick ready."
gum style --foreground 8 "  Keep it somewhere safe, away from this laptop. To restore, boot any"
gum style --foreground 8 "  computer from it and type the backup disk's password. It finds"
gum style --foreground 8 "  $REMOTE_HOST on your home network, or over Tailscale from anywhere."
gum style --foreground 8 "  Changed the backup disk's password? Make a new stick."
press_enter
