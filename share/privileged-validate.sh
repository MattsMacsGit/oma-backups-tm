#!/usr/bin/env bash
# Root steps on the testrig. Never touches nvme0n1. Never formats sdc.
set -euo pipefail
export OMARCHY_TM_ROOT="${OMARCHY_TM_ROOT:-/home/test/Work/omarchy-tm}"
CLI="$OMARCHY_TM_ROOT/omarchy-backups"
LOG=/tmp/oma-privileged-validate.log
exec > >(tee "$LOG") 2>&1

echo "== OmaBackups privileged validate $(date -u +%FT%TZ) =="
echo "user=$USER SUDO_USER=${SUDO_USER:-} HOME=$HOME"
[[ $(id -u) -eq 0 ]] || { echo "need root"; exit 1; }
[[ ${SUDO_USER:-} == test ]] || echo "WARNING: SUDO_USER is '${SUDO_USER:-}' (skip list uses this home)"

"$CLI" compile-excludes
"$OMARCHY_TM_ROOT/lib/progress.py" idle
chmod 644 /etc/omarchy-backups/*.txt /etc/omarchy-backups/config.toml 2>/dev/null || true

echo "-- mount --"
"$CLI" mount

echo "-- doctor before --"
"$CLI" doctor || true

echo "-- refresh rescue USB (no wipe) --"
"$CLI" refresh-rescue

echo "-- restore dry-run live root --"
if "$CLI" --dry-run restore-to-disk /dev/sda --snapshot 20260912T053938Z; then
  echo "FAIL: live root dry-run should refuse"; exit 1
else
  echo "OK live root refused"
fi

echo "-- restore dry-run nvme without allow --"
if "$CLI" --dry-run restore-to-disk /dev/nvme0n1 --snapshot 20260912T053938Z; then
  echo "FAIL: nvme dry-run should refuse"; exit 1
else
  echo "OK nvme refused without --allow-internal"
fi

echo "-- restore dry-run nvme with allow (must not write) --"
"$CLI" --dry-run restore-to-disk /dev/nvme0n1 --snapshot 20260912T053938Z --allow-internal

echo "-- home-only backup (Pictures must land; Videos must not) --"
"$CLI" backup --yes --home-only

echo "-- doctor after --"
"$CLI" doctor

echo "-- snapshots --"
"$CLI" snapshots

echo "-- status --"
"$CLI" status

echo "== privileged validate done =="
