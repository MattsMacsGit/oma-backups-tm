# shellcheck shell=bash
# Shared helpers for oma-backups. Source from every command script.

[[ -n ${OMARCHY_TM_COMMON_LOADED:-} ]] && return 0
OMARCHY_TM_COMMON_LOADED=1

set -euo pipefail

if [[ -z ${OMARCHY_TM_ROOT:-} ]]; then
  OMARCHY_TM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

OMARCHY_TM_PYTHON="${OMARCHY_TM_PYTHON:-/usr/bin/python3}"
if [[ ! -x $OMARCHY_TM_PYTHON ]]; then
  OMARCHY_TM_PYTHON="$(command -v python3)"
fi

umask 077

_tm_user_home() {
  if [[ ${EUID:-$(id -u)} -eq 0 && -n ${SUDO_USER:-} ]]; then
    getent passwd "$SUDO_USER" | cut -d: -f6
  else
    printf '%s\n' "${HOME:-/tmp}"
  fi
}

OMARCHY_TM_USER_HOME="$(_tm_user_home)"
OMARCHY_TM_STATE="${OMARCHY_TM_STATE:-$OMARCHY_TM_USER_HOME/.local/state/omarchy-backups}"
mkdir -p "$OMARCHY_TM_STATE"

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  OMARCHY_TM_LOG_DIR="${OMARCHY_TM_LOG_DIR:-/var/log/omarchy-backups}"
  mkdir -p "$OMARCHY_TM_LOG_DIR" 2>/dev/null || OMARCHY_TM_LOG_DIR="$OMARCHY_TM_STATE"
else
  OMARCHY_TM_LOG_DIR="$OMARCHY_TM_STATE"
fi
OMARCHY_TM_LOG="${OMARCHY_TM_LOG:-$OMARCHY_TM_LOG_DIR/oma-backups.log}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log() {
  local line
  line="$(ts) $*"
  mkdir -p "$(dirname "$OMARCHY_TM_LOG")"
  printf '%s\n' "$line" >>"$OMARCHY_TM_LOG" || true
  printf '%s\n' "$*"
}

log_err() {
  local line
  line="$(ts) ERROR $*"
  printf '%s\n' "$line" >>"$OMARCHY_TM_LOG" || true
  printf 'oma-backups: %s\n' "$*" >&2
}

die() {
  log_err "$*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

mnt_is_ro() {
  local opts
  opts="$(findmnt -n -o OPTIONS "$1" 2>/dev/null || true)"
  [[ $opts =~ (^|,)ro(,|$) ]]
}

mapper_is_stale() {
  local m=$1 dev
  [[ -e /dev/mapper/$m ]] || return 0
  dev="$(cryptsetup status "$m" 2>/dev/null | awk '/^ *device:/{print $2}')"
  [[ -z $dev || $dev == "(null)" || ! -b $dev ]]
}

close_stale_mapper() {
  local m=$1
  if [[ -e /dev/mapper/$m ]] && mapper_is_stale "$m"; then
    log "closing stale mapper $m (USB re-enumerated)"
    umount -R /run/omarchy-backups 2>/dev/null || umount -l /run/omarchy-backups 2>/dev/null || true
    cryptsetup close "$m" 2>/dev/null || dmsetup remove -f "$m" 2>/dev/null || true
  fi
}

backup_mapper() {
  local src mapper
  src="$(findmnt -n -o SOURCE "${1:-}" 2>/dev/null | awk '{print $1; exit}' || true)"
  if [[ $src == /dev/mapper/* ]]; then
    mapper="${src#/dev/mapper/}"
    mapper="${mapper%%\[*}"
    printf '%s\n' "$mapper"
    return 0
  fi
  if [[ -e /dev/mapper/omarchy-backups ]]; then
    printf '%s\n' omarchy-backups
    return 0
  fi
  lsblk -nr -o NAME,TYPE 2>/dev/null | awk '$2=="crypt" && $1!="root"{print $1; exit}'
}

mount_backup_rw() {
  local mnt=$1
  local mapper=$2
  mkdir -p "$mnt"
  if mount -o rw,compress=zstd:3 "/dev/mapper/$mapper" "$mnt" 2>/dev/null; then
    :
  elif mount -o rw "/dev/mapper/$mapper" "$mnt"; then
    :
  else
    die "could not mount /dev/mapper/$mapper read-write on $mnt"
  fi
  if mnt_is_ro "$mnt"; then
    die "backup disk is still read-only"
  fi
  log "backup disk mounted read-write at $mnt ($(findmnt -n -o OPTIONS "$mnt"))"
}

ensure_rw_mount() {
  local mnt=$1
  local mapper
  mapper="$(backup_mapper "$mnt")"
  if findmnt -n "$mnt" >/dev/null 2>&1; then
    if ! mnt_is_ro "$mnt"; then
      return 0
    fi
    log "backup disk is read-only — replacing that mount with a read-write one"
    umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
  fi
  [[ -n $mapper && -e /dev/mapper/$mapper ]] || \
    die "backup disk is not unlocked. Open it in Files, enter the password, then Backup now again."
  mount_backup_rw "$mnt" "$mapper"
}

is_dry_run() {
  [[ ${OMARCHY_TM_DRY_RUN:-0} == 1 ]]
}

run() {
  # run CMD... — prints and optionally executes
  if is_dry_run; then
    printf '[dry-run] %s\n' "$*"
    log "[dry-run] $*"
    return 0
  fi
  log "+ $*"
  "$@"
}

run_sh() {
  # run_sh 'pipeline...'
  if is_dry_run; then
    printf '[dry-run] %s\n' "$*"
    log "[dry-run] $*"
    return 0
  fi
  log "+ $*"
  bash -c "$*"
}

load_config_json() {
  OMARCHY_TM_CONFIG_JSON="$("$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/load_config.py")"
}

cfg() {
  # cfg '.paths.mountpoint'
  printf '%s\n' "$OMARCHY_TM_CONFIG_JSON" | jq -r "$1"
}

detect_json() {
  "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/detect.py" --json
}

require_supported() {
  local json rc=0
  json="$(detect_json)" || rc=$?
  DETECT_JSON="$json"
  if is_rescue; then
    # Rescue USB is ext4, not Omarchy. Restore/mount still need disk listing.
    [[ -n $DETECT_JSON ]] || DETECT_JSON='{"supported":false,"disks":[],"live_root_disk":null,"hostname":"oma-backups-rescue"}'
    return 0
  fi
  if [[ $rc -eq 2 ]]; then
    die "this machine is not an Omarchy-like btrfs @ + @home system (see: oma-backups detect)"
  fi
  if [[ $rc -ne 0 ]]; then
    die "detect failed (exit $rc)"
  fi
}

# Re-exec with sudo when a terminal can prompt. Never for detect.
require_root() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    return 0
  fi
  if [[ ${OMARCHY_TM_DRY_RUN:-0} == 1 && ${OMARCHY_TM_ALLOW_USER_DRY_RUN:-1} == 1 ]]; then
    return 0
  fi
  if [[ -t 0 && -t 1 ]]; then
    log "re-executing with sudo"
    exec sudo --preserve-env=OMARCHY_TM_ROOT,OMARCHY_BACKUPS_ROOT,OMARCHY_TM_DRY_RUN,OMARCHY_TM_YES,OMARCHY_TM_FORCE,OMARCHY_TM_PYTHON,OMARCHY_TM_ALLOW_INTERNAL,OMARCHY_TM_HOME_ONLY,OMARCHY_TM_PASSPHRASE_FD \
      "$0" "$@"
  fi
  die "this command needs root; run it in a terminal so sudo can prompt"
}

confirm() {
  local prompt=$1
  if [[ ${OMARCHY_TM_YES:-0} == 1 ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "refusing non-interactive run without --yes: $prompt"
  fi
  local ans
  read -r -p "$prompt [type YES]: " ans
  [[ $ans == YES ]] || die "aborted"
}

real_dev() {
  readlink -f "$1"
}

partition_path() {
  # partition_path /dev/sdb 1 -> /dev/sdb1 ; /dev/nvme0n1 1 -> /dev/nvme0n1p1
  local disk=$1 n=$2
  if [[ $disk =~ [0-9]$ ]]; then
    printf '%s\n' "${disk}p${n}"
  else
    printf '%s\n' "${disk}${n}"
  fi
}

is_whole_disk() {
  local p=$1
  [[ -b $p ]] || return 1
  local type
  type="$(lsblk -n -d -o TYPE "$p" 2>/dev/null || true)"
  [[ $type == disk ]]
}

live_root_disk() {
  printf '%s\n' "$(printf '%s' "${DETECT_JSON:-}" | jq -r '.live_root_disk // empty')"
}

disk_protected_reason() {
  local want=$1
  local want_real
  want_real="$(real_dev "$want")"
  printf '%s' "${DETECT_JSON:-}" | jq -r --arg p "$want" --arg r "$want_real" '
    .disks[] | select(.path == $p or .path == $r) | .protected_reason // empty
  '
}

# Close every crypt mapper and unmount every filesystem on a whole disk.
# Format used to remake EFI+LIVE while LUKS stayed open (old UUID c7c9b00d).
_part_holders() {
  local part=$1 base
  base="${part##*/}"
  ls "/sys/class/block/$base/holders" 2>/dev/null || true
}

close_crypt_on_disk() {
  local disk=$1
  local i name mp part holder
  disk="$(real_dev "$disk")"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    while read -r mp; do
      [[ -z $mp ]] && continue
      case "$mp" in
        /|/boot|/home) die "REFUSING to unmount $mp while closing $disk" ;;
      esac
      umount -R "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
      if command -v udisksctl >/dev/null; then
        udisksctl unmount -b "$(findmnt -n -o SOURCE "$mp" 2>/dev/null)" >/dev/null 2>&1 || true
      fi
    done < <(lsblk -nr -o MOUNTPOINTS "$disk" 2>/dev/null | awk 'NF')

    while read -r part; do
      [[ -z $part ]] && continue
      if command -v udisksctl >/dev/null; then
        udisksctl unmount -b "$part" >/dev/null 2>&1 || true
        udisksctl lock -b "$part" >/dev/null 2>&1 || true
      fi
      while read -r holder; do
        [[ -z $holder ]] && continue
        log "force-removing holder $holder"
        dmsetup remove -f "$holder" 2>/dev/null || cryptsetup close "$holder" 2>/dev/null || true
      done < <(_part_holders "$part")
    done < <(lsblk -nr -p -o NAME,TYPE "$disk" 2>/dev/null | awk '$2=="part"{print $1}')

    while read -r name; do
      name="${name##*/}"
      name="${name//[^a-zA-Z0-9._-]/}"
      [[ -z $name ]] && continue
      log "closing mapper $name"
      cryptsetup close "$name" 2>/dev/null || dmsetup remove -f "$name" 2>/dev/null || true
    done < <(lsblk -nr -o NAME,TYPE "$disk" 2>/dev/null | awk '$2=="crypt"{print $1}')

    cryptsetup close omarchy-backups 2>/dev/null || true
    cryptsetup close omarchy-tm 2>/dev/null || true
    dmsetup remove -f omarchy-backups 2>/dev/null || true

    if ! lsblk -nr -o TYPE "$disk" 2>/dev/null | grep -qx crypt; then
      return 0
    fi
    sleep 0.5
  done
  die "could not close LUKS on $disk — eject the disk in Files, unplug it, plug it back in, and try again. Refusing to format while the old volume is still unlocked."
}

luks_uuid_of() {
  cryptsetup luksUUID "$1" 2>/dev/null || true
}

wipe_luks_header() {
  local part=$1
  [[ -b $part ]] || return 0
  wipefs -a "$part" >/dev/null 2>&1 || true
  dd if=/dev/zero of="$part" bs=1M count=32 status=none conv=fsync 2>/dev/null || \
    dd if=/dev/zero of="$part" bs=1M count=32 2>/dev/null || true
}

refuse_dangerous_disk() {
  local disk=$1 action=$2
  [[ -b $disk ]] || die "not a block device: $disk"
  is_whole_disk "$disk" || die "$disk is not a whole disk (pass /dev/sdX or /dev/nvmeXn1, not a partition)"

  local live live_real disk_real
  live="$(live_root_disk)"
  disk_real="$(real_dev "$disk")"
  if [[ -n $live ]]; then
    live_real="$(real_dev "$live")"
    if [[ $disk_real == "$live_real" ]]; then
      die "REFUSING to $action $disk — that is the live root disk ($live)"
    fi
  fi

  # Never operate on the disk that holds / or /boot even if detect missed it.
  local src pk
  src="$(findmnt -n -o SOURCE /boot 2>/dev/null || true)"
  if [[ -n $src ]]; then
    pk="$(lsblk -n -o PKNAME "$src" 2>/dev/null | head -1)"
    if [[ -n $pk && $(real_dev "/dev/$pk") == "$disk_real" ]]; then
      die "REFUSING to $action $disk — it holds /boot"
    fi
  fi
  src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  if [[ -n $src ]]; then
    local walker=$src
    local i
    for i in 1 2 3 4; do
      pk="$(lsblk -n -d -o PKNAME "$walker" 2>/dev/null | head -1 || true)"
      [[ -n $pk ]] || break
      if [[ $(real_dev "/dev/$pk") == "$disk_real" ]]; then
        die "REFUSING to $action $disk — it backs the live root ($src)"
      fi
      walker="/dev/$pk"
    done
  fi

  local reason
  reason="$(disk_protected_reason "$disk")"
  if [[ -n $reason ]]; then
    # Rescue restore: the user picks any disk (including Ventoy). Format from
    # a running desktop still refuses installer sticks.
    if [[ $action == "restore onto" && $reason == installer\ disk* ]]; then
      log "installer disk $disk allowed for restore ($reason)"
    else
      die "REFUSING to $action $disk — $reason"
    fi
  fi
}

status_write() {
  log "$*"
}

progress() {
  "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/progress.py" "$@" || true
}

now_timestamp() {
  date -u +%Y%m%dT%H%M%SZ
}

is_rescue() {
  [[ -f /etc/oma-backups-rescue ]] || [[ -f /etc/omarchy-backups-rescue ]]
}

# LUKS partition that shares a disk with OMARCHY-EFI / OMARCHY-LIVE.
# On rescue that disk IS the live root — still the backup we need to unlock.
capsule_luks_partition() {
  local efi_dev live_dev disk
  efi_dev="$(lsblk -n -p -o PATH,LABEL 2>/dev/null | awk '$2=="OMARCHY-EFI"{print $1; exit}')"
  live_dev="$(lsblk -n -p -o PATH,LABEL 2>/dev/null | awk '$2=="OMARCHY-LIVE"{print $1; exit}')"
  disk=""
  if [[ -n ${efi_dev:-} ]]; then
    disk="$(lsblk -n -o PKNAME "$efi_dev" 2>/dev/null | head -1 || true)"
  fi
  if [[ -z $disk && -n ${live_dev:-} ]]; then
    disk="$(lsblk -n -o PKNAME "$live_dev" 2>/dev/null | head -1 || true)"
  fi
  [[ -n $disk ]] || return 1
  lsblk -n -p -o PATH,FSTYPE "/dev/$disk" 2>/dev/null | awk '$2=="crypto_LUKS"{print $1; exit}'
}

pid_file() {
  printf '%s\n' "${OMARCHY_TM_PID_FILE:-/run/omarchy-backups.pid}"
}

pid_alive() {
  local pid=${1:-}
  [[ -n $pid && $pid =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

write_pid() {
  local f
  f="$(pid_file)"
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$$" >"$f"
  chmod 644 "$f" 2>/dev/null || true
}

clear_pid() {
  rm -f "$(pid_file)"
}

kill_tree() {
  local p=$1 c
  [[ -n $p ]] || return 0
  for c in $(pgrep -P "$p" 2>/dev/null || true); do
    kill_tree "$c"
  done
  kill -TERM "$p" 2>/dev/null || true
}

stop_backup() {
  local f pid
  f="$(pid_file)"
  if [[ ! -f $f ]]; then
    progress idle
    log "no backup running"
    return 0
  fi
  pid="$(tr -d '[:space:]' <"$f")"
  if pid_alive "$pid"; then
    log "stopping backup pid $pid"
    kill_tree "$pid"
    sleep 1
    if pid_alive "$pid"; then
      kill -KILL "$pid" 2>/dev/null || true
      kill_tree "$pid"
    fi
  fi
  clear_pid
  progress idle
  log "stopped"
}

status_json() {
  local f="${OMARCHY_TM_STATUS_FILE:-/run/omarchy-backups.status}"
  local pidf pid raw
  pidf="$(pid_file)"
  pid=""
  [[ -f $pidf ]] && pid="$(tr -d '[:space:]' <"$pidf")"
  if [[ -f $f ]]; then
    raw="$(cat "$f" 2>/dev/null || true)"
  else
    raw='{"running":false,"phase":"idle","percent":0,"speed":"","eta":"","line":""}'
  fi
  if printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    if [[ -n $pid ]] && pid_alive "$pid"; then
      printf '%s\n' "$raw" | jq -c --arg pid "$pid" '.pid=$pid | .stale=false'
      return 0
    fi
    printf '%s\n' "$raw" | jq -c '.running=false | .stale=true | .pid=null'
    return 0
  fi
  if [[ -n $pid ]] && pid_alive "$pid"; then
    jq -n -c --arg line "$raw" --arg pid "$pid" \
      '{running:true, phase:"unknown", percent:0, speed:"", eta:"", line:$line, pid:$pid, stale:false}'
  else
    jq -n -c --arg line "$raw" \
      '{running:false, phase:"idle", percent:0, speed:"", eta:"", line:$line, stale:true}'
  fi
}

disk_tran() {
  lsblk -n -d -o TRAN "$1" 2>/dev/null | head -1 | tr '[:upper:]' '[:lower:]'
}

require_usb_or_allow() {
  local disk=$1 action=$2
  local tran
  tran="$(disk_tran "$disk")"
  if [[ $tran == usb || $tran == mmc ]]; then
    return 0
  fi
  if is_rescue; then
    return 0
  fi
  if [[ ${OMARCHY_TM_ALLOW_INTERNAL:-0} == 1 ]]; then
    log "allowing internal disk $disk ($tran) because --allow-internal"
    return 0
  fi
  die "REFUSING to $action $disk — it is an internal disk (tran=$tran). USB is the default. Pass --allow-internal only if you really mean this disk."
}

has_pv() {
  command -v pv >/dev/null 2>&1
}

send_pipe() {
  # print the middle of `btrfs send ... | THIS | btrfs receive`
  if has_pv; then
    printf 'pv -f -p -t -e -r -b'
  else
    printf 'cat'
  fi
}
