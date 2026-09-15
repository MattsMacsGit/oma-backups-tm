#!/usr/bin/env bash
# One sudo prompt, then everything runs as a systemd service.
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
echo "Starting omarchy-tm-setup (live OS finish + backup). You can close this window after it prints STARTED."
sudo mkdir -p /var/log/omarchy-tm /etc/omarchy-tm
sudo chmod 700 /etc/omarchy-tm
if [[ ! -s /etc/omarchy-tm/restic.pass ]]; then
  read -r -s -p "restic password (file history): " a; echo
  read -r -s -p "confirm: " b; echo
  [[ $a == "$b" && -n $a ]] || { echo "mismatch"; exit 1; }
  printf '%s' "$a" | sudo tee /etc/omarchy-tm/restic.pass >/dev/null
  sudo chmod 600 /etc/omarchy-tm/restic.pass
  unset a b
fi
sudo systemctl stop omarchy-tm-setup.service 2>/dev/null || true
sudo systemctl reset-failed omarchy-tm-setup.service 2>/dev/null || true
sudo systemd-run --unit=omarchy-tm-setup \
  --description='omarchy-tm finish live + backup' \
  --working-directory="$ROOT" \
  "$ROOT/finish-live-then-backup.sh"
echo
echo "STARTED. Progress:"
echo "  sudo journalctl -u omarchy-tm-setup -f"
echo "  sudo tail -f /var/log/omarchy-tm/setup.log"
sleep 2
systemctl is-active omarchy-tm-setup.service
echo
echo "Press Enter to close (setup keeps running)."
read -r || true
