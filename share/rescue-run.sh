#!/usr/bin/env bash
# Started by official Arch ISO automated_script (kernel cmdline script=).
# Finds the backup USB, puts oma-backups on PATH, runs the restore wizard.
set -euo pipefail

find_root() {
  local d
  for d in \
    /run/archiso/bootmnt/oma-backups \
    /run/archiso/copytoram/oma-backups \
    /run/archiso/img_dev/oma-backups
  do
    if [[ -x $d/omarchy-backups ]]; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  # Extracted ISO: LIVE is labeled OMARCHY-LIVE
  local mp
  mp="$(lsblk -n -o LABEL,MOUNTPOINT 2>/dev/null | awk '($1=="OMARCHY-LIVE" || $1=="OMANET-LIVE") && $2!=""{print $2; exit}')"
  if [[ -n $mp && -x $mp/oma-backups/omarchy-backups ]]; then
    printf '%s\n' "$mp/oma-backups"
    return 0
  fi
  mkdir -p /run/oma-live
  if mountpoint -q /run/oma-live || mount -L OMARCHY-LIVE /run/oma-live 2>/dev/null ||
    mount -L OMANET-LIVE /run/oma-live 2>/dev/null; then
    if [[ -x /run/oma-live/oma-backups/omarchy-backups ]]; then
      printf '%s\n' /run/oma-live/oma-backups
      return 0
    fi
  fi
  return 1
}

# Marker so oma-backups treats this as rescue (not an Omarchy install).
touch /etc/oma-backups-rescue 2>/dev/null || true

timeout 20 systemctl is-system-running --wait >/dev/null 2>&1 || true

ROOT="$(find_root || true)"
if [[ -z ${ROOT:-} ]]; then
  echo "OmaBackups scripts not found on this USB."
  echo "Mount the OMARCHY-LIVE partition and run:"
  echo "  python3 /path/to/oma-backups/lib/restore_tui.py"
  exit 1
fi

export OMARCHY_TM_ROOT="$ROOT"
export OMARCHY_BACKUPS_ROOT="$ROOT"
export PATH="$ROOT/../oma-extra/usr/bin:$ROOT:$PATH"

if [[ -f $ROOT/etc-omarchy-backups/config.toml ]]; then
  mkdir -p /etc/omarchy-backups
  cp "$ROOT/etc-omarchy-backups/config.toml" /etc/omarchy-backups/config.toml
fi

ln -sfn "$ROOT/omarchy-backups" /usr/local/bin/oma-backups 2>/dev/null || true
ln -sfn "$ROOT/omarchy-backups" /usr/local/bin/omarchy-backups 2>/dev/null || true

cd /
if command -v python3 >/dev/null && command -v gum >/dev/null; then
  python3 "$ROOT/lib/restore_tui.py" || true
else
  command -v python3 >/dev/null || echo "python3 is missing on this live image."
  command -v gum >/dev/null || echo "gum is missing on this live image (the wizard needs it)."
  echo "  oma-backups restore-to-disk /dev/TARGET --snapshot TIMESTAMP --allow-internal"
fi
