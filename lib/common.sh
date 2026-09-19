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

# File-only counterpart to log() — full detail for debugging, never the
# terminal. Pair with step()/warn() for what the user actually sees.
log_file() {
  local line
  line="$(ts) $*"
  mkdir -p "$(dirname "$OMARCHY_TM_LOG")"
  printf '%s\n' "$line" >>"$OMARCHY_TM_LOG" || true
}

# One quiet, dim narrated status line — the house style Omarchy's own
# scripts use (gum style --foreground 8), e.g. omarchy-system-factory-reset.
# Always also recorded to the log file.
step() {
  log_file "$1"
  gum style --foreground 8 "  $1"
}

# Same, but for a non-fatal warning worth the user's attention (yellow).
warn() {
  log_file "WARNING: $1"
  gum style --foreground 3 "  $1"
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

# Command -> pacman package, for auto-install. Commands not listed here
# fall back to using the command name itself as the package name.
declare -A OMARCHY_TM_PKG_OF=(
  [btrfs]=btrfs-progs
  [mkfs.btrfs]=btrfs-progs
  [cryptsetup]=cryptsetup
  [mkfs.fat]=dosfstools
  [mkfs.ext4]=e2fsprogs
  [rsync]=rsync
  [sfdisk]=util-linux
  [lsblk]=util-linux
  [wipefs]=util-linux
  [sgdisk]=gptfdisk
  [curl]=curl
  [unsquashfs]=squashfs-tools
  [mksquashfs]=squashfs-tools
  [jq]=jq
  [pv]=pv
  [arch-chroot]=arch-install-scripts
  [gum]=gum
  [bsdtar]=libarchive
)

# Ensure each named command is present, auto-installing its pacman package
# (via sudo if not already root) when it is missing. This is the product's
# job, not the user's — never tell someone to go run pacman themselves.
# Dies with a clear message if the install attempt itself fails (no
# network, renamed package, etc.) rather than silently continuing.
ensure_deps() {
  local missing=() pkgs=() c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  for c in "${missing[@]}"; do
    pkgs+=("${OMARCHY_TM_PKG_OF[$c]:-$c}")
  done
  mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | sort -u)
  log "installing missing packages: ${pkgs[*]} (for: ${missing[*]})"
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    pacman -S --needed --noconfirm "${pkgs[@]}" ||
      die "could not install ${pkgs[*]} — check network/pacman and re-run"
  else
    sudo pacman -S --needed --noconfirm "${pkgs[@]}" ||
      die "could not install ${pkgs[*]} — check network/pacman and re-run"
  fi
  for c in "${missing[@]}"; do
    command -v "$c" >/dev/null 2>&1 || die "still missing after install attempt: $c"
  done
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

# Same as run(), but the command line and its own output go to the log
# file only — never the terminal. Pair with an explicit step() call so
# the user sees a clean narrated line instead of the raw command.
run_quiet() {
  if is_dry_run; then
    printf '[dry-run] %s\n' "$*"
    log_file "[dry-run] $*"
    return 0
  fi
  log_file "+ $*"
  "$@" >>"$OMARCHY_TM_LOG" 2>&1
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
  echo
  gum style --bold --foreground 3 "$prompt"
  ans=$(gum input --placeholder "Type 'YES' to continue" --prompt "> ") || die "aborted"
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

# Which backup disk is the current one (written when a disk is set up), so a
# second backup USB plugged in at the same time never gets picked by accident.
OMA_CURRENT_CAPSULE=/etc/omarchy-backups/capsule.json

current_capsule_uuid() {
  jq -r '.luks_uuid // empty' "$OMA_CURRENT_CAPSULE" 2>/dev/null || true
}

# LUKS partition of a backup disk (one that also has OMARCHY-EFI /
# OMARCHY-LIVE): the current one if it's plugged in, else the first found.
# On rescue that disk IS the live root — still the backup we need to unlock.
capsule_luks_partition() {
  local want disk part first=""
  want="$(current_capsule_uuid)"
  while read -r disk; do
    part="$(lsblk -n -p -o PATH,FSTYPE "/dev/$disk" 2>/dev/null | awk '$2=="crypto_LUKS"{print $1; exit}')"
    [[ -n $part ]] || continue
    if [[ -n $want && $(lsblk -n -o UUID "$part" 2>/dev/null | head -1) == "$want" ]]; then
      printf '%s\n' "$part"
      return 0
    fi
    [[ -n $first ]] || first=$part
  done < <(lsblk -nr -o PKNAME,LABEL 2>/dev/null | awk '$2=="OMARCHY-EFI" || $2=="OMARCHY-LIVE" {print $1}' | awk 'NF && !seen[$0]++')
  [[ -n $first ]] || return 1
  printf '%s\n' "$first"
}

set_current_capsule() {
  local uuid=$1
  mkdir -p "$(dirname "$OMA_CURRENT_CAPSULE")"
  jq -n --arg u "$uuid" --arg at "$(ts)" '{luks_uuid: $u, set_up_at: $at}' >"$OMA_CURRENT_CAPSULE.tmp"
  chmod 644 "$OMA_CURRENT_CAPSULE.tmp"
  mv "$OMA_CURRENT_CAPSULE.tmp" "$OMA_CURRENT_CAPSULE"
}

# Root-only unlock key held by this laptop, added as an extra key slot on
# the backup disk. Lets backups unlock without a password: on a paired Pi,
# and for scheduled backups to a USB plugged in here.
OMA_CAPSULE_KEY=/etc/omarchy-backups/capsule.key

capsule_key_present() {
  # Pairing used to keep it in the Pi folder; move it where both uses find it.
  local old=/etc/omarchy-backups/remote/capsule.key
  if [[ ! -f $OMA_CAPSULE_KEY && -f $old && ${EUID:-$(id -u)} -eq 0 ]]; then
    mv "$old" "$OMA_CAPSULE_KEY"
  fi
  [[ -f $OMA_CAPSULE_KEY ]]
}

create_capsule_key() {
  capsule_key_present && return 0
  mkdir -p "$(dirname "$OMA_CAPSULE_KEY")"
  (umask 077 && head -c 4096 /dev/urandom >"$OMA_CAPSULE_KEY")
}

capsule_key_opens() {
  capsule_key_present && cryptsetup open --test-passphrase --key-file "$OMA_CAPSULE_KEY" "$1" 2>/dev/null
}

# Make sure the backup disk's LUKS partition accepts the laptop key, asking
# for the disk password once if it doesn't yet.
ensure_capsule_key() {
  local part=$1
  capsule_key_opens "$part" && return 0
  create_capsule_key
  step "Adding this laptop's unlock key to the backup disk"
  gum style --foreground 8 "  Enter the backup disk password (the one you chose when setting it up)."
  # 4 KB of random data doesn't need argon2's slow, memory-hungry derivation,
  # which would make every unlock on a small machine like a Pi slow.
  cryptsetup luksAddKey --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
    "$part" "$OMA_CAPSULE_KEY" </dev/tty
}

# Automatic backups run from a root-owned copy of this code: the root timer
# must never run files the user account can edit (the normal install is a
# user-owned clone). Refreshed whenever the user authenticates with sudo.
OMA_ROOT_COPY=/usr/local/lib/oma-backups
OMA_SCHEDULE_UNIT=/etc/systemd/system/oma-backups-scheduled.service

refresh_root_copy() {
  [[ ${EUID:-$(id -u)} -eq 0 && $OMARCHY_TM_ROOT != "$OMA_ROOT_COPY" ]] || return 0
  mkdir -p "$OMA_ROOT_COPY"
  rsync -a --delete --exclude .git/ --exclude __pycache__/ --exclude .claude-notes/ \
    "$OMARCHY_TM_ROOT/" "$OMA_ROOT_COPY/"
  chown -R root:root "$OMA_ROOT_COPY"
  chmod -R go-w "$OMA_ROOT_COPY"
}

# Desktop notification for the logged-in user, even from the root timer.
# KEY limits each kind of message to once a day.
notify_user() {
  local title=$1 body=$2 key=${3:-} user uid stamp
  if [[ -n $key ]]; then
    stamp="$OMARCHY_TM_STATE/notified-$key"
    if [[ -f $stamp ]] && (($(date +%s) - $(stat -c %Y "$stamp") < 86400)); then
      return 0
    fi
  fi
  user=${SUDO_USER:-${USER:-}}
  uid="$(id -u "$user" 2>/dev/null)" || return 0
  [[ -S /run/user/$uid/bus ]] || return 0
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
      notify-send -a OmaBackups "$title" "$body" 2>/dev/null || return 0
  else
    notify-send -a OmaBackups "$title" "$body" 2>/dev/null || return 0
  fi
  [[ -z $key ]] || touch "$stamp" 2>/dev/null || true
}

pid_file() {
  printf '%s\n' "${OMARCHY_TM_PID_FILE:-/run/omarchy-backups.pid}"
}

pid_alive() {
  local pid=${1:-}
  [[ -n $pid && $pid =~ ^[0-9]+$ ]] || return 1
  # /proc existence, not kill -0: the backup runs as root (via sudo), but
  # this is also called unprivileged by the plugin's status poll — kill -0
  # against a root-owned pid from a non-root caller fails with EPERM even
  # when the process is alive, which made status_json report "stale" for
  # the entire duration of every real backup.
  [[ -d /proc/$pid ]]
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

# Marks whether the last backup attempt ran to completion. Set once a
# backup genuinely starts (write_pid time); cleared only on a clean
# finish. Lets the plugin offer "Resume backup" instead of "Backup now"
# after a stop/crash/interruption, without guessing from status alone.
incomplete_flag() {
  printf '%s\n' "$OMARCHY_TM_STATE/incomplete"
}

mark_incomplete() {
  local f
  f="$(incomplete_flag)"
  touch "$f" 2>/dev/null || true
  chmod 644 "$f" 2>/dev/null || true
}

clear_incomplete() {
  rm -f "$(incomplete_flag)"
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
  local pidf pid raw incomplete
  pidf="$(pid_file)"
  pid=""
  [[ -f $pidf ]] && pid="$(tr -d '[:space:]' <"$pidf")"
  incomplete=false
  [[ -f $(incomplete_flag) ]] && incomplete=true
  if [[ -f $f ]]; then
    raw="$(cat "$f" 2>/dev/null || true)"
  else
    raw='{"running":false,"phase":"idle","percent":0,"speed":"","eta":"","line":""}'
  fi
  if printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    if [[ -n $pid ]] && pid_alive "$pid"; then
      printf '%s\n' "$raw" | jq -c --arg pid "$pid" --argjson incomplete "$incomplete" \
        '.pid=$pid | .stale=false | .incomplete=$incomplete'
      return 0
    fi
    printf '%s\n' "$raw" | jq -c --argjson incomplete "$incomplete" \
      '.running=false | .stale=true | .pid=null | .incomplete=$incomplete'
    return 0
  fi
  if [[ -n $pid ]] && pid_alive "$pid"; then
    jq -n -c --arg line "$raw" --arg pid "$pid" --argjson incomplete "$incomplete" \
      '{running:true, phase:"unknown", percent:0, speed:"", eta:"", line:$line, pid:$pid, stale:false, incomplete:$incomplete}'
  else
    jq -n -c --arg line "$raw" --argjson incomplete "$incomplete" \
      '{running:false, phase:"idle", percent:0, speed:"", eta:"", line:$line, stale:true, incomplete:$incomplete}'
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
