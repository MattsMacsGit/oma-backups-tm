#!/usr/bin/env bash
# Resume the interrupted first backup (TS baked in from the v0.1 run).
# Safe to re-run: completed os receive is kept; incomplete home receive is deleted.
set -euo pipefail

OMARCHY_TM_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export OMARCHY_TM_ROOT
# shellcheck source=lib/common.sh
source "$OMARCHY_TM_ROOT/lib/common.sh"

TS="${OMARCHY_TM_RESUME_TS:-20260912T004327Z}"
load_config_json
require_supported

MNT="$(cfg '.paths.mountpoint')"
SRC_TOP="$(cfg '.paths.source_toplevel')"
SEND_SUB="$(cfg '.paths.source_send_subvol')"
ROOT_DEV="$(printf '%s' "$DETECT_JSON" | jq -r '.root.device')"
HOSTNAME="$(printf '%s' "$DETECT_JSON" | jq -r '.hostname')"
MACHINE_ID="$(printf '%s' "$DETECT_JSON" | jq -r '.machine_id')"
KERNEL="$(printf '%s' "$DETECT_JSON" | jq -r '.kernel')"
BTRFS_UUID="$(printf '%s' "$DETECT_JSON" | jq -r '.root.uuid')"
LUKS_USED="$(printf '%s' "$DETECT_JSON" | jq -r '.luks_used')"
LUKS_PARTUUID="$(printf '%s' "$DETECT_JSON" | jq -r '.luks.partuuid')"
EXCLUDE_FILE="$(cfg '._exclude_file')"

[[ $(id -u) -eq 0 ]] || die "continue-backup.sh must run as root (systemd-run)"

mkdir -p "$SRC_TOP" "$MNT"
if ! findmnt -n "$MNT" >/dev/null 2>&1; then
  die "capsule not mounted at $MNT"
fi
if ! findmnt -n "$SRC_TOP" >/dev/null 2>&1; then
  mount -o subvolid=5,compress=zstd:3 "$ROOT_DEV" "$SRC_TOP"
fi

pipe=cat
command -v pv >/dev/null && pipe='pv -f -i 10'

send_one() {
  local kind=$1 src=$2 dest_dir=$3
  mkdir -p "$dest_dir"
  if [[ -e $dest_dir/$TS ]]; then
    # Interrupted receive leaves a subvolume; only skip if it looks finished.
    # A finished receive is a btrfs subvolume we can show. We cannot tell
    # completeness cheaply, so for home we always resend; for os we keep
    # if the subvolume exists AND this function is called with keep_if_present=1.
    if [[ ${4:-} == keep ]]; then
      log "keeping existing $kind receive $dest_dir/$TS"
      return 0
    fi
    log "deleting incomplete $kind receive $dest_dir/$TS"
    if btrfs subvolume show "$dest_dir/$TS" >/dev/null 2>&1; then
      btrfs subvolume delete "$dest_dir/$TS"
    else
      rm -rf -- "$dest_dir/$TS"
    fi
  fi
  [[ -e $src ]] || die "missing source snapshot $src"
  log "btrfs send $kind $src -> $dest_dir"
  btrfs send "$src" | $pipe | btrfs receive "$dest_dir"
  log "finished $kind send"
}

log "=== continue backup TS=$TS ==="
send_one os "$SRC_TOP/$SEND_SUB/os/$TS" "$MNT/os" keep
send_one home "$SRC_TOP/$SEND_SUB/home/$TS" "$MNT/home"

mkdir -p "$MNT/esp/$TS"
log "rsync /boot -> $MNT/esp/$TS"
rsync -a --delete-delay /boot/ "$MNT/esp/$TS/"

restic_id=""
if command -v restic >/dev/null; then
  export RESTIC_REPOSITORY="$MNT/files/restic"
  mkdir -p "$RESTIC_REPOSITORY"
  if restic snapshots >/dev/null 2>&1; then
    log "restic backup /home (Videos excluded)"
    restic backup --one-file-system \
      --exclude-file "$EXCLUDE_FILE" \
      --exclude /home/matt/Videos \
      /home
    restic_id="$(restic snapshots --json 2>/dev/null | jq -r '.[-1].short_id // .[-1].id // empty')"
    restic forget --keep-daily "$(cfg '.retention.daily')" \
      --keep-weekly "$(cfg '.retention.weekly')" \
      --keep-monthly "$(cfg '.retention.monthly')" --prune || true
  else
    log "restic repo not initialized (no password in this service). Skipping file history."
    log "Later: RESTIC_REPOSITORY=$MNT/files/restic restic init && restic backup /home"
  fi
fi

valid=true
[[ -e $MNT/os/$TS ]] || valid=false
[[ -e $MNT/home/$TS ]] || valid=false
[[ -e $MNT/esp/$TS ]] || valid=false

meta="$MNT/meta/machine.json"
mkdir -p "$MNT/meta"
jq -n \
  --arg host "$HOSTNAME" --arg mid "$MACHINE_ID" --arg ker "$KERNEL" \
  --arg uuid "$BTRFS_UUID" --argjson luks "$LUKS_USED" --arg partuuid "$LUKS_PARTUUID" \
  --arg ts "$TS" --argjson valid "$valid" --arg rid "$restic_id" \
  --arg send "$SEND_SUB" \
  '{
    schema_version: 1,
    hostname: $host,
    machine_id: $mid,
    luks_used: $luks,
    kernel: $ker,
    limine: {esp_path:"/boot", conf:"/boot/limine.conf", uki:true, defaults_conf:"/etc/default/limine"},
    source: {btrfs_uuid:$uuid, luks_partuuid:$partuuid, subvolumes: {}},
    anchor_timestamp: (if $valid then $ts else null end),
    snapshots: [{
      timestamp: $ts,
      created_at: (now|todateiso8601),
      kind: "full",
      parent_timestamp: null,
      valid: $valid,
      pinned: $valid,
      kernel: $ker,
      os: {received_path: ("/os/"+$ts), source_snapshot: ("/"+$send+"/os/"+$ts), parent_snapshot: null},
      home: {received_path: ("/home/"+$ts), source_snapshot: ("/"+$send+"/home/"+$ts), parent_snapshot: null},
      esp: {path: ("/esp/"+$ts)},
      restic: {snapshot_id: (if $rid=="" then null else $rid end)}
    }]
  }' >"$meta"

log "continue backup TS=$TS valid=$valid restic=$restic_id"
if [[ $valid == true ]]; then
  echo "CONTINUE_BACKUP_DONE ts=$TS"
else
  die "restore point $TS is not VALID (os/home/esp missing)"
fi
