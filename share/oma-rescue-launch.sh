#!/usr/bin/env bash
# Lives INSIDE the Arch live squashfs (always present after login).
# Finds OmaBackups on OMARCHY-LIVE / OMARCHY-EFI by label — does not
# depend on /run/archiso/bootmnt still being mounted.
set -euo pipefail

if [[ -t 1 ]]; then
  echo
  echo "  OmaBackups — looking for restore scripts on this USB..."
fi

find_root() {
  local cand mp dev
  for cand in \
    /run/archiso/bootmnt/oma-backups \
    /run/oma-usb/oma-backups
  do
    if [[ -f $cand/share/rescue-run.sh || -x $cand/omarchy-backups ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  for dev in /dev/disk/by-label/OMARCHY-LIVE /dev/disk/by-label/OMARCHY-EFI; do
    [[ -e $dev ]] || continue
    mp="$(lsblk -n -o MOUNTPOINT "$dev" 2>/dev/null | awk 'NF{print; exit}')"
    if [[ -n $mp && -e $mp/oma-backups/share/rescue-run.sh ]]; then
      printf '%s\n' "$mp/oma-backups"
      return 0
    fi
  done
  mkdir -p /run/oma-usb
  for dev in /dev/disk/by-label/OMARCHY-LIVE /dev/disk/by-label/OMARCHY-EFI; do
    [[ -e $dev ]] || continue
    umount /run/oma-usb 2>/dev/null || true
    if mount -o ro "$dev" /run/oma-usb 2>/dev/null; then
      if [[ -e /run/oma-usb/oma-backups/share/rescue-run.sh ]]; then
        printf '%s\n' /run/oma-usb/oma-backups
        return 0
      fi
      umount /run/oma-usb 2>/dev/null || true
    fi
  done
  return 1
}

udevadm settle -t 8 >/dev/null 2>&1 || true
sleep 1

ROOT="$(find_root || true)"
if [[ -z ${ROOT:-} ]]; then
  echo
  echo "  Could not find OmaBackups on OMARCHY-LIVE / OMARCHY-EFI."
  echo "  You are on the Omarchy live prompt (network: iwctl)."
  echo "  Try:"
  echo "    mkdir -p /run/oma-usb && mount -L OMARCHY-LIVE /run/oma-usb"
  echo "    bash /run/oma-usb/oma-backups/share/rescue-run.sh"
  echo
  exit 1
fi

export OMARCHY_TM_ROOT="$ROOT"
export OMARCHY_BACKUPS_ROOT="$ROOT"
exec bash "$ROOT/share/rescue-run.sh"
