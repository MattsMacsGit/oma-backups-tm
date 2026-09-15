#!/usr/bin/env bash
# pkexec entry: restore SUDO_USER/HOME so skip-paths are the desktop user's.
set -euo pipefail
if [[ -z ${PKEXEC_UID:-} ]]; then
  echo "oma-backups: pkexec wrapper must be run via pkexec" >&2
  exit 1
fi
USER_NAME="$(id -nu "$PKEXEC_UID")"
export SUDO_USER="$USER_NAME"
export HOME
HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
if [[ -x /usr/lib/oma-backups/omarchy-backups ]]; then
  ROOT=/usr/lib/oma-backups
fi
export OMARCHY_TM_ROOT="$ROOT" OMARCHY_BACKUPS_ROOT="$ROOT"
exec "$ROOT/omarchy-backups" "$@"
