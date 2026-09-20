#!/usr/bin/env bash
# Bare-metal restore of a VALID snapshot onto a BLANK disk.
set -euo pipefail

OMARCHY_TM_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export OMARCHY_TM_ROOT
# shellcheck source=lib/common.sh
source "$OMARCHY_TM_ROOT/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: oma-backups restore-to-disk /dev/TARGET --snapshot TIMESTAMP [--level full|settings] [--from-pi] [--dry-run] [--yes] [--allow-internal]

--from-pi: read the restore point from the paired Pi (remote.json) instead of
the mounted backup disk. The network rescue stick uses this.

--level settings: the system plus each home's hidden settings (.config,
.local, ...); visible folders come back empty and files over 100 MB are
skipped. Bring the rest back later with "Restore my files".

Restores a VALID (os+home+esp) point onto a blank disk so it boots Omarchy:
  GPT → 2G ESP + LUKS2 → btrfs (@, @home, empty @log/@pkg)
  rsync the snapshot, rewrite fstab + cryptdevice=PARTUUID
  mkinitcpio + Limine on the new ESP

Refuses the live root disk and the backup USB itself.
Internal disks (NVMe/SATA) need --allow-internal unless you booted the
rescue USB (that is the intended full-restore path).
EOF
}

TARGET=""
SNAPSHOT=""
LEVEL=full
FROM_PI=0
ORIG_ARGS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) export OMARCHY_TM_DRY_RUN=1; shift ;;
    --yes) export OMARCHY_TM_YES=1; shift ;;
    --allow-internal) export OMARCHY_TM_ALLOW_INTERNAL=1; shift ;;
    --snapshot) SNAPSHOT=${2:-}; shift 2 ;;
    --level) LEVEL=${2:-}; shift 2 ;;
    --from-pi) FROM_PI=1; shift ;;
    --*) die "unknown flag: $1" ;;
    *)
      if [[ -z $TARGET ]]; then
        TARGET=$1
        shift
      else
        die "unexpected argument: $1"
      fi
      ;;
  esac
done

[[ -n $TARGET && -n $SNAPSHOT ]] || { usage >&2; exit 1; }
[[ $LEVEL == full || $LEVEL == settings ]] || die "--level must be full or settings"

load_config_json
require_supported

MNT="$(cfg '.paths.mountpoint')"
ESP_SIZE="$(cfg '.restore_layout.esp_size')"
MAPPER="$(cfg '.restore_layout.luks_mapper')"

refuse_dangerous_disk "$TARGET" "restore onto"
require_usb_or_allow "$TARGET" "restore onto"

if findmnt -n "$MNT" >/dev/null 2>&1; then
  cap_src="$(findmnt -n -o SOURCE "$MNT")"
  cap_disk="$(lsblk -n -o PKNAME "$cap_src" 2>/dev/null | head -1 || true)"
  if [[ -n $cap_disk ]]; then
    parent="$(lsblk -n -o PKNAME "/dev/$cap_disk" 2>/dev/null | head -1 || true)"
    [[ -n $parent ]] && cap_disk=$parent
    if [[ $(real_dev "/dev/$cap_disk") == "$(real_dev "$TARGET")" ]]; then
      die "REFUSING to restore onto the backup disk itself"
    fi
  fi
fi

# Where the restore point is read from: the mounted backup disk, or the Pi.
RSYNC_RSH=()
if [[ $FROM_PI == 1 ]]; then
  # shellcheck source=lib/remote.sh
  source "$OMARCHY_TM_ROOT/lib/remote.sh"
  remote_load
  RSYNC_RSH=(-e "$(remote_rsh)")
fi
src() {
  if [[ $FROM_PI == 1 ]]; then printf '%s:%s\n' "$(remote_target)" "$1"; else printf '%s\n' "$MNT/$1"; fi
}
src_exists() {
  if [[ $FROM_PI == 1 ]]; then rgate exists "$1" 2>/dev/null; else [[ -d $MNT/$1 ]]; fi
}

P1="$(partition_path "$TARGET" 1)"
P2="$(partition_path "$TARGET" 2)"
NEW_ROOT=/run/oma-backups-restore
NEW_ESP=/run/oma-backups-restore-esp

print_plan() {
  cat <<EOF
== restore-to-disk --snapshot $SNAPSHOT ==
Target:     $TARGET   $(lsblk -n -d -o SIZE,MODEL,TRAN "$TARGET" 2>/dev/null || true)
Capsule:    $(src "")
Snapshot:   $SNAPSHOT  (restore level: $LEVEL)
Live root:  $(printf '%s' "$DETECT_JSON" | jq -r '.live_root_disk')  [always refused]
Rescue:     $(is_rescue && echo yes || echo no)
Allow internal: ${OMARCHY_TM_ALLOW_INTERNAL:-0}

THIS ERASES $TARGET.

# 1. GPT: ${ESP_SIZE} ESP + LUKS rest
wipefs -a $TARGET
sgdisk --zap-all $TARGET
sgdisk -n 1:0:+${ESP_SIZE} -t 1:ef00 -c 1:ESP \\
       -n 2:0:0 -t 2:8309 -c 2:root $TARGET
mkfs.fat -F32 -n OMARCHY $P1
cryptsetup luksFormat --type luks2 $P2
cryptsetup open $P2 $MAPPER
mkfs.btrfs -L omarchy /dev/mapper/$MAPPER

# 2. Subvolumes + rsync (not btrfs send — excludes already applied at backup)
mount /dev/mapper/$MAPPER $NEW_ROOT
btrfs subvolume create $NEW_ROOT/@ $NEW_ROOT/@home $NEW_ROOT/@log $NEW_ROOT/@pkg
rsync -aHAX --numeric-ids --info=progress2 $(src os/$SNAPSHOT)/   $NEW_ROOT/@/
rsync -aHAX --numeric-ids --info=progress2 $(src home/$SNAPSHOT)/ $NEW_ROOT/@home/
rsync -a --info=progress2 $(src esp/$SNAPSHOT)/ $NEW_ESP/

# 3. Rewrite fstab UUID + /etc/default/limine cryptdevice=PARTUUID
#    drop resume_offset (swapfile is not restored as-is)
# 4. arch-chroot limine-mkinitcpio && limine-install $TARGET
EOF
}

print_plan

if is_dry_run; then
  echo
  echo "Dry-run only. No partitions were touched."
  if [[ $FROM_PI == 0 ]] && ! findmnt -n "$MNT" >/dev/null 2>&1; then
    echo "Note: backup disk is not mounted; VALID-check of $SNAPSHOT cannot be performed yet."
  elif ! src_exists "os/$SNAPSHOT" || ! src_exists "home/$SNAPSHOT" || ! src_exists "esp/$SNAPSHOT"; then
    echo "WARNING: $SNAPSHOT is not a VALID restore point on the mounted disk."
  else
    echo "Backup disk has os+home+esp for $SNAPSHOT — would be VALID."
  fi
  exit 0
fi

require_root "${ORIG_ARGS[@]}"
need_cmd cryptsetup
need_cmd mkfs.btrfs
need_cmd mkfs.fat
need_cmd rsync
need_cmd sgdisk
need_cmd arch-chroot

src_exists "os/$SNAPSHOT" || die "missing os snapshot $SNAPSHOT"
src_exists "home/$SNAPSHOT" || die "missing home snapshot $SNAPSHOT"
src_exists "esp/$SNAPSHOT" || die "missing esp snapshot $SNAPSHOT"

confirm "ERASE $TARGET and restore snapshot $SNAPSHOT onto it?"

ask_new_luks_pass() {
  local tty=/dev/tty
  [[ -r $tty && -w $tty ]] || die "need a real terminal to set the new disk encryption password"
  {
    echo
    echo "============================================================"
    echo " NEW encryption password for the restored system disk"
    echo " (this is the password you type at the boot unlock prompt)"
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

ask_new_luks_pass

while read -r mp; do
  [[ -z $mp ]] && continue
  case "$mp" in
    /|/boot|/home) die "$TARGET is mounted as $mp" ;;
  esac
  umount -R "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
done < <(lsblk -n -o MOUNTPOINTS "$TARGET" | awk 'NF')

run wipefs -a "$TARGET" || true
run sgdisk --zap-all "$TARGET"
run sgdisk \
  -n "1:0:+${ESP_SIZE}" -t 1:ef00 -c 1:ESP \
  -n 2:0:0 -t 2:8309 -c 2:root \
  "$TARGET"
run partprobe "$TARGET" || true
command -v udevadm >/dev/null && udevadm settle || true
sleep 1
[[ -b $P1 && -b $P2 ]] || die "partitions $P1 $P2 did not appear"

run mkfs.fat -F32 -n OMARCHY "$P1"
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$P2"
printf '%s' "$LUKS_PASS" | cryptsetup open --key-file=- "$P2" "$MAPPER"
unset LUKS_PASS
run mkfs.btrfs -L omarchy "/dev/mapper/$MAPPER"

mkdir -p "$NEW_ROOT"
run mount -o compress=zstd:3 "/dev/mapper/$MAPPER" "$NEW_ROOT"
run btrfs subvolume create "$NEW_ROOT/@"
run btrfs subvolume create "$NEW_ROOT/@home"
run btrfs subvolume create "$NEW_ROOT/@log"
run btrfs subvolume create "$NEW_ROOT/@pkg"
# @log and @pkg are never rsynced from the backup (regenerable caches), so
# unlike @ and @home they never inherit real permissions from the source
# system. A bare `btrfs subvolume create` can leave them 0700 root:root,
# which breaks pacman's DownloadUser=alpm sandbox (needs 'other' rx into
# the pkg cache) on every restored system until someone notices. Match a
# normal install.
chmod 755 "$NEW_ROOT/@log" "$NEW_ROOT/@pkg"

log "rsync OS snapshot"
rsync "${RSYNC_RSH[@]}" -aHAX --numeric-ids --info=progress2 --delete \
  --exclude=swap --exclude=swapfile --exclude=tmp --exclude=var/tmp \
  "$(src "os/$SNAPSHOT")"/ "$NEW_ROOT/@/"
log "rsync home snapshot ($LEVEL)"
home_filter=()
if [[ $LEVEL == settings ]]; then
  # Hidden files and folders at the top of each home (.config, .local, ...)
  # come back; visible folders (Documents, Pictures, ...) come back empty;
  # anything over 100 MB is left for "Restore my files" (games, AI models).
  home_filter=(--max-size=100M --include='/*/' --include='/*/.*' --include='/*/.*/**'
    --include='/*/*/' --exclude='/*/**')
fi
rsync "${RSYNC_RSH[@]}" -aHAX --numeric-ids --info=progress2 --delete "${home_filter[@]}" \
  "$(src "home/$SNAPSHOT")"/ "$NEW_ROOT/@home/"
if [[ $LEVEL == settings ]]; then
  # While this marker exists, the restored system's plugin offers "Restore my
  # files" and backups never thin away $SNAPSHOT: until the files are back,
  # it's the only restore point that still has them. It lives in each user's
  # own state folder so the plugin (running as that user) can clear it.
  for h in "$NEW_ROOT/@home"/*/; do
    [[ -d $h ]] || continue
    d="$h.local/state/omarchy-backups"
    mkdir -p "$d"
    jq -n --arg s "$SNAPSHOT" --arg at "$(ts)" \
      '{snapshot: $s, level: "settings", restored_at: $at}' >"$d/partial-restore.json"
    chown --reference="$h" "$h.local" "$h.local/state" "$d" "$d/partial-restore.json" 2>/dev/null || true
  done
fi

mkdir -p "$NEW_ESP"
run mount "$P1" "$NEW_ESP"
log "rsync ESP snapshot"
rsync "${RSYNC_RSH[@]}" -a --info=progress2 --delete-delay "$(src "esp/$SNAPSHOT")"/ "$NEW_ESP/" || true

NEW_BTRFS_UUID="$(blkid -s UUID -o value "/dev/mapper/$MAPPER")"
NEW_ESP_UUID="$(blkid -s UUID -o value "$P1")"
NEW_PARTUUID="$(blkid -s PARTUUID -o value "$P2")"
[[ -n $NEW_BTRFS_UUID && -n $NEW_ESP_UUID && -n $NEW_PARTUUID ]] || die "missing new UUIDs"

FSTAB="$NEW_ROOT/@/etc/fstab"
if [[ -f $FSTAB ]]; then
  python3 - "$FSTAB" "$NEW_BTRFS_UUID" "$NEW_ESP_UUID" <<'PY'
import re, sys
path, btrfs_uuid, esp_uuid = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8", errors="replace").read()
# Replace btrfs UUID= lines (root/home/log/pkg)
text = re.sub(
    r"^UUID=[0-9a-fA-F-]+(\s+/\s+btrfs)",
    f"UUID={btrfs_uuid}\\1",
    text,
    flags=re.M,
)
text = re.sub(
    r"^UUID=[0-9a-fA-F-]+(\s+/home\s+btrfs)",
    f"UUID={btrfs_uuid}\\1",
    text,
    flags=re.M,
)
text = re.sub(
    r"^UUID=[0-9a-fA-F-]+(\s+/var/log\s+btrfs)",
    f"UUID={btrfs_uuid}\\1",
    text,
    flags=re.M,
)
text = re.sub(
    r"^UUID=[0-9a-fA-F-]+(\s+/var/cache/pacman/pkg\s+btrfs)",
    f"UUID={btrfs_uuid}\\1",
    text,
    flags=re.M,
)
text = re.sub(
    r"^UUID=[0-9A-F-]+(\s+/boot\s+vfat)",
    f"UUID={esp_uuid}\\1",
    text,
    flags=re.M,
)
# Comment hibernation swapfile — offset is wrong on a new disk
lines = []
for line in text.splitlines(True):
    if "swapfile" in line and not line.lstrip().startswith("#"):
        lines.append("# restored: swapfile omitted\n# " + line)
    else:
        lines.append(line)
open(path, "w", encoding="utf-8").writelines(lines)
PY
fi

rewrite_cryptdevice() {
  local file=$1
  [[ -f $file ]] || return 0
  python3 - "$file" "$NEW_PARTUUID" <<'PY'
import re, sys
path, partuuid = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8", errors="replace").read()
text = re.sub(
    r"cryptdevice=PARTUUID=[0-9a-fA-F-]+",
    f"cryptdevice=PARTUUID={partuuid}",
    text,
)
# Hibernation offset is invalid on a new disk. Empty resume= hangs the initramfs.
text = re.sub(r"\s*resume_offset=\S+", "", text)
text = re.sub(r"\s*resume=\S*", "", text)
open(path, "w", encoding="utf-8").write(text)
PY
}

rewrite_cryptdevice "$NEW_ROOT/@/etc/default/limine"
rewrite_cryptdevice "$NEW_ROOT/@/etc/limine-entry-tool.d/resume.conf"
# Drop leftover resume drop-in if it is now empty of resume=
if [[ -f $NEW_ROOT/@/etc/limine-entry-tool.d/resume.conf ]]; then
  if ! grep -q 'resume' "$NEW_ROOT/@/etc/limine-entry-tool.d/resume.conf"; then
    echo "# restored: hibernation resume disabled (new disk)" >"$NEW_ROOT/@/etc/limine-entry-tool.d/resume.conf"
  fi
fi

# Mount the new @ as the chroot root
umount "$NEW_ROOT"
mkdir -p "$NEW_ROOT"
run mount -o subvol=@,compress=zstd:3 "/dev/mapper/$MAPPER" "$NEW_ROOT"
mkdir -p "$NEW_ROOT/home" "$NEW_ROOT/var/log" "$NEW_ROOT/var/cache/pacman/pkg" "$NEW_ROOT/boot" "$NEW_ROOT/tmp"
run mount -o subvol=@home,compress=zstd:3 "/dev/mapper/$MAPPER" "$NEW_ROOT/home"
run mount -o subvol=@log,compress=zstd:3 "/dev/mapper/$MAPPER" "$NEW_ROOT/var/log"
run mount -o subvol=@pkg,compress=zstd:3 "/dev/mapper/$MAPPER" "$NEW_ROOT/var/cache/pacman/pkg"
run mount --bind "$NEW_ESP" "$NEW_ROOT/boot"

log "rebuild initramfs for new PARTUUID $NEW_PARTUUID"
if arch-chroot "$NEW_ROOT" bash -lc 'command -v limine-mkinitcpio >/dev/null && limine-mkinitcpio'; then
  log "limine-mkinitcpio exited 0 (it can still leave the old UKI cmdline — verifying next)"
elif arch-chroot "$NEW_ROOT" bash -lc 'mkinitcpio -P && (limine-update || true)'; then
  log "mkinitcpio exited 0 — verifying UKI cmdline next"
else
  log "WARNING: limine-mkinitcpio failed — will patch UKI/limine.conf in place"
fi

# Boot reads the UKI .cmdline and ESP limine.conf, not /etc/default/limine.
# Official Arch ISO rescue has no binutils; objcopy comes from this chroot.
if ! "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/patch_boot_cmdline.py" \
  --esp "$NEW_ESP" --partuuid "$NEW_PARTUUID" --chroot "$NEW_ROOT" --verify-only; then
  log "UKI/limine.conf still have the old cryptdevice; patching PARTUUID=$NEW_PARTUUID"
  "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/patch_boot_cmdline.py" \
    --esp "$NEW_ESP" --partuuid "$NEW_PARTUUID" --chroot "$NEW_ROOT" \
    || die "could not patch UKI cmdline"
fi
if ! "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/patch_boot_cmdline.py" \
  --esp "$NEW_ESP" --partuuid "$NEW_PARTUUID" --verify-only; then
  die "restored disk would not unlock LUKS (UKI cmdline PARTUUID != $NEW_PARTUUID). Restore aborted."
fi
log "boot cmdline verified PARTUUID=$NEW_PARTUUID"

if command -v limine-install >/dev/null; then
  limine-install "$TARGET" || true
fi
arch-chroot "$NEW_ROOT" bash -lc "limine-install $TARGET || limine bios-install $TARGET || true" || true
mkdir -p "$NEW_ESP/EFI/BOOT" "$NEW_ESP/EFI/limine"
for efi_src in \
  /usr/share/limine/BOOTX64.EFI \
  "$NEW_ROOT/usr/share/limine/BOOTX64.EFI" \
  /usr/share/limine/limine-uefi.efi
do
  if [[ -f $efi_src ]]; then
    cp "$efi_src" "$NEW_ESP/EFI/BOOT/BOOTX64.EFI"
    cp "$efi_src" "$NEW_ESP/EFI/limine/limine-uefi.efi" 2>/dev/null || true
    break
  fi
done

sync
umount "$NEW_ROOT/boot" || true
umount "$NEW_ROOT/home" || true
umount "$NEW_ROOT/var/log" || true
umount "$NEW_ROOT/var/cache/pacman/pkg" || true
umount "$NEW_ROOT" || true
umount "$NEW_ESP" || true
cryptsetup close "$MAPPER" || true

log "restore complete."
log "Reboot, pick this disk in firmware, unlock LUKS with the password you just set."
log "TPM auto-unlock is not restored — enroll it again after login if you use it."
