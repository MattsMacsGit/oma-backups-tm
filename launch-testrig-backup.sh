#!/usr/bin/env bash
# Format OMABACKUP as a bootable capsule, then backup testrig (Videos excluded)
# as a systemd unit so closing this window does not kill the send.
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DISK=/dev/sdb
LOG=/var/log/omarchy-tm/backup.log

echo "=== testrig → Time Capsule ==="
echo "Source: this OS (Videos excluded). Dest: $DISK (currently OMABACKUP)."
echo "Framework NVMe is refused. Live root (this USB) is refused."
echo

# Identify dest still looks like the Expansion card.
model="$(lsblk -n -d -o MODEL "$DISK" 2>/dev/null || true)"
label="$(lsblk -n -o LABEL "$DISK"1 2>/dev/null | head -1 || true)"
echo "Target $DISK model='$model' p1_label='$label'"
if [[ $model != *Expansion* && $label != OMABACKUP && $label != OMARCHY-EFI ]]; then
  echo "Refusing to guess the dest disk. Set DISK= in this script."
  exit 1
fi

echo "Installing restic / pv / gptfdisk / arch-install-scripts / dosfstools if needed..."
sudo pacman -S --needed --noconfirm restic pv gptfdisk arch-install-scripts dosfstools e2fsprogs

if findmnt -n "${DISK}1" >/dev/null 2>&1; then
  echo "Unmounting ${DISK}1..."
  udisksctl unmount -b "${DISK}1" || sudo umount "${DISK}1"
fi

echo
echo "Formatting $DISK (bootable EFI + live rescue + LUKS). cryptsetup will ask for a passphrase."
sudo env OMARCHY_TM_YES=1 "$ROOT/omarchy-tm" format-disk "$DISK" --yes --force

echo
echo "Mounting capsule..."
sudo "$ROOT/omarchy-tm" mount --disk "$DISK"

echo
echo "restic password (file history). Stored at /etc/omarchy-tm/restic.pass on THIS testrig"
echo "(that file is inside @, so it will be in the OS send — fine for a test box)."
sudo mkdir -p /etc/omarchy-tm
sudo chmod 700 /etc/omarchy-tm
if [[ ! -s /etc/omarchy-tm/restic.pass ]]; then
  read -r -s -p "restic password: " rp1; echo
  read -r -s -p "confirm: " rp2; echo
  [[ $rp1 == "$rp2" && -n $rp1 ]] || { echo "passwords did not match"; exit 1; }
  printf '%s' "$rp1" | sudo tee /etc/omarchy-tm/restic.pass >/dev/null
  sudo chmod 600 /etc/omarchy-tm/restic.pass
  unset rp1 rp2
fi
export RESTIC_PASSWORD_FILE=/etc/omarchy-tm/restic.pass
export RESTIC_REPOSITORY=/run/omarchy-tm/files/restic
sudo -E restic snapshots >/dev/null 2>&1 || sudo -E restic init

echo
echo "Starting backup as systemd unit omarchy-tm-backup (survives closing this window)."
sudo mkdir -p /var/log/omarchy-tm
sudo systemctl stop omarchy-tm-backup.service 2>/dev/null || true
sudo systemctl reset-failed omarchy-tm-backup.service 2>/dev/null || true
sudo systemd-run --unit=omarchy-tm-backup \
  --description='omarchy-tm testrig backup' \
  --property=StandardOutput=append:"$LOG" \
  --property=StandardError=append:"$LOG" \
  --property=Environment=RESTIC_PASSWORD_FILE=/etc/omarchy-tm/restic.pass \
  --working-directory="$ROOT" \
  "$ROOT/omarchy-tm" backup --yes

echo
echo "Progress (Ctrl-C only stops the viewer, not the backup):"
echo "  journalctl -u omarchy-tm-backup -f"
echo "  tail -f $LOG"
echo
exec sudo journalctl -u omarchy-tm-backup -f
