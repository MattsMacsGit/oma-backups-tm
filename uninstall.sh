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

# Settings (the skip list) are removed unless you say otherwise, so that
# reinstalling really does give you a fresh start: a folder skipped on the old
# install used to come back on the new one, with nothing to say why.
PURGE=0
KEEP=0
case "${1:-}" in
  --purge) PURGE=1 ;;
  --keep-settings) KEEP=1 ;;
esac

ask() {
  if command -v gum >/dev/null 2>&1; then
    gum confirm "$1"
  else
    local reply=""
    # No terminal (piped into bash): take the default rather than dying.
    read -rp "$1 [Y/n] " reply || true
    [[ -z $reply || $reply == [Yy]* ]]
  fi
}

if [[ $PURGE == 0 && $KEEP == 0 && -d $CFG ]]; then
  ask "Also delete your settings (the skip list) in $CFG?" && PURGE=1
fi

# Only offer to delete something that is unmistakably this repo.
REMOVE_SRC=0
if [[ -f $SRC/install.sh && -d $SRC/plugin/oma.backups && $SRC != "$HOME" ]]; then
  ask "Also delete the source folder $SRC?" && REMOVE_SRC=1
fi

if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin disable oma.backups >/dev/null 2>&1 || true
fi

"$SRC/lib/udiskie-rule.sh" remove || true

rm -f "$BINDIR/oma-backups" "$BINDIR/omarchy-backups" "$BINDIR/omarchy-tm"
rm -rf "$PLUGIN" "$SHARE" "$STATE"

if command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
fi

if compgen -G "/etc/systemd/system/oma-backups-*" >/dev/null || [[ -d /usr/local/lib/oma-backups ]]; then
  echo "Removing the backup services (needs sudo)..."
  sudo systemctl disable --now oma-backups-scheduled.timer >/dev/null 2>&1 || true
  sudo systemctl stop 'oma-backups-browse@*.service' >/dev/null 2>&1 || true
  sudo rm -f /etc/systemd/system/oma-backups-* /etc/polkit-1/rules.d/50-oma-backups.rules &&
    sudo systemctl daemon-reload || true
  if [[ -f /etc/udev/rules.d/99-oma-backups.rules ]]; then
    sudo rm -f /etc/udev/rules.d/99-oma-backups.rules &&
      sudo udevadm control --reload >/dev/null 2>&1 || true
  fi
  # Only our own links, and only if that is still what they are.
  for n in /usr/local/bin/oma-backups /usr/local/bin/omarchy-backups; do
    [[ -L $n && $(readlink -f "$n") == /usr/local/lib/oma-backups/* ]] && sudo rm -f "$n"
  done
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
  echo "Removed your settings (skip list, etc). A reinstall starts fresh."
else
  echo "Kept your settings at $CFG (skip list, etc)."
  echo "A reinstall will pick them up again, including anything you skipped."
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
