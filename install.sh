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
if [[ ! -f $CFG/skip-paths.txt ]]; then
  cat >"$CFG/skip-paths.txt" <<'EOF'
# OmaBackups skip list — one absolute path per line
# Example: /home/you/Videos
EOF
fi

"$SHARE/omarchy-backups" compile-excludes >/dev/null 2>&1 || true

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
Full restore: firmware-boot that USB (Limine entry “OmaBackups Restore”).

Optional (hides the sudo terminal; uses polkit instead):
  sudo $SHARE/install-polkit.sh
EOF
