#!/usr/bin/env bash
# Remove OmaBackups from this user account, and (after asking) the folder
# this repo was cloned into.
#
# Does NOT touch any backup USB disk.
set -euo pipefail

SRC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BINDIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/oma-backups"
PLUGIN="$HOME/.config/omarchy/plugins/oma.backups"
CFG="$HOME/.config/omarchy-backups"
STATE="$HOME/.local/state/omarchy-backups"

PURGE=0
[[ ${1:-} == --purge ]] && PURGE=1

ask() {
  if command -v gum >/dev/null 2>&1; then
    gum confirm "$1"
  else
    local reply
    read -rp "$1 [Y/n] " reply
    [[ -z $reply || $reply == [Yy]* ]]
  fi
}

# Only offer to delete something that is unmistakably this repo.
REMOVE_SRC=0
if [[ -f $SRC/install.sh && -d $SRC/plugin/oma.backups && $SRC != "$HOME" ]]; then
  ask "Also delete the source folder $SRC?" && REMOVE_SRC=1
fi

if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin disable oma.backups >/dev/null 2>&1 || true
fi

rm -f "$BINDIR/oma-backups" "$BINDIR/omarchy-backups" "$BINDIR/omarchy-tm"
rm -rf "$PLUGIN" "$SHARE" "$STATE"

if command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
fi

if [[ -f /etc/systemd/system/oma-backups-scheduled.timer || -d /usr/local/lib/oma-backups ]]; then
  echo "Removing automatic backups (needs sudo)..."
  sudo systemctl disable --now oma-backups-scheduled.timer >/dev/null 2>&1 || true
  sudo rm -f /etc/systemd/system/oma-backups-scheduled.service /etc/systemd/system/oma-backups-scheduled.timer &&
    sudo systemctl daemon-reload || true
  sudo rm -rf /usr/local/lib/oma-backups ||
    echo "  could not remove it — remove yourself: sudo rm -rf /usr/local/lib/oma-backups"
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

if [[ $REMOVE_SRC == 1 ]]; then
  cd "$HOME"
  rm -rf "$SRC"
  echo "Removed the source folder $SRC."
else
  echo "Kept the source folder $SRC."
fi

cat <<'EOF'

OmaBackups removed from this account.
Any backup USB disk was not touched (unplug it, or reformat it yourself if done).
EOF
