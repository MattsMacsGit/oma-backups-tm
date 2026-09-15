#!/usr/bin/env bash
# One sudo: install config (Videos + ollama), bind-mount dest, start systemd backup.
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
UNIT=omarchy-backups
LOG=/var/log/omarchy-backups/backup.log

echo "=== OmarchyBackups test (exclude Videos + ollama) ==="
sudo mkdir -p /etc/omarchy-backups /var/log/omarchy-backups /run/omarchy-backups
sudo cp "$ROOT/share/excludes-home.txt" /etc/omarchy-backups/excludes-home.txt
sudo cp "$ROOT/share/excludes-os.txt" /etc/omarchy-backups/excludes-os.txt
sudo chmod 644 /etc/omarchy-backups/excludes-*.txt
echo "home excludes:"
grep -v '^#' /etc/omarchy-backups/excludes-home.txt | grep -v '^$'
echo "os excludes:"
grep -v '^#' /etc/omarchy-backups/excludes-os.txt | grep -v '^$'

if findmnt -n /run/media/test/OMARCHY-TM >/dev/null 2>&1; then
  echo "Using already-unlocked dest at /run/media/test/OMARCHY-TM"
  sudo mount --bind /run/media/test/OMARCHY-TM /run/omarchy-backups
else
  sudo "$ROOT/omarchy-backups" mount --disk /dev/sdb
fi

echo
echo "Dry-run of excludes:"
sudo --preserve-env=OMARCHY_TM_ROOT \
  env SUDO_USER=test HOME=/home/test OMARCHY_TM_ROOT="$ROOT" OMARCHY_TM_DRY_RUN=1 \
  "$ROOT/omarchy-backups" backup --dry-run | grep -E 'exclude|Videos|ollama|rsync'

echo
echo "Starting $UNIT (close this window; job keeps running)."
sudo systemctl stop "$UNIT".service 2>/dev/null || true
sudo systemctl reset-failed "$UNIT".service 2>/dev/null || true
sudo systemd-run --unit="$UNIT" \
  --description='OmarchyBackups rsync test' \
  --property=Environment=SUDO_USER=test \
  --property=Environment=HOME=/home/test \
  --property=Environment=OMARCHY_TM_ROOT="$ROOT" \
  --property=Environment=OMARCHY_TM_YES=1 \
  --working-directory="$ROOT" \
  "$ROOT/omarchy-backups" backup --yes

echo "STARTED.  journalctl -u $UNIT -f"
sleep 1
systemctl is-active "$UNIT".service
echo "Enter to close viewer (backup continues)."
sudo journalctl -u "$UNIT" -f || true
