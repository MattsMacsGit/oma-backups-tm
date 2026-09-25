#!/usr/bin/env bash
# Install OmaBackups for this user on any Omarchy machine.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export OMARCHY_TM_ROOT="$ROOT"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

BINDIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/oma-backups"
PLUGIN="$HOME/.config/omarchy/plugins/oma.backups"
CFG="$HOME/.config/omarchy-backups"

mkdir -p "$BINDIR" "$CFG" "$(dirname "$PLUGIN")" "$(dirname "$SHARE")"

echo "Checking dependencies..."
ensure_deps rsync btrfs cryptsetup mkfs.fat mkfs.ext4 sgdisk curl \
  unsquashfs mksquashfs jq lsblk wipefs sfdisk

COPY=0
[[ ${1:-} == --copy ]] && COPY=1

if [[ $COPY == 1 ]]; then
  mkdir -p "$SHARE"
  rsync -a --delete \
    --exclude '.git/' --exclude '__pycache__/' --exclude '*.pyc' \
    "$ROOT/" "$SHARE/"
else
  # ln -sfn onto a real directory (left by --copy) nests the link inside it
  # and keeps serving the stale copy, so clear it first.
  [[ -d $SHARE && ! -L $SHARE ]] && rm -rf "$SHARE"
  ln -sfn "$ROOT" "$SHARE"
fi

ln -sfn "$SHARE/omarchy-backups" "$BINDIR/oma-backups"
ln -sfn "$SHARE/omarchy-backups" "$BINDIR/omarchy-backups"
ln -sfn "$SHARE/omarchy-backups" "$BINDIR/omarchy-tm"

# Plugin folder cannot be a symlink (omarchy plugin validate). Copy files.
rm -rf "$PLUGIN"
mkdir -p "$PLUGIN"
rsync -a "$ROOT/plugin/oma.backups/" "$PLUGIN/"

printf '%s\n' "$SHARE" >"$CFG/root"
# Nothing is skipped to begin with. The recommended quick-skips (Trash,
# caches, thumbnails) are seeded as switches the first time the panel opens,
# and every one of them can be turned off — see lib/skip_defaults.py.
if [[ ! -f $CFG/skip-paths.txt ]]; then
  printf '%s\n' "# OmaBackups skip list — one entry per line" >"$CFG/skip-paths.txt"
fi

"$SHARE/omarchy-backups" compile-excludes >/dev/null 2>&1 || true

# Plugging the backup disk in shouldn't pop up a password window: OmaBackups
# unlocks it itself. See lib/udiskie-rule.sh.
"$ROOT/lib/udiskie-rule.sh" install || true

# Password-free and automatic backups run from a root-owned copy; bring it
# up to date with this install.
if [[ -f /etc/omarchy-backups/linked.json ]]; then
  echo "Updating the linked backup services (needs sudo)..."
  # Spelled out in full, and with sudo. `sudo oma-backups` only works once a
  # refresh has been through -- that is what puts the name on root's PATH --
  # so telling someone whose refresh just failed to run it that way sends them
  # straight into "sudo: oma-backups: command not found".
  sudo "$SHARE/omarchy-backups" link --refresh ||
    echo "  couldn't update them; run: sudo $SHARE/omarchy-backups link --refresh"
fi

if command -v omarchy >/dev/null; then
  omarchy plugin validate "$PLUGIN" || true
fi
if command -v omarchy-shell >/dev/null; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
fi
if command -v omarchy >/dev/null; then
  omarchy plugin enable oma.backups || true
fi

case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) echo "Note: add $BINDIR to PATH if 'oma-backups' is not found." ;;
esac

cat <<EOF
OmaBackups installed.

  Bar:     OmaBackups icon on the right (disk). Do not run: omarchy refresh shell
  CLI:     $BINDIR/oma-backups
  Files:   $SHARE
  Skips:   $CFG/skip-paths.txt

Open the bar icon. Plug in a USB disk. The panel walks you through setup.
Full restore: firmware-boot that USB (Limine entry “Rescue Disk”).
EOF
