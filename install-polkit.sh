#!/usr/bin/env bash
# System-wide pkexec helper so backups do not need a visible terminal.
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

mkdir -p /usr/lib/oma-backups
rsync -a --delete \
  --exclude '.git/' --exclude '__pycache__/' --exclude '*.pyc' \
  --exclude 'plugin/omarchy.omabackups/' \
  "$ROOT/" /usr/lib/oma-backups/
install -m 0755 "$ROOT/lib/pkexec-wrapper.sh" /usr/lib/oma-backups/pkexec-wrapper.sh
install -m 0644 "$ROOT/share/polkit/org.omarchy.backups.policy" \
  /usr/share/polkit-1/actions/org.omarchy.backups.policy
ln -sfn /usr/lib/oma-backups/omarchy-backups /usr/local/bin/oma-backups
echo "polkit helper installed: pkexec /usr/lib/oma-backups/pkexec-wrapper.sh"
echo "In the bar panel, turn off “Show backup terminal”."
