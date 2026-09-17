#!/usr/bin/env bash
# Remove OmaBackups from this user account.
#
# Does NOT touch: any backup USB disk, or the folder you cloned this repo
# into (delete that yourself if you're done with it).
set -euo pipefail

BINDIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/oma-backups"
PLUGIN="$HOME/.config/omarchy/plugins/oma.backups"
CFG="$HOME/.config/omarchy-backups"
STATE="$HOME/.local/state/omarchy-backups"

PURGE=0
[[ ${1:-} == --purge ]] && PURGE=1

if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin disable oma.backups >/dev/null 2>&1 || true
fi

rm -f "$BINDIR/oma-backups" "$BINDIR/omarchy-backups" "$BINDIR/omarchy-tm"
rm -rf "$PLUGIN" "$SHARE" "$STATE"

if command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
fi

if [[ -d /etc/omarchy-backups ]]; then
  echo "Removing /etc/omarchy-backups (needs sudo)..."
  sudo rm -rf /etc/omarchy-backups ||
    echo "  could not remove it — remove yourself: sudo rm -rf /etc/omarchy-backups"
fi
if [[ -d /var/log/omarchy-backups ]]; then
  sudo rm -rf /var/log/omarchy-backups 2>/dev/null ||
    echo "  could not remove /var/log/omarchy-backups — remove yourself: sudo rm -rf /var/log/omarchy-backups"
fi

if [[ $PURGE == 1 ]]; then
  rm -rf "$CFG"
  echo "Removed your settings too (skip list, etc — ran with --purge)."
else
  echo "Kept your settings at $CFG (skip list, etc)."
  echo "Re-run with --purge to remove those too."
fi

cat <<'EOF'

OmaBackups removed from this account.

Not touched:
  - Any backup USB disk (unplug it, or wipe/reformat it yourself if done)
  - The folder you cloned this repo into (rm -rf it yourself if done)
EOF
