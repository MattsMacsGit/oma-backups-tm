#!/usr/bin/env bash
# Interactive first run: format /dev/sdc as the Time Capsule, mount, optional backup.
# Run in a real terminal (sudo + LUKS + restic passphrases).
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DISK=/dev/sdc
ISO=/run/media/matt/Ventoy/omarchy-4.0.0.iso
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-tm"
mkdir -p "$STATE"
LOG="$STATE/first-run-sdc.log"
PIDFILE="$STATE/first-run-sdc.pid"
echo $$ >"$PIDFILE"
exec > >(tee -a "$LOG") 2>&1

echo "=== omarchy-tm first run on $DISK ==="
echo "This WIPES the old 'Backups' images on the 1.8T Expansion card."
echo "Videos (~604G) is excluded from send + restic; live ~/Videos is not touched."
echo "To include Videos later: edit ~/.config/omarchy-tm/config.toml and backup again."
echo

if [[ ! -b $DISK ]]; then
  echo "ERROR: $DISK is not a block device"
  exit 1
fi
if [[ ! -f $ISO ]]; then
  echo "ERROR: Omarchy ISO not found at $ISO"
  exit 1
fi

echo "Installing restic / pv / gptfdisk / arch-install-scripts if needed..."
sudo pacman -S --needed --noconfirm restic pv gptfdisk arch-install-scripts

already=0
if lsblk -n -o LABEL "${DISK}1" 2>/dev/null | grep -qx OMARCHY-ISO \
  && lsblk -n -o FSTYPE "${DISK}2" 2>/dev/null | grep -qx crypto_LUKS; then
  already=1
  echo "$DISK already has Time Capsule partitions — skipping format."
fi

if [[ $already -eq 0 ]]; then
  if findmnt -n "${DISK}1" >/dev/null 2>&1; then
    echo "Unmounting ${DISK}1..."
    udisksctl unmount -b "${DISK}1" || sudo umount "${DISK}1"
  fi
  echo
  echo "Formatting $DISK — cryptsetup will ask for a NEW LUKS passphrase."
  echo "Store it OFF this home directory (password manager, paper, other USB)."
  sudo env OMARCHY_TM_YES=1 "$ROOT/omarchy-tm" format-disk "$DISK" --iso "$ISO" --extract-iso --yes
fi

echo
echo "Finishing ISO partition (skip files >4GiB — airootfs.sfs cannot live on FAT32)..."
sudo mkdir -p /run/omarchy-tm-iso /run/omarchy-tm-iso-src
if ! findmnt -n /run/omarchy-tm-iso >/dev/null 2>&1; then
  sudo mount "${DISK}1" /run/omarchy-tm-iso
fi
if [[ -f $ISO ]]; then
  if ! findmnt -n /run/omarchy-tm-iso-src >/dev/null 2>&1; then
    sudo mount -o loop,ro "$ISO" /run/omarchy-tm-iso-src
  fi
  sudo rsync -a --max-size=4294967294 /run/omarchy-tm-iso-src/ /run/omarchy-tm-iso/ || true
  sudo umount /run/omarchy-tm-iso-src || true
fi
sudo cp "$ROOT/share/RESTORE.txt" /run/omarchy-tm-iso/RESTORE.txt
sudo umount /run/omarchy-tm-iso || true

echo
echo "Mounting capsule..."
if ! findmnt -n /run/omarchy-tm >/dev/null 2>&1; then
  sudo "$ROOT/omarchy-tm" mount --disk "$DISK"
else
  echo "already mounted at /run/omarchy-tm"
fi

echo
echo "Capsule mounted:"
findmnt /run/omarchy-tm || true
sudo ls -la /run/omarchy-tm

echo
echo "First full backup is next. restic will ask for a SEPARATE password."
echo "Same rule: store it OFF this home. Expect many hours (home minus Videos is still ~450G, plus @)."
read -r -p "Start first full backup now? [type YES]: " ans
if [[ $ans != YES ]]; then
  echo "OK. When ready:"
  echo "  sudo $ROOT/omarchy-tm backup --yes"
  echo "FIRST_RUN_FORMAT_DONE"
  exit 0
fi

sudo env OMARCHY_TM_YES=1 "$ROOT/omarchy-tm" backup --yes
echo "FIRST_RUN_BACKUP_DONE"
