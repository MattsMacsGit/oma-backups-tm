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
LIVE_DEV="$(lsblk -n -p -o PATH,LABEL |
  awk "$(oma_label_match '$2' "${OMA_LABELS_LIVE[@]}"){print \$1; exit}")"
[[ -n $EFI_DEV ]] || die "The backup USB's boot partition wasn't found — plug the backup USB in"
[[ -n $LIVE_DEV ]] || die "The backup USB's rescue partition wasn't found — plug the backup USB in"

DISK="/dev/$(lsblk -n -o PKNAME "$EFI_DEV" | head -1)"

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
