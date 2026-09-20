#!/usr/bin/env bash
# Update the rescue USB (OmaRescue + OMABOOT) without wiping backups.
# --boot-only: copy the Arch ISO kernel already on LIVE onto EFI.
set -euo pipefail

OMARCHY_TM_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export OMARCHY_TM_ROOT
# shellcheck source=lib/common.sh
source "$OMARCHY_TM_ROOT/lib/common.sh"
# shellcheck source=lib/install-rescue.sh
source "$OMARCHY_TM_ROOT/lib/install-rescue.sh"

BOOT_ONLY=0
ORIG_ARGS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --boot-only) BOOT_ONLY=1; shift ;;
    --dry-run) export OMARCHY_TM_DRY_RUN=1; shift ;;
    -h|--help)
      echo "Usage: oma-backups refresh-rescue [--boot-only]"
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_root "${ORIG_ARGS[@]}"

EFI_DEV="$(lsblk -n -p -o PATH,LABEL |
  awk "$(oma_label_match '$2' "${OMA_LABELS_EFI[@]}"){print \$1; exit}")"
[[ -n $EFI_DEV ]] || die "The backup USB's boot partition wasn't found — plug the backup USB in"

PK="$(lsblk -n -o PKNAME "$EFI_DEV" 2>/dev/null | head -1)"
[[ -n $PK ]] ||
  die "Couldn't work out which disk $EFI_DEV is on. Unplug the backup USB, plug it back in, and try again."
DISK="/dev/$PK"

# Both partitions have to come off the SAME disk. Looking each one up on its
# own meant that with two backup USBs plugged in, the boot partition could
# come from one and the rescue partition from the other — and the bootloader
# then went onto whichever disk owned the boot one, leaving two half-updated
# rescue USBs and no error.
LIVE_DEV="$(lsblk -n -p -o PATH,LABEL "$DISK" |
  awk "$(oma_label_match '$2' "${OMA_LABELS_LIVE[@]}"){print \$1; exit}")"
[[ -n $LIVE_DEV ]] ||
  die "$DISK has a boot partition but no rescue partition. Is this really the backup USB?"

LIVE_MNT=/run/oma-backups-live
EFI_MNT=/run/omarchy-backups-efi
mkdir -p "$LIVE_MNT" "$EFI_MNT"
if ! findmnt -n "$LIVE_MNT" >/dev/null 2>&1; then
  # LIVE may already be automounted
  already="$(lsblk -n -o MOUNTPOINT "$LIVE_DEV" | awk 'NF{print; exit}')"
  if [[ -n $already ]]; then
    mount --bind "$already" "$LIVE_MNT"
  else
    mount "$LIVE_DEV" "$LIVE_MNT"
  fi
fi
if ! findmnt -n "$EFI_MNT" >/dev/null 2>&1; then
  already="$(lsblk -n -o MOUNTPOINT "$EFI_DEV" | awk 'NF{print; exit}')"
  if [[ -n $already ]]; then
    mount --bind "$already" "$EFI_MNT"
  else
    mount "$EFI_DEV" "$EFI_MNT"
  fi
fi

if [[ $BOOT_ONLY == 1 ]]; then
  log "refresh rescue EFI from Arch ISO on LIVE"
  if [[ ! -d $LIVE_MNT/arch ]]; then
    log "LIVE has no Arch ISO yet — doing a full rescue refresh"
    install_archiso_rescue "$LIVE_MNT" "$EFI_MNT"
  else
    install_rescue_kernel "$LIVE_MNT" "$EFI_MNT"
  fi
  install_rescue_limine "$DISK" "$EFI_MNT"
else
  log "refresh rescue Arch ISO + restore wizard"
  install_archiso_rescue "$LIVE_MNT" "$EFI_MNT"
  install_rescue_limine "$DISK" "$EFI_MNT"
fi

sync
umount "$EFI_MNT" || true
umount "$LIVE_MNT" || true
log "rescue USB updated"
