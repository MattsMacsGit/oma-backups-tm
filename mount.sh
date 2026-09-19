#!/usr/bin/env bash
# Unlock LUKS and mount the backup btrfs at /run/omarchy-backups.
# If the desktop already unlocked it (udisks), bind-mount that here.
set -euo pipefail

OMARCHY_TM_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export OMARCHY_TM_ROOT
# shellcheck source=lib/common.sh
source "$OMARCHY_TM_ROOT/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  oma-backups mount [--disk /dev/sdX] [--dry-run]
  oma-backups umount [--dry-run]
EOF
}

CMD=${1:-mount}
shift || true
DISK=""
ORIG_ARGS=("$CMD" "$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) export OMARCHY_TM_DRY_RUN=1; shift ;;
    --disk) DISK=${2:-}; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

load_config_json
require_supported
require_root "${ORIG_ARGS[@]}"

MNT="$(cfg '.paths.mountpoint')"
LUKS_MAPPER="$(cfg '.layout.luks_mapper')"
SRC_TOP="$(cfg '.paths.source_toplevel')"
TM_LABEL="$(cfg '.layout.tm_label')"

find_labeled_mount() {
  local lab mp
  for lab in "$TM_LABEL" OMARCHY-TM OMARCHY-BACKUPS; do
    mp="$(lsblk -n -o LABEL,MOUNTPOINT | awk -v l="$lab" '$1==l && $2!=""{print $2; exit}')"
    if [[ -n $mp && -d $mp ]]; then
      printf '%s\n' "$mp"
      return 0
    fi
  done
  return 1
}

find_tm_partition() {
  if [[ -n $DISK ]]; then
    if ! is_rescue; then
      refuse_dangerous_disk "$DISK" "mount"
    fi
    local p
    p="$(lsblk -n -p -o PATH,FSTYPE "$DISK" | awk '$2=="crypto_LUKS"{print $1; exit}')"
    [[ -n $p ]] || die "no LUKS partition on $DISK"
    printf '%s\n' "$p"
    return
  fi
  local p
  p="$(capsule_luks_partition || true)"
  if [[ -n $p && -b $p ]]; then
    printf '%s\n' "$p"
    return
  fi
  # Capsule even when detect marks the disk protected (rescue IS the backup USB).
  p="$(printf '%s' "$DETECT_JSON" | jq -r '
    .disks[]
    | select(.capsule.tm_partition != null)
    | .capsule.tm_partition
  ' | head -1)"
  if [[ -n $p && $p != null ]]; then
    printf '%s\n' "$p"
    return
  fi
  p="$(printf '%s' "$DETECT_JSON" | jq -r '
    .disks[]
    | select(.protected != true)
    | .capsule.tm_partition // empty
  ' | head -1)"
  if [[ -n $p ]]; then
    printf '%s\n' "$p"
    return
  fi
  local live_part
  live_part="$(printf '%s' "$DETECT_JSON" | jq -r '.luks.partition // empty')"
  lsblk -n -p -o PATH,FSTYPE | awk -v live="$live_part" '$2=="crypto_LUKS" && $1!=live {print $1; exit}'
}

cmd_mount() {
  if findmnt -n "$MNT" >/dev/null 2>&1; then
    ensure_rw_mount "$MNT"
    log "already mounted: $(findmnt -n -o SOURCE,TARGET,OPTIONS "$MNT")"
    return 0
  fi
  # Do NOT bind-mount the Files/udisks mount — it is often read-only.

  local part
  part="$(find_tm_partition)"
  [[ -n $part && -b $part ]] || die "could not find backup LUKS partition (pass --disk /dev/sdX)"

  local disk
  disk="$(lsblk -n -o PKNAME "$part" | head -1)"
  # Rescue boots from the backup USB; unlocking that same disk's LUKS is required.
  if [[ -n $disk ]] && ! is_rescue; then
    refuse_dangerous_disk "/dev/$disk" "mount"
  fi

  close_stale_mapper omarchy-backups
  close_stale_mapper "$LUKS_MAPPER"

  local mapper=$LUKS_MAPPER
  local already
  already="$(lsblk -nr -o NAME,TYPE "$part" | awk '$2=="crypt"{print $1; exit}')"
  if [[ -n $already ]]; then
    mapper=$already
    log "using already-unlocked mapper $mapper"
  elif [[ ! -e /dev/mapper/$LUKS_MAPPER ]]; then
    if capsule_key_opens "$part"; then
      log "unlocking $part as $LUKS_MAPPER with this laptop's key"
      cryptsetup open --key-file "$OMA_CAPSULE_KEY" "$part" "$LUKS_MAPPER"
    elif [[ ${OMARCHY_TM_UNATTENDED:-0} == 1 ]]; then
      die "the backup disk needs its password and nobody is here to type it. Turn automatic backups off and on again in Settings to add this laptop's key to it."
    else
      log "unlocking $part as $LUKS_MAPPER — enter the backup disk password"
      if [[ -n ${OMARCHY_TM_PASSPHRASE_FD:-} ]]; then
        cryptsetup open --key-file=- "$part" "$LUKS_MAPPER" <&"${OMARCHY_TM_PASSPHRASE_FD}"
      elif [[ -r /dev/tty ]]; then
        cryptsetup open "$part" "$LUKS_MAPPER" < /dev/tty > /dev/tty 2>&1
      else
        cryptsetup open "$part" "$LUKS_MAPPER"
      fi
    fi
  fi
  if [[ -e /dev/mapper/omarchy-backups ]]; then
    mapper=omarchy-backups
  fi
  mount_backup_rw "$MNT" "$mapper"
  chmod 755 "$MNT" 2>/dev/null || true
}

cmd_umount() {
  if findmnt -n "$SRC_TOP" >/dev/null 2>&1; then
    run umount "$SRC_TOP" || true
  fi
  if findmnt -n /run/omarchy-backups-efi >/dev/null 2>&1; then
    run umount /run/omarchy-backups-efi || true
  fi
  if findmnt -n "$MNT" >/dev/null 2>&1; then
    run umount "$MNT"
  fi
  if [[ -e /dev/mapper/$LUKS_MAPPER ]]; then
    run cryptsetup close "$LUKS_MAPPER" || true
  fi
  log "unmounted"
}

case "$CMD" in
  mount) cmd_mount ;;
  umount) cmd_umount ;;
  *) usage >&2; exit 1 ;;
esac
