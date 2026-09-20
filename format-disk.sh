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
Usage: oma-backups format-disk /dev/sdX [--dry-run] [--yes] [--force] [--skip-live] [--iso PATH]

GPT:
  1. ~1G FAT32   OMABOOT        UEFI ESP (Limine + Omarchy ISO kernel)
  2. ~16G ext4   OmaRescue      real Omarchy installer ISO + restore scripts
  3. rest LUKS2→btrfs OmaBackups  backups

Rescue is the real Omarchy installer environment (not a pacstrap of this
machine). Firmware boots Limine → Omarchy live → restore wizard. Needs an
Omarchy ISO from https://omarchy.org/ — picked up automatically from
~/Downloads, or point at one directly with --iso.

--skip-live   partition + LUKS + btrfs only (no ISO/Limine)
--iso PATH    use this Omarchy ISO instead of searching for one
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

load_config_json
require_supported
require_root "${ORIG_ARGS[@]}"

ensure_deps wipefs cryptsetup mkfs.fat mkfs.btrfs lsblk jq gum bsdtar
if ! is_dry_run; then
  ensure_deps mkfs.ext4 sgdisk
  # Check early — before anything on the disk is touched — rather than
  # discovering it's missing partway through the wipe.
  [[ $SKIP_LIVE != 1 ]] && ensure_omarchy_iso >/dev/null
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
    [[ -n $OLD_LUKS_UUID ]] && log_file "existing LUKS UUID $OLD_LUKS_UUID — will refuse to continue if this does not change"
  fi
fi

P1="$(partition_path "$DISK" 1)"
P2="$(partition_path "$DISK" 2)"
P3="$(partition_path "$DISK" 3)"

echo
gum style --bold "Setting up $DISK as a backup disk"
echo
gum style --foreground 8 "  $(lsblk -n -d -o SIZE,MODEL,TRAN "$DISK" 2>/dev/null || true)"
gum style --foreground 8 "  $P1   ${EFI_SIZE} FAT32  ${EFI_LABEL}   (ESP)"
gum style --foreground 8 "  $P2   ${LIVE_SIZE} ext4  ${LIVE_LABEL}  (rescue OS)"
gum style --foreground 8 "  $P3   rest  LUKS2→btrfs ${TM_LABEL}"
gum style --foreground 8 "  Live OS: $([[ $SKIP_LIVE == 1 ]] && echo skipped || echo "real Omarchy installer + restore wizard")"
is_dry_run && gum style --foreground 8 "  Dry-run: no changes will be made"
echo
gum style --bold --foreground 1 "This erases $DISK."
echo

ask_new_luks_pass() {
  local tty=/dev/tty
  local p1="" p2=""
  if [[ -r $tty && -w $tty ]]; then
    echo
    gum style --foreground 8 "New encryption password for this backup disk — not your login"
    gum style --foreground 8 "password, you will need this to restore."
    p1=$(gum input --password --header "Encryption password") || die "aborted"
    p2=$(gum input --password --header "Confirm password") || die "aborted"
  else
    # No controlling terminal (plugin-driven run with "show terminal" off)
    # — the plugin prompts for the password itself and sends it over
    # stdin instead, two lines: password, confirm.
    IFS= read -r p1 || true
    IFS= read -r p2 || true
  fi
  [[ -n $p1 && $p1 == "$p2" ]] || die "passwords empty or did not match — disk was NOT erased"
  LUKS_PASS="$p1"
  p1="" p2=""
}

if ! is_dry_run; then
  confirm "Wipe $DISK and write a bootable Time Capsule?"
  progress phase "waiting-input"
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
[dry-run] extract the Omarchy ISO onto $P2; limine-install $DISK
[dry-run] mkdir ${MNT}/{meta,os,home,esp}
EOF
  echo "No changes made."
  exit 0
fi

fail_setup() {
  unset LUKS_PASS || true
  echo
  gum style --bold --foreground 1 "Setup failed — the backup disk was NOT re-encrypted."
  gum style --foreground 8 "The old password and old copies are unchanged."
  gum style --foreground 1 "$*"
  if [[ -r /dev/tty ]]; then
    read -r -p "Press Enter to close." _ < /dev/tty || true
  fi
  exit 130
}

# Safety net for a command failure we didn't explicitly check — run_quiet's
# output only goes to the log file now, so without this the terminal would
# otherwise just go blank with no clue what happened.
trap 'fail_setup "unexpected failure — see $OMARCHY_TM_LOG for details"' ERR

close_crypt_on_disk "$DISK" || fail_setup "could not unlock-close the old volume"
if [[ -b $P3 ]]; then
  wipe_luks_header "$P3"
fi
step "Wiping old partition signatures"
run_quiet wipefs -a "$DISK" || true
step "Partitioning the disk"
run_quiet sgdisk --zap-all "$DISK"
run_quiet sgdisk \
  -n "1:0:+${EFI_SIZE}" -t 1:ef00 -c 1:"$EFI_LABEL" \
  -n "2:0:+${LIVE_SIZE}" -t 2:8300 -c 2:"$LIVE_LABEL" \
  -n 3:0:0 -t 3:8309 -c 3:"$TM_LABEL" \
  "$DISK"
run_quiet partprobe "$DISK" || true
command -v udevadm >/dev/null && run_quiet udevadm settle || true
sleep 2
close_crypt_on_disk "$DISK" || true
[[ -b $P1 && -b $P2 && -b $P3 ]] || fail_setup "new partitions did not appear"
if lsblk -nr -o TYPE "$DISK" | grep -qx crypt; then
  fail_setup "old LUKS volume is still unlocked (Files/GNOME reopened it)"
fi
progress set setup 15

# Encrypt FIRST so a later EFI/live failure cannot leave the old volume in place.
wipe_luks_header "$P3"
step "Setting up encryption"
if ! printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$P3"; then
  fail_setup "cryptsetup luksFormat failed"
fi
new_uuid="$(luks_uuid_of "$P3")"
[[ -n $new_uuid ]] || fail_setup "luksFormat produced no UUID"
if [[ -n $OLD_LUKS_UUID && $new_uuid == "$OLD_LUKS_UUID" ]]; then
  fail_setup "LUKS UUID did not change (still $new_uuid)"
fi
log_file "new LUKS UUID $new_uuid (was ${OLD_LUKS_UUID:-none})"
# A backup disk pulled out while unlocked leaves its mapper behind under the
# same name, which would make the open below fail.
close_stale_mapper "$LUKS_MAPPER"
[[ ! -e /dev/mapper/$LUKS_MAPPER ]] ||
  fail_setup "another backup disk is still unlocked as $LUKS_MAPPER. Eject it in Files (or run: sudo oma-backups umount) and try again."
if ! printf '%s' "$LUKS_PASS" | cryptsetup open --key-file=- "$P3" "$LUKS_MAPPER"; then
  fail_setup "could not open the new LUKS volume with the password you just set"
fi
# If this laptop already unlocks backups by itself (automatic backups or a
# paired Pi), give the new disk its key too, while the password is at hand.
if capsule_key_present; then
  printf '%s' "$LUKS_PASS" | cryptsetup luksAddKey --key-file=- \
    --pbkdf pbkdf2 --pbkdf-force-iterations 1000 "$P3" "$OMA_CAPSULE_KEY" ||
    warn "couldn't add this laptop's unlock key; automatic backups will ask you to switch them off and on"
fi
unset LUKS_PASS
progress set setup 22

step "Formatting the encrypted volume"
run_quiet mkfs.btrfs -f -L "$TM_LABEL" "/dev/mapper/${LUKS_MAPPER}"
mkdir -p "$MNT"
run_quiet mount -o compress=zstd:3 "/dev/mapper/${LUKS_MAPPER}" "$MNT"
if compgen -G "$MNT/home/20*" >/dev/null || compgen -G "$MNT/os/20*" >/dev/null; then
  fail_setup "old restore points are still on the disk — format did not wipe the volume"
fi
run_quiet mkdir -p "$MNT/meta" "$MNT/os" "$MNT/home" "$MNT/esp"
chmod 755 "$MNT" "$MNT/os" "$MNT/home" "$MNT/esp" "$MNT/meta" 2>/dev/null || true
progress set setup 30

step "Formatting the boot and rescue partitions"
run_quiet mkfs.fat -F32 -n "$EFI_LABEL" "$P1"
run_quiet mkfs.ext4 -F -L "$LIVE_LABEL" "$P2"
progress set setup 35

install_live() {
  need_cmd curl
  need_cmd rsync
  need_cmd unsquashfs
  need_cmd mksquashfs
  local live=/run/oma-backups-live
  local efi=/run/omarchy-backups-efi
  mkdir -p "$live" "$efi"
  run_quiet mount "$P2" "$live"
  run_quiet mount "$P1" "$efi"
  install_archiso_rescue "$live" "$efi"
  install_rescue_limine "$DISK" "$efi"
  umount "$efi" || true
  umount "$live" || true
  rmdir "$live" "$efi" || true
  step "Rescue system installed on $LIVE_LABEL"
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
run_quiet umount "$MNT"
run_quiet cryptsetup close "$LUKS_MAPPER"
set_current_capsule "$new_uuid"

trap - ERR
echo
gum style --bold --foreground 2 "● Backup disk ready."
gum style --foreground 8 "  Firmware-boot this USB for a full rescue."
gum style --foreground 8 "  Next: oma-backups mount --disk $DISK && oma-backups backup"
