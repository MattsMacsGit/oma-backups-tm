#!/usr/bin/env bash
# GPT Time Capsule: EFI + live rescue OS + LUKS2→btrfs backups.
set -euo pipefail

OMARCHY_TM_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export OMARCHY_TM_ROOT
# shellcheck source=lib/common.sh
source "$OMARCHY_TM_ROOT/lib/common.sh"
# shellcheck source=lib/install-rescue.sh
source "$OMARCHY_TM_ROOT/lib/install-rescue.sh"

usage() {
  cat <<'EOF'
Usage: oma-backups format-disk /dev/sdX [--dry-run] [--yes] [--force] [--skip-live]

GPT:
  1. ~1G FAT32   OMARCHY-EFI    UEFI ESP (Limine + Arch ISO kernel)
  2. ~16G ext4   OMARCHY-LIVE   official Arch ISO files + restore scripts
  3. rest LUKS2→btrfs OMARCHY-TM  backups

Rescue is the official Arch installer environment (not Omarchy, not a
pacstrap of this machine). Firmware boots Limine → Arch live → restore wizard.

--skip-live   partition + LUKS + btrfs only (no ISO/Limine)
EOF
}

DISK=""
SKIP_LIVE=0
ORIG_ARGS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) export OMARCHY_TM_DRY_RUN=1; shift ;;
    --yes) export OMARCHY_TM_YES=1; shift ;;
    --force) export OMARCHY_TM_FORCE=1; shift ;;
    --allow-internal) export OMARCHY_TM_ALLOW_INTERNAL=1; shift ;;
    --skip-live) SKIP_LIVE=1; shift ;;
    --iso|--extract-iso)
      log "note: --iso is ignored; rescue is a pacstrap live OS (ISO squashfs > FAT32 limit)"
      shift
      [[ ${1:-} == --* || -z ${1:-} ]] || shift
      ;;
    --*) die "unknown flag: $1" ;;
    *)
      if [[ -z $DISK ]]; then DISK=$1; shift; else die "unexpected argument: $1"; fi
      ;;
  esac
done

[[ -n $DISK ]] || { usage >&2; exit 1; }

load_config_json
require_supported
require_root "${ORIG_ARGS[@]}"

ensure_deps wipefs cryptsetup mkfs.fat mkfs.btrfs lsblk jq
if ! is_dry_run; then
  ensure_deps mkfs.ext4 sgdisk
  [[ $SKIP_LIVE != 1 ]] && ensure_deps curl unsquashfs mksquashfs
fi

EFI_SIZE="$(cfg '.layout.efi_size')"
EFI_LABEL="$(cfg '.layout.efi_label')"
LIVE_SIZE="$(cfg '.layout.live_size')"
LIVE_LABEL="$(cfg '.layout.live_label')"
TM_LABEL="$(cfg '.layout.tm_label')"
LUKS_MAPPER="$(cfg '.layout.luks_mapper')"
MNT="$(cfg '.paths.mountpoint')"

refuse_dangerous_disk "$DISK" "format"
require_usb_or_allow "$DISK" "format"

existing="$(printf '%s' "$DETECT_JSON" | jq -r --arg p "$(real_dev "$DISK")" --arg n "$DISK" '
  .disks[] | select(.path == $p or .path == $n) | .capsule // empty | tostring
')"
if [[ -n $existing && $existing != null && $existing != "" && ${OMARCHY_TM_FORCE:-0} != 1 ]]; then
  die "$DISK already looks like a backup disk. Pass --force to wipe and recreate."
fi

OLD_LUKS_UUID=""
if ! is_dry_run; then
  close_crypt_on_disk "$DISK"
  P3_OLD="$(partition_path "$DISK" 3)"
  if [[ -b $P3_OLD ]]; then
    OLD_LUKS_UUID="$(luks_uuid_of "$P3_OLD")"
    [[ -n $OLD_LUKS_UUID ]] && log "existing LUKS UUID $OLD_LUKS_UUID — will refuse to continue if this does not change"
  fi
fi

P1="$(partition_path "$DISK" 1)"
P2="$(partition_path "$DISK" 2)"
P3="$(partition_path "$DISK" 3)"

# shellcheck source=lib/install-rescue.sh
source "$OMARCHY_TM_ROOT/lib/install-rescue.sh"

cat <<EOF
== format-disk ==
Target:     $DISK
            $(lsblk -n -d -o SIZE,MODEL,TRAN "$DISK" 2>/dev/null || true)
Layout:     GPT (bootable rescue)
  $P1   ${EFI_SIZE} FAT32  ${EFI_LABEL}   (ESP)
  $P2   ${LIVE_SIZE} ext4  ${LIVE_LABEL}  (rescue OS)
  $P3   rest  LUKS2→btrfs ${TM_LABEL}
Live OS:    $([[ $SKIP_LIVE == 1 ]] && echo skipped || echo "official Arch ISO + restore wizard")
Dry-run:    ${OMARCHY_TM_DRY_RUN:-0}

THIS ERASES $DISK.
EOF

ask_new_luks_pass() {
  local tty=/dev/tty
  [[ -r $tty && -w $tty ]] || die "need a real terminal to set the disk encryption password"
  {
    echo
    echo "============================================================"
    echo " NEW encryption password for this backup disk"
    echo " (not your login password — you will need this to restore)"
    echo "============================================================"
  } >"$tty"
  local p1="" p2=""
  read -r -s -p "Encryption password: " p1 <"$tty" || true
  echo >"$tty"
  read -r -s -p "Confirm password:    " p2 <"$tty" || true
  echo >"$tty"
  [[ -n $p1 && $p1 == "$p2" ]] || die "passwords empty or did not match — disk was NOT erased"
  LUKS_PASS="$p1"
  p1="" p2=""
}

if ! is_dry_run; then
  confirm "Wipe $DISK and write a bootable Time Capsule?"
  ask_new_luks_pass
fi

if is_dry_run; then
  cat <<EOF
[dry-run] sgdisk --zap-all $DISK
[dry-run] sgdisk -n 1:0:+${EFI_SIZE} -t 1:ef00 -c 1:${EFI_LABEL} \\
                 -n 2:0:+${LIVE_SIZE} -t 2:8300 -c 2:${LIVE_LABEL} \\
                 -n 3:0:0 -t 3:8309 -c 3:${TM_LABEL} $DISK
[dry-run] mkfs.fat -F32 -n ${EFI_LABEL} $P1
[dry-run] mkfs.ext4 -F -L ${LIVE_LABEL} $P2
[dry-run] cryptsetup luksFormat --type luks2 --batch-mode $P3
[dry-run] cryptsetup open $P3 ${LUKS_MAPPER}
[dry-run] mkfs.btrfs -L ${TM_LABEL} /dev/mapper/${LUKS_MAPPER}
[dry-run] extract official Arch ISO onto $P2; limine-install $DISK
[dry-run] mkdir ${MNT}/{meta,os,home,esp}
EOF
  echo "No changes made."
  exit 0
fi

fail_setup() {
  unset LUKS_PASS || true
  echo
  echo "============================================================" >&2
  echo " SETUP FAILED — the backup disk was NOT re-encrypted." >&2
  echo " The old password and old copies are unchanged." >&2
  echo " $*" >&2
  echo "============================================================" >&2
  if [[ -r /dev/tty ]]; then
    read -r -p "Press Enter to close." _ < /dev/tty || true
  fi
  exit 130
}

close_crypt_on_disk "$DISK" || fail_setup "could not unlock-close the old volume"
if [[ -b $P3 ]]; then
  wipe_luks_header "$P3"
fi
run wipefs -a "$DISK" || true
run sgdisk --zap-all "$DISK"
run sgdisk \
  -n "1:0:+${EFI_SIZE}" -t 1:ef00 -c 1:"$EFI_LABEL" \
  -n "2:0:+${LIVE_SIZE}" -t 2:8300 -c 2:"$LIVE_LABEL" \
  -n 3:0:0 -t 3:8309 -c 3:"$TM_LABEL" \
  "$DISK"
run partprobe "$DISK" || true
command -v udevadm >/dev/null && run udevadm settle || true
sleep 2
close_crypt_on_disk "$DISK" || true
[[ -b $P1 && -b $P2 && -b $P3 ]] || fail_setup "new partitions did not appear"
if lsblk -nr -o TYPE "$DISK" | grep -qx crypt; then
  fail_setup "old LUKS volume is still unlocked (Files/GNOME reopened it)"
fi
progress set setup 15

# Encrypt FIRST so a later EFI/live failure cannot leave the old volume in place.
wipe_luks_header "$P3"
log "LUKS format of $P3"
if ! printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$P3"; then
  fail_setup "cryptsetup luksFormat failed"
fi
new_uuid="$(luks_uuid_of "$P3")"
[[ -n $new_uuid ]] || fail_setup "luksFormat produced no UUID"
if [[ -n $OLD_LUKS_UUID && $new_uuid == "$OLD_LUKS_UUID" ]]; then
  fail_setup "LUKS UUID did not change (still $new_uuid)"
fi
log "new LUKS UUID $new_uuid (was ${OLD_LUKS_UUID:-none})"
printf '\nNew encryption UUID: %s\n(this MUST be different from the old one)\n\n' "$new_uuid" > /dev/tty || true
if ! printf '%s' "$LUKS_PASS" | cryptsetup open --key-file=- "$P3" "$LUKS_MAPPER"; then
  fail_setup "could not open the new LUKS volume with the password you just set"
fi
unset LUKS_PASS
progress set setup 22
run mkfs.btrfs -f -L "$TM_LABEL" "/dev/mapper/${LUKS_MAPPER}"
mkdir -p "$MNT"
run mount -o compress=zstd:3 "/dev/mapper/${LUKS_MAPPER}" "$MNT"
if compgen -G "$MNT/home/20*" >/dev/null || compgen -G "$MNT/os/20*" >/dev/null; then
  fail_setup "old restore points are still on the disk — format did not wipe the volume"
fi
run mkdir -p "$MNT/meta" "$MNT/os" "$MNT/home" "$MNT/esp"
chmod 755 "$MNT" "$MNT/os" "$MNT/home" "$MNT/esp" "$MNT/meta" 2>/dev/null || true
progress set setup 30

run mkfs.fat -F32 -n "$EFI_LABEL" "$P1"
run mkfs.ext4 -F -L "$LIVE_LABEL" "$P2"
progress set setup 35

install_live() {
  need_cmd curl
  need_cmd rsync
  need_cmd unsquashfs
  need_cmd mksquashfs
  local live=/run/oma-backups-live
  local efi=/run/omarchy-backups-efi
  mkdir -p "$live" "$efi"
  run mount "$P2" "$live"
  run mount "$P1" "$efi"
  install_archiso_rescue "$live" "$efi"
  install_rescue_limine "$DISK" "$efi"
  umount "$efi" || true
  umount "$live" || true
  rmdir "$live" "$efi" || true
  log "Arch ISO rescue installed on $P2"
}

if [[ $SKIP_LIVE != 1 ]]; then
  install_live
else
  EFI_MNT=/run/omarchy-backups-efi
  mkdir -p "$EFI_MNT"
  mount "$P1" "$EFI_MNT"
  cp "$OMARCHY_TM_ROOT/share/RESTORE.txt" "$EFI_MNT/RESTORE.txt"
  umount "$EFI_MNT"
fi
progress set setup 100

sync
run umount "$MNT"
run cryptsetup close "$LUKS_MAPPER"

log "formatted $DISK as an OmaBackups USB."
log "Firmware boot this USB for rescue. Next: oma-backups mount --disk $DISK && oma-backups backup"
