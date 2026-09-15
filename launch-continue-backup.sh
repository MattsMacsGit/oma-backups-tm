#!/usr/bin/env bash
# Start continue-backup.sh as a systemd service so a closed terminal cannot kill it.
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LOG=/var/log/omarchy-tm/backup-continue.log

echo "=== omarchy-tm continue backup (systemd, survives closing this window) ==="
echo "The first run died when the terminal cgroup was torn down (34m in, ~230G written)."
echo "This resumes: keep @ send if present, redo home send, copy ESP, write machine.json."
echo "restic runs only if the repo already has a password; otherwise file history is later."
echo

sudo mkdir -p /var/log/omarchy-tm
sudo touch "$LOG"
sudo chmod 644 "$LOG"

# Drop a leftover unit from a previous attempt.
sudo systemctl stop omarchy-tm-backup.service 2>/dev/null || true
sudo systemctl reset-failed omarchy-tm-backup.service 2>/dev/null || true

echo "Starting systemd service omarchy-tm-backup. Close this window if you want — it will keep going."
sudo systemd-run --unit=omarchy-tm-backup \
  --description='omarchy-tm resume first backup' \
  --property=StandardOutput=append:"$LOG" \
  --property=StandardError=append:"$LOG" \
  --working-directory="$ROOT" \
  "$ROOT/continue-backup.sh"

echo
echo "Follow progress:"
echo "  journalctl -u omarchy-tm-backup -f"
echo "  tail -f $LOG"
echo
systemctl status omarchy-tm-backup --no-pager || true
echo
echo "Press Enter to close this helper (the backup keeps running)."
read -r || true
