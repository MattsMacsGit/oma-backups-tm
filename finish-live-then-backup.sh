#!/usr/bin/env bash
# Resume after format: finish OMARCHY-LIVE rescue OS, then first backup.
# Intended to run as root via systemd-run (not tied to a terminal).
echo "begin $(date -Is) uid=$(id -u)" >>/tmp/omarchy-tm-setup.trace
set -euo pipefail
trap 'echo "ERR line $LINENO exit $?" >>/tmp/omarchy-tm-setup.trace' ERR
export OMARCHY_TM_YES=1
OMARCHY_TM_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export OMARCHY_TM_ROOT
echo "root=$OMARCHY_TM_ROOT" >>/tmp/omarchy-tm-setup.trace
# shellcheck source=lib/common.sh
source "$OMARCHY_TM_ROOT/lib/common.sh"
echo "sourced common" >>/tmp/omarchy-tm-setup.trace

DISK=/dev/sdb
P1="$(partition_path "$DISK" 1)"
P2="$(partition_path "$DISK" 2)"
LIVE=/run/omarchy-tm-live
MNT=/run/omarchy-tm
LOG=/var/log/omarchy-tm/setup.log
mkdir -p /var/log/omarchy-tm
exec >>"$LOG" 2>&1
log "=== finish-live-then-backup ==="

[[ $(id -u) -eq 0 ]] || die "must be root"

# Drop the desktop automount so we own P2.
if findmnt -n /run/media/test/OMARCHY-LIVE >/dev/null 2>&1; then
  umount /run/media/test/OMARCHY-LIVE || true
fi

mkdir -p "$LIVE"
if ! findmnt -n "$LIVE" >/dev/null 2>&1; then
  mount "$P2" "$LIVE"
fi
mkdir -p "$LIVE/boot"
if ! findmnt -n "$LIVE/boot" >/dev/null 2>&1; then
  mount "$P1" "$LIVE/boot"
fi

LIVE_PKGS=(
  base linux linux-firmware mkinitcpio limine
  amd-ucode intel-ucode
  btrfs-progs cryptsetup rsync restic jq python pv
  gptfdisk parted dosfstools arch-install-scripts
  networkmanager nano less sudo
)

log "ensuring rescue packages"
if [[ -x $LIVE/usr/bin/pacman ]]; then
  arch-chroot "$LIVE" pacman -S --needed --noconfirm "${LIVE_PKGS[@]}"
else
  pacstrap -K "$LIVE" "${LIVE_PKGS[@]}"
fi

cat >"$LIVE/etc/fstab" <<FSTAB
LABEL=OMARCHY-LIVE  /      ext4  defaults,relatime  0 1
LABEL=OMARCHY-EFI   /boot  vfat  defaults,umask=0077  0 2
FSTAB
echo omarchy-tm-rescue >"$LIVE/etc/hostname"
mkdir -p "$LIVE/opt"
rsync -a --delete "$OMARCHY_TM_ROOT"/ "$LIVE/opt/omarchy-tm/"
ln -sf /opt/omarchy-tm/omarchy-tm "$LIVE/usr/local/bin/omarchy-tm"
cp "$OMARCHY_TM_ROOT/share/RESTORE.txt" "$LIVE/boot/RESTORE.txt"
cp "$OMARCHY_TM_ROOT/share/rescue-banner.sh" "$LIVE/opt/omarchy-tm/share/rescue-banner.sh"
chmod +x "$LIVE/opt/omarchy-tm/share/rescue-banner.sh"
grep -q rescue-banner "$LIVE/root/.profile" 2>/dev/null || cat >>"$LIVE/root/.profile" <<'PROF'
if [[ -t 0 && -f /opt/omarchy-tm/share/rescue-banner.sh ]]; then
  bash /opt/omarchy-tm/share/rescue-banner.sh
fi
PROF
mkdir -p "$LIVE/etc/systemd/system/getty@tty1.service.d"
cat >"$LIVE/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<'AUTO'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
AUTO

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
kver="$(ls "$LIVE/usr/lib/modules" | head -1)"
if [[ -n $kver && -f $LIVE/usr/lib/modules/$kver/vmlinuz ]]; then
  cp -f "$LIVE/usr/lib/modules/$kver/vmlinuz" "$LIVE/boot/vmlinuz-linux"
  log "copied vmlinuz $kver -> /boot/vmlinuz-linux"
fi
if [[ ! -f $LIVE/etc/mkinitcpio.d/linux.preset ]]; then
  mkdir -p "$LIVE/etc/mkinitcpio.d"
  cat >"$LIVE/etc/mkinitcpio.d/linux.preset" <<PRE
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux"
PRESETS=('default')
default_image="/boot/initramfs-linux.img"
PRE
fi
log "mkinitcpio"
if ! arch-chroot "$LIVE" mkinitcpio -P >>/tmp/omarchy-tm-setup.trace 2>&1; then
  log "mkinitcpio -P failed, trying explicit image"
  arch-chroot "$LIVE" mkinitcpio -g /boot/initramfs-linux.img -k "$kver" >>/tmp/omarchy-tm-setup.trace 2>&1 \
    || die "mkinitcpio failed (see /tmp/omarchy-tm-setup.trace)"
fi

k="$(find "$LIVE/boot" -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' | head -1)"
init="$(find "$LIVE/boot" -maxdepth 1 -name 'initramfs-linux.img' -printf '%f\n' | head -1)"
[[ -n $k && -n $init ]] || die "kernel/initramfs missing on ESP"
ucode=""
[[ -f $LIVE/boot/amd-ucode.img ]] && ucode+=$'\n    module_path: boot():/amd-ucode.img'
[[ -f $LIVE/boot/intel-ucode.img ]] && ucode+=$'\n    module_path: boot():/intel-ucode.img'
cat >"$LIVE/boot/limine.conf" <<LIM
timeout: 8
interface_branding: Omarchy Time Capsule
/:Rescue
    protocol: linux
    path: boot():/${k}
${ucode}
    module_path: boot():/${init}
    cmdline: root=LABEL=OMARCHY-LIVE rootfstype=ext4 rw
LIM

arch-chroot "$LIVE" limine-install "$DISK" || true
mkdir -p "$LIVE/boot/EFI/BOOT" "$LIVE/boot/EFI/limine"
for efi_src in \
  "$LIVE/usr/share/limine/BOOTX64.EFI" \
  "$LIVE/usr/share/limine/limine_x64.efi" \
  /usr/share/limine/BOOTX64.EFI
do
  if [[ -f $efi_src ]]; then
    cp "$efi_src" "$LIVE/boot/EFI/BOOT/BOOTX64.EFI"
    cp "$efi_src" "$LIVE/boot/EFI/limine/BOOTX64.EFI"
    log "installed $efi_src as BOOTX64.EFI"
    break
  fi
done
[[ -f $LIVE/boot/EFI/BOOT/BOOTX64.EFI ]] || log "WARNING: no BOOTX64.EFI"

sync
# Do not fail the backup if the live tree is busy (gpg-agent, automount).
umount "$LIVE/boot" 2>/dev/null || umount -l "$LIVE/boot" 2>/dev/null || true
umount "$LIVE" 2>/dev/null || umount -l "$LIVE" 2>/dev/null || true
log "LIVE_INSTALL_DONE"

# Capsule data mount should still be up; remount if not.
if ! findmnt -n "$MNT" >/dev/null 2>&1; then
  "$OMARCHY_TM_ROOT/omarchy-tm" mount --disk "$DISK"
fi

export RESTIC_PASSWORD_FILE=/etc/omarchy-tm/restic.pass
if [[ -s $RESTIC_PASSWORD_FILE ]]; then
  export RESTIC_REPOSITORY="$MNT/files/restic"
  restic snapshots >/dev/null 2>&1 || restic init
else
  log "no restic password file; file history will be skipped"
fi

log "starting backup"
"$OMARCHY_TM_ROOT/omarchy-tm" backup --yes
log "SETUP_AND_BACKUP_DONE"
