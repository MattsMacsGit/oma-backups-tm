#!/usr/bin/env bash
# Snapshot @ and @home, rsync onto LUKS dest, snapshot dest.
# Progress: phase JSON + rsync --info=progress2 on stderr. Never du, never pty.
set -euo pipefail

OMARCHY_TM_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export OMARCHY_TM_ROOT
# shellcheck source=lib/common.sh
source "$OMARCHY_TM_ROOT/lib/common.sh"
# shellcheck source=lib/remote.sh
source "$OMARCHY_TM_ROOT/lib/remote.sh"

usage() {
  cat <<'EOF'
Usage:
  oma-backups backup [--dry-run] [--yes] [--home-only]
  oma-backups snapshots
  oma-backups files SNAPSHOT [PATH]
  oma-backups copy SNAPSHOT SRC DEST

Engine: btrfs RO snapshot of @/@home → rsync (excludes) → dest RO snapshot.
EOF
}

MODE=backup
HOME_ONLY=0
LIST_JSON=0
ORIG_ARGS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) export OMARCHY_TM_DRY_RUN=1; shift ;;
    --yes) export OMARCHY_TM_YES=1; shift ;;
    --home-only) HOME_ONLY=1; export OMARCHY_TM_HOME_ONLY=1; shift ;;
    --list) MODE=list; shift ;;
    --prune) MODE=prune; shift ;;
    --browse) MODE=browse; shift; break ;;
    --json) LIST_JSON=1; shift ;;
    --check) MODE=check; shift ;;
    --files) MODE=files; shift; break ;;
    --copy) MODE=copy; shift; break ;;
    --restore-files) MODE=copy; shift; break ;;
    *) die "unknown flag: $1" ;;
  esac
done

load_config_json
require_supported

MNT="$(cfg '.paths.mountpoint')"
LUKS_MAPPER="$(cfg '.layout.luks_mapper')"
SRC_TOP="$(cfg '.paths.source_toplevel')"
SNAP_SUB="$(cfg '.paths.source_snap_subvol')"
EX_HOME="$(cfg '._excludes_home')"
EX_OS="$(cfg '._excludes_os')"
ROOT_DEV="$(printf '%s' "$DETECT_JSON" | jq -r '.root.device')"
HOSTNAME="$(printf '%s' "$DETECT_JSON" | jq -r '.hostname')"
MACHINE_ID="$(printf '%s' "$DETECT_JSON" | jq -r '.machine_id')"
KERNEL="$(printf '%s' "$DETECT_JSON" | jq -r '.kernel')"
OS_VER="$(printf '%s' "$DETECT_JSON" | jq -r '.os.version')"

require_excludes_visible() {
  local ok
  ok="$(cfg '._config_ok_as_root')"
  if [[ $ok != true && $(id -u) -eq 0 ]]; then
    die "running as root with no SUDO_USER and no /etc/omarchy-backups/excludes-home.txt — refusing (this is how Videos leaked last time). Run: sudo oma-backups init-config"
  fi
  if [[ ! -f $EX_HOME ]]; then
    die "missing excludes file $EX_HOME — run: sudo oma-backups init-config"
  fi
}

refresh_excludes_from_user() {
  "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/compile_excludes.py"
  load_config_json
  EX_HOME="$(cfg '._excludes_home')"
  EX_OS="$(cfg '._excludes_os')"
  local n_home n_os line
  n_home=$(grep -v '^#' "$EX_HOME" 2>/dev/null | grep -vc '^$')
  n_os=$(grep -v '^#' "$EX_OS" 2>/dev/null | grep -vc '^$')
  while IFS= read -r line; do log_file "  home $line"; done < <(grep -v '^#' "$EX_HOME" 2>/dev/null | grep -v '^$')
  while IFS= read -r line; do log_file "  os   $line"; done < <(grep -v '^#' "$EX_OS" 2>/dev/null | grep -v '^$')
  step "Skip list: $n_home home, $n_os os entries excluded"
}

mount_src_top() {
  mkdir -p "$SRC_TOP"
  if ! findmnt -n "$SRC_TOP" >/dev/null 2>&1; then
    run_quiet mount -o subvolid=5,compress=zstd:3 "$ROOT_DEV" "$SRC_TOP"
  fi
  if [[ ! -e $SRC_TOP/$SNAP_SUB ]]; then
    run_quiet btrfs subvolume create "$SRC_TOP/$SNAP_SUB"
  fi
}

# Source snapshots only live for one backup (or until it's resumed). Anything
# else here was left by a run that won't be resumed, and pins old data on the
# system disk. Only one backup runs at a time (pid file).
clean_src_snapshots() {
  local keep=${1:-} s
  for s in "$SRC_TOP/$SNAP_SUB"/os-* "$SRC_TOP/$SNAP_SUB"/home-*; do
    [[ -e $s ]] || continue
    [[ -n $keep && ${s##*-} == "$keep" ]] && continue
    btrfs subvolume delete "$s" >/dev/null 2>>"$OMARCHY_TM_LOG" &&
      log_file "removed leftover source snapshot $s"
  done
}

# ---- Resume -----------------------------------------------------------------
# A stopped or interrupted backup carries on where it left off: same restore
# point, same source snapshots, finished steps skipped, half-copied files
# continued (rsync --partial). Only for the same backup disk, the same kind of
# backup, within a day; anything else starts fresh.
RESUME_FILE="$OMARCHY_TM_STATE/in-progress.json"
RESUME_MAX_AGE=86400
RESUMED=0

dest_id() {
  if [[ $DEST_REMOTE == 1 ]]; then
    printf 'remote:%s:%s\n' "$REMOTE_HOST" "$(jq -r '.luks_uuid // ""' "$OMA_REMOTE_CONF")"
  else
    printf 'local:%s\n' "$(luks_uuid_of "$(capsule_luks_partition 2>/dev/null || true)")"
  fi
}

# Prints the restore point to carry on with, or nothing.
resumable_ts() {
  [[ -f $RESUME_FILE ]] || return 0
  local ts dest home_only started
  ts="$(jq -r '.ts // ""' "$RESUME_FILE" 2>/dev/null)" || return 0
  dest="$(jq -r '.dest // ""' "$RESUME_FILE")"
  home_only="$(jq -r '.home_only // 0' "$RESUME_FILE")"
  started="$(jq -r '.started // 0' "$RESUME_FILE")"
  [[ $ts =~ ^[0-9]{8}T[0-9]{6}Z$ && $dest == "$(dest_id)" && $home_only == "$HOME_ONLY" ]] || return 0
  (($(date +%s) - started < RESUME_MAX_AGE)) || return 0
  [[ -d $SRC_TOP/$SNAP_SUB/home-$ts ]] || return 0
  [[ $HOME_ONLY == 1 || -d $SRC_TOP/$SNAP_SUB/os-$ts ]] || return 0
  printf '%s\n' "$ts"
}

resume_start() {
  jq -n --arg ts "$1" --arg dest "$(dest_id)" --argjson ho "$HOME_ONLY" --argjson at "$(date +%s)" \
    '{ts: $ts, dest: $dest, home_only: $ho, started: $at, done: [], sizes: {}}' >"$RESUME_FILE"
  chmod 644 "$RESUME_FILE" 2>/dev/null || true
}

step_done() {
  local name=$1 size=${2:-0}
  [[ $size =~ ^[0-9]+$ ]] || size=0
  jq --arg n "$name" --argjson s "$size" '.done += [$n] | .sizes[$n] = $s' "$RESUME_FILE" >"$RESUME_FILE.tmp" &&
    chmod 644 "$RESUME_FILE.tmp" && mv "$RESUME_FILE.tmp" "$RESUME_FILE"
}

is_done() {
  jq -e --arg n "$1" '.done | index($n)' "$RESUME_FILE" >/dev/null 2>&1
}

step_size() {
  jq -r --arg n "$1" '.sizes[$n] // 0' "$RESUME_FILE" 2>/dev/null || echo 0
}

# Where this backup goes: the backup USB plugged into this laptop, or (once
# paired, and only while the USB isn't plugged in here) the Pi it lives on.
# Every d_* helper takes paths relative to the backup disk's top level.
DEST_REMOTE=0
RSYNC_RSH=()

pick_destination() {
  if remote_configured && [[ -z $(capsule_luks_partition 2>/dev/null || true) ]] &&
    ! findmnt -n "$MNT" >/dev/null 2>&1; then
    DEST_REMOTE=1
    remote_load
    RSYNC_RSH=(-e "$(remote_rsh)")
  fi
}

remote_open() {
  local st
  st="$(rgate status 2>>"$OMARCHY_TM_LOG")" ||
    fail_backup "Can't reach $REMOTE_HOST. Is it switched on, and on the same network (or Tailscale) as this laptop?"
  [[ $(jq -r .present <<<"$st") == true ]] ||
    fail_backup "The backup disk isn't plugged into $REMOTE_HOST (or its USB hub has no power)."
  rgate unlock <"$OMA_CAPSULE_KEY" 2>>"$OMARCHY_TM_LOG" ||
    fail_backup "$REMOTE_HOST couldn't unlock the backup disk. Re-pair it: oma-backups remote pair $REMOTE_HOST"
}

remote_close() {
  [[ $DEST_REMOTE == 1 ]] && rgate lock >/dev/null 2>>"$OMARCHY_TM_LOG" || true
}

d_target() {
  if [[ $DEST_REMOTE == 1 ]]; then printf '%s:%s\n' "$REMOTE_HOST" "$1"; else printf '%s\n' "$MNT/$1"; fi
}

d_exists() {
  if [[ $DEST_REMOTE == 1 ]]; then rgate exists "$1" 2>>"$OMARCHY_TM_LOG"; else [[ -e $MNT/$1 ]]; fi
}

# Functions don't inherit the ERR trap, so these fail loudly themselves.
d_mkdir() {
  if [[ $DEST_REMOTE == 1 ]]; then
    rgate mkdir "$1" 2>>"$OMARCHY_TM_LOG"
  else
    mkdir -p "$MNT/$1" 2>>"$OMARCHY_TM_LOG"
  fi || fail_backup "couldn't create $1 on the backup disk"
}

d_snapshot() {
  if [[ $DEST_REMOTE == 1 ]]; then
    rgate snapshot "$1" "$2" 2>>"$OMARCHY_TM_LOG"
  else
    run_quiet btrfs subvolume snapshot -r "$MNT/$1" "$MNT/$2"
  fi || fail_backup "couldn't save restore point $2"
}

d_chmod755() {
  if [[ $DEST_REMOTE == 1 ]]; then
    rgate chmod755 "$@" 2>>"$OMARCHY_TM_LOG" || true
  else
    local p
    for p in "$@"; do chmod 755 "$MNT/$p" 2>/dev/null || true; done
  fi
}

ensure_dest_current() {
  local kind=$1
  if [[ $DEST_REMOTE == 1 ]]; then
    rgate subvol-create "$kind/current" 2>>"$OMARCHY_TM_LOG" ||
      fail_backup "couldn't prepare $kind/current on $REMOTE_HOST"
    rgate set-writable "$kind/current" 2>>"$OMARCHY_TM_LOG" || true
    return 0
  fi
  mkdir -p "$MNT/$kind"
  if ! btrfs subvolume show "$MNT/$kind/current" >/dev/null 2>&1; then
    if [[ -e $MNT/$kind/current ]]; then
      fail_backup "$MNT/$kind/current exists but is not a btrfs subvolume"
    fi
    run_quiet btrfs subvolume create "$MNT/$kind/current"
  fi
  # A read-only "current" cannot receive the next backup.
  btrfs property set -ts "$MNT/$kind/current" ro false 2>/dev/null || true
}

# Literal command dump for --dry-run only — real runs get announce_backup's
# short gum-styled summary instead.
print_plan() {
  local ts=$1
  cat <<EOF
== backup $ts ==
source:  $ROOT_DEV  Omarchy $OS_VER  kernel $KERNEL  host $HOSTNAME
os exclude:   $EX_OS
$(grep -v '^#' "$EX_OS" 2>/dev/null | grep -v '^$' | sed 's/^/    /' || true)
home exclude: $EX_HOME
$(grep -v '^#' "$EX_HOME" 2>/dev/null | grep -v '^$' | sed 's/^/    /' || true)

mkdir -p $SRC_TOP
mount -o subvolid=5 $ROOT_DEV $SRC_TOP
btrfs subvolume snapshot -r $SRC_TOP/@     $SRC_TOP/$SNAP_SUB/os-$ts
btrfs subvolume snapshot -r $SRC_TOP/@home $SRC_TOP/$SNAP_SUB/home-$ts
rsync -aHAX --numeric-ids --delete --info=progress2 --exclude-from=$EX_OS \\
  $SRC_TOP/$SNAP_SUB/os-$ts/   $MNT/os/current/
rsync -aHAX --numeric-ids --delete --info=progress2 --exclude-from=$EX_HOME \\
  $SRC_TOP/$SNAP_SUB/home-$ts/ $MNT/home/current/
rsync -a --delete --partial --info=progress2 /boot/ $MNT/esp/current/
btrfs subvolume snapshot -r $MNT/os/current   $MNT/os/$ts
btrfs subvolume snapshot -r $MNT/home/current $MNT/home/$ts
btrfs subvolume snapshot -r $MNT/esp/current  $MNT/esp/$ts
# also refresh rescue EFI from this /boot (so updates stay restorable)
EOF
}

# Short gum-styled summary shown once at the start of a real backup —
# print_plan's literal command dump is for --dry-run only.
announce_backup() {
  local ts=$1
  echo
  gum style --bold "Backing up $HOSTNAME"
  echo
  gum style --foreground 8 "  source:  $ROOT_DEV  Omarchy $OS_VER  kernel $KERNEL"
  if [[ $DEST_REMOTE == 1 ]]; then
    gum style --foreground 8 "  to:      backup disk on $REMOTE_HOST"
  fi
  gum style --foreground 8 "  restore point: $ts"
  echo
}

# Parse rsync progress2 on stderr without a PTY and without du.
# Copy one tree. Sets TREE_SIZE to rsync's "Total file size" (the restore
# point's size for this part), so nothing ever has to walk the tree again.
TREE_SIZE=0
rsync_tree() {
  local src=$1 dest=$2 ex=$3 label=$4
  progress phase "$label"
  if is_dry_run; then
    echo "[dry-run] rsync -aHAX --numeric-ids --delete --partial --info=progress2 --exclude-from=$ex $src/ $dest/"
    return 0
  fi
  step "Backing up $label — live progress in the plugin panel"
  [[ $DEST_REMOTE == 1 ]] || mkdir -p "$dest"
  local stats
  stats="$(mktemp)"
  set +e
  set +o pipefail
  # rsync 3.x sends --info=progress2 to stdout (not stderr) when not a TTY.
  # --partial: a file cut off mid-copy continues next time instead of
  # starting over (safe: `current` only becomes a restore point on success).
  stdbuf -e0 -o0 rsync "${RSYNC_RSH[@]}" -aHAX --numeric-ids --delete --delete-excluded --partial \
    --info=progress2,name0,flist2 --stats \
    --exclude-from="$ex" "$src"/ "$dest"/ \
    2>&1 | "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/progress.py" stream "$label" "$stats"
  local rc=${PIPESTATUS[0]}
  TREE_SIZE="$(cat "$stats" 2>/dev/null || echo 0)"
  rm -f "$stats"
  set -o pipefail
  set -e
  # 0 = ok, 23 = some files skipped (xattrs/ACLs), 24 = vanished during copy.
  # None of those should abort the restore point.
  if [[ $rc -ne 0 && $rc -ne 23 && $rc -ne 24 ]]; then
    fail_backup "$(rsync_failure_text "$rc")"
  fi
  if [[ $rc -ne 0 ]]; then
    warn "rsync $label finished with warnings (exit $rc) — restore point will still be saved"
  fi
  progress set "$label" 100
}

# rsync's exit codes mean nothing to most people; say what probably
# happened and what to do. The code stays at the end for the log.
rsync_failure_text() {
  local rc=$1 where="The backup disk"
  [[ $DEST_REMOTE == 1 ]] && where="The backup disk on $REMOTE_HOST"
  case $rc in
    11)
      echo "$where stopped responding partway through. Check its power and cable, then press Resume. (rsync code $rc)" ;;
    10 | 12 | 30 | 35 | 255)
      if [[ $DEST_REMOTE == 1 ]]; then
        echo "Lost the connection to $REMOTE_HOST partway through. Check it's switched on and connected, then press Resume. (rsync code $rc)"
      else
        echo "$where stopped responding partway through. Check it's still plugged in, then press Resume. (rsync code $rc)"
      fi ;;
    20)
      echo "The copy was interrupted. Press Resume to carry on. (rsync code $rc)" ;;
    *)
      echo "Copying stopped with an error. Press Resume to try again; details are in $OMARCHY_TM_LOG. (rsync code $rc)" ;;
  esac
}

on_backup_exit() {
  local rc=$?
  # Locking a disk on a Pi takes a few seconds; say so rather than leaving
  # the plugin to guess whether the backup is still running.
  [[ $STOPPED == 1 && $DEST_REMOTE == 1 ]] && progress phase stopping
  remote_close
  clear_pid
  if [[ $rc -ne 0 ]]; then
    # Keep fail_backup's message for the plugin; otherwise it was stopped.
    [[ $BACKUP_FAILED == 1 ]] || progress idle
  else
    clear_incomplete
  fi
}

# Stop button / systemctl stop: exit cleanly (the EXIT trap tidies up and the
# backup can be resumed) instead of carrying on and reporting rsync's
# "killed by signal" as a failure.
STOPPED=0
# 1 once cmd_backup's EXIT handler is on. Other commands that unlock the disk
# install a smaller "lock it again" trap; during a backup that must not
# replace on_backup_exit, which locks up AND clears the pid and status.
BACKUP_TRAPS=0
on_stop_signal() {
  STOPPED=1
  exit 143
}

BACKUP_FAILED=0
fail_backup() {
  echo
  gum style --bold --foreground 1 "Backup failed."
  gum style --foreground 8 "$*"
  gum style --foreground 8 "See $OMARCHY_TM_LOG for details."
  # The plugin shows this; backups started without a terminal have no other
  # way to say why they stopped.
  [[ $STOPPED == 1 ]] && exit 143
  BACKUP_FAILED=1
  if [[ -n ${BROWSE_STATE:-} ]]; then
    browse_state error "$*"
  else
    progress fail "Backup failed: $*"
  fi
  exit 130
}

backup_running() {
  local p
  p="$(tr -d '[:space:]' <"$(pid_file)" 2>/dev/null || true)"
  [[ -n $p && $p != "$$" ]] && pid_alive "$p" && grep -qa backup.sh "/proc/$p/cmdline" 2>/dev/null
}

# Checks for another backup and claims the pid file in one step, under a
# short lock. The pid file used to be written only after the disk was
# unlocked (several seconds on a Pi), so an automatic backup and a Resume
# press close together could both get through.
refuse_if_running() {
  local other
  exec 9>"$(pid_file).lock"
  flock -w 10 9 || true
  other="$(tr -d '[:space:]' 2>/dev/null <"$(pid_file)" || true)"
  if [[ -n $other && $other != "$$" ]] && pid_alive "$other" &&
    grep -qa backup.sh "/proc/$other/cmdline" 2>/dev/null; then
    exec 9>&-
    # Not a failure: leave the status file alone so the plugin keeps
    # following the backup that's already running.
    gum style --bold "A backup is already running (pid $other). Leaving it to finish."
    exit 0
  fi
  write_pid
  exec 9>&-
}

open_destination() {
  if [[ $DEST_REMOTE == 1 ]]; then
    step "Unlocking the backup disk on $REMOTE_HOST"
    progress phase "unlock"
    remote_open
    ((BACKUP_TRAPS)) || trap remote_close EXIT
    # Setups from before the current-disk record: adopt the disk in use.
    local u
    u="$(jq -r '.luks_uuid // empty' "$OMA_REMOTE_CONF")"
    [[ -f $OMA_CURRENT_CAPSULE || -z $u ]] || set_current_capsule "$u"
    return 0
  fi
  local want mapper
  want="$(capsule_luks_partition 2>/dev/null || true)"
  if [[ -n $want ]] && findmnt -n "$MNT" >/dev/null 2>&1; then
    mapper="$(backup_mapper "$MNT")"
    if ! lsblk -nr -o NAME,TYPE "$want" 2>/dev/null | awk '$2=="crypt"{print $1}' | grep -qx "$mapper"; then
      step "Switching to the current backup disk"
      "$OMARCHY_TM_ROOT/mount.sh" umount >/dev/null 2>&1 || true
    fi
  fi
  if ! findmnt -n "$MNT" >/dev/null 2>&1; then
    step "Backup disk not mounted — unlocking"
    progress phase "unlock"
    "$OMARCHY_TM_ROOT/mount.sh" mount
  fi
  ensure_rw_mount "$MNT"
  findmnt -n "$MNT" >/dev/null 2>&1 || fail_backup "capsule not mounted at $MNT"
  { touch "$MNT/.oma-write-test" && rm -f "$MNT/.oma-write-test"; } 2>/dev/null ||
    fail_backup "The backup disk can't be written to. Unplug it, plug it back in, and try again."
  if [[ ! -f $OMA_CURRENT_CAPSULE && -n $want ]]; then
    set_current_capsule "$(luks_uuid_of "$want")"
  fi
}

d_list_json() {
  if [[ $DEST_REMOTE == 1 ]]; then
    rgate list 2>>"$OMARCHY_TM_LOG"
  else
    "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/list_snapshots.py" "$MNT" --json
  fi
}

# "TOTAL FREE" in bytes.
d_df() {
  if [[ $DEST_REMOTE == 1 ]]; then
    rgate df 2>>"$OMARCHY_TM_LOG"
  else
    df -B1 --output=size,avail "$MNT" | tail -1 | awk '{print $1, $2}'
  fi
}

d_delete_point() {
  local ts=$1
  [[ $ts =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || return 1
  if [[ $DEST_REMOTE == 1 ]]; then
    rgate delete "$ts" 2>>"$OMARCHY_TM_LOG"
  else
    local kind newest
    newest="$(find "$MNT/home" "$MNT/os" -maxdepth 1 -regex '.*/[0-9]\{8\}T[0-9]\{6\}Z' -printf '%f\n' 2>/dev/null | sort | tail -1)"
    [[ $ts != "$newest" ]] || return 1
    for kind in os home; do
      if [[ -d $MNT/$kind/$ts ]]; then
        btrfs subvolume delete "$MNT/$kind/$ts" >>"$OMARCHY_TM_LOG" 2>&1 || return 1
      fi
    done
    # Boot files are a snapshot of esp/current now; older restore points
    # have a plain folder.
    if btrfs subvolume show "$MNT/esp/$ts" >/dev/null 2>&1; then
      btrfs subvolume delete "$MNT/esp/$ts" >>"$OMARCHY_TM_LOG" 2>&1 || return 1
    else
      rm -rf "${MNT:?}/esp/$ts"
    fi
  fi
}

# Wait until btrfs has really freed the space of deleted restore points.
d_settle() {
  if [[ $DEST_REMOTE == 1 ]]; then
    rgate settle 2>>"$OMARCHY_TM_LOG"
  else
    btrfs subvolume sync "$MNT" >>"$OMARCHY_TM_LOG" 2>&1
  fi
}

# The plugin shows a remote disk's free space from this; it can't ask the Pi.
cache_remote_df() {
  local total free f="$OMARCHY_TM_STATE/capsule-disk.json"
  [[ $DEST_REMOTE == 1 ]] || return 0
  read -r total free < <(d_df) || return 0
  [[ $total =~ ^[0-9]+$ && $free =~ ^[0-9]+$ ]] || return 0
  printf '{"total": %s, "free": %s}\n' "$total" "$free" >"$f.tmp" && chmod 644 "$f.tmp" && mv "$f.tmp" "$f"
}

disk_low() {
  local total free
  read -r total free < <(d_df) || return 1
  [[ ${total:-0} -gt 0 ]] && ((free * 10 < total))
}

# Thin old restore points (Time Machine-style) and, when the disk is under
# 10% free, delete the oldest until it isn't. Never the newest. With the
# "keep" setting nothing is deleted; the user is warned instead.
prune_restore_points() {
  local dry=${1:-0} mode plan ts n=0
  mode="$("$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/schedule.py" get retention)"
  if [[ $DEST_REMOTE == 1 && $(rgate version 2>/dev/null || echo 0) -lt 2 ]]; then
    warn "The Pi's gatekeeper is out of date, so old restore points weren't tidied up. Update it by running this on the Pi:"
    warn "  curl -fsSL $OMA_REPO_RAW/pi/pi-setup.sh | sudo bash -s -- --update"
    return 0
  fi
  plan="$(d_list_json | jq -r '.[].timestamp' |
    "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/retention.py" plan --mode "$mode")"
  # After a "system + settings" restore, the restore point it came from is the
  # only one that still has the user's files until they're brought back.
  local protected
  protected="$(jq -r '.snapshot // empty' "$OMARCHY_TM_STATE/partial-restore.json" 2>/dev/null || true)"
  if [[ -n $protected ]]; then
    plan="$(jq --arg p "$protected" '.thin -= [$p] | .space_order -= [$p] | .keep = (.keep + [$p] | unique)' <<<"$plan")"
  fi
  if [[ $dry == 1 ]]; then
    echo "Setting: $mode"
    jq -r '"Keep:    \(.keep | length)", "Thin:    \(.thin | join(" "))", "If the disk fills, oldest first: \(.space_order | join(" "))"' <<<"$plan"
    disk_low && echo "The disk is under 10% free right now."
    return 0
  fi
  for ts in $(jq -r '.thin[]' <<<"$plan"); do
    d_delete_point "$ts" && n=$((n + 1)) && log_file "thinned restore point $ts"
  done
  ((n == 0)) || d_settle || true
  if disk_low; then
    if [[ $mode == keep ]]; then
      warn "The backup disk is nearly full (under 10% free)."
      notify_user "Backup disk nearly full" "Less than 10% free. Delete old restore points or use a bigger disk." nearly-full
      return 0
    fi
    for ts in $(jq -r '.space_order[]' <<<"$plan"); do
      d_delete_point "$ts" || break
      n=$((n + 1))
      log_file "deleted restore point $ts to free space"
      d_settle || true
      disk_low || break
    done
    disk_low && warn "The backup disk is still nearly full, even after removing old restore points."
  fi
  ((n == 0)) || step "Tidied up $n old restore point(s)"
}

cmd_backup() {
  require_excludes_visible
  dest_mounted() { findmnt -n "$MNT" >/dev/null 2>&1; }
  local ts run_started
  ts="$(now_timestamp)"
  # When this run began. The schedule counts from here rather than from the
  # finish, so a slow backup doesn't push the next one a whole tick late.
  run_started="$(date +%s)"
  if [[ $(id -u) -eq 0 ]]; then
    refresh_excludes_from_user
  fi
  if is_dry_run; then
    print_plan "$ts"
    echo "Dry-run only."
    exit 0
  fi
  require_root "${ORIG_ARGS[@]}"
  refuse_if_running
  # From here on this run owns the pid file, and the next steps can unlock
  # the disk, so Stop must already be handled: without these traps a Stop
  # during unlocking killed us outright and left the disk open.
  trap on_backup_exit EXIT
  trap on_stop_signal INT TERM
  BACKUP_TRAPS=1
  if [[ -f $OMA_SCHEDULE_UNIT && ${OMARCHY_TM_UNATTENDED:-0} != 1 ]]; then
    refresh_root_copy || warn "Couldn't update the copy automatic backups run from."
  fi
  refresh_excludes_from_user
  # A backup disk unplugged while mounted leaves a dead mount at $MNT that
  # still looks mounted; writing to it fails with I/O errors mid-backup.
  close_stale_mapper "$LUKS_MAPPER"
  pick_destination
  announce_backup "$ts"
  open_destination
  [[ ${OMARCHY_TM_YES:-0} == 1 ]] || confirm "Run this backup?"

  mark_incomplete
  trap 'fail_backup "unexpected failure"' ERR
  progress phase "prepare"

  mount_src_top
  local resume_ts
  resume_ts="$(resumable_ts)"
  if [[ -n $resume_ts ]]; then
    ts=$resume_ts
    RESUMED=1
    progress phase "resume"
    step "Carrying on the backup from $ts where it stopped"
  else
    rm -f "$RESUME_FILE"
    while d_exists "os/$ts" || d_exists "home/$ts"; do
      sleep 1
      ts="$(now_timestamp)"
    done
  fi
  clean_src_snapshots "$([[ $RESUMED == 1 ]] && echo "$ts")"

  # Boot files: rsync into esp/current and snapshot it, like os/home, so only
  # changed files are sent. A Pi whose gatekeeper can't delete such snapshots
  # yet (before v4) gets a full copy per restore point, as before.
  local esp_subvol=1
  if [[ $DEST_REMOTE == 1 && $(rgate version 2>/dev/null || echo 0) -lt 4 ]]; then
    esp_subvol=0
  fi

  ensure_dest_current os
  ensure_dest_current home
  d_mkdir esp
  [[ $esp_subvol == 1 ]] && ensure_dest_current esp
  d_mkdir meta

  if [[ $RESUMED != 1 ]]; then
    progress phase "snapshot"
    step "Snapshotting the current system"
    if [[ $HOME_ONLY != 1 ]]; then
      run_quiet btrfs subvolume snapshot -r "$SRC_TOP/@" "$SRC_TOP/$SNAP_SUB/os-$ts"
    fi
    run_quiet btrfs subvolume snapshot -r "$SRC_TOP/@home" "$SRC_TOP/$SNAP_SUB/home-$ts"
    resume_start "$ts"
  fi

  if [[ $HOME_ONLY != 1 ]] && ! is_done os; then
    rsync_tree "$SRC_TOP/$SNAP_SUB/os-$ts" "$(d_target os/current)" "$EX_OS" os
    step_done os "$TREE_SIZE"
  fi
  if ! is_done home; then
    rsync_tree "$SRC_TOP/$SNAP_SUB/home-$ts" "$(d_target home/current)" "$EX_HOME" home
    step_done home "$TREE_SIZE"
  fi
  if ! is_done esp; then
    step "Backing up the boot partition"
    progress phase "esp"
    local esp_dest=esp/current
    [[ $esp_subvol == 1 ]] || { esp_dest="esp/$ts"; d_mkdir "$esp_dest"; }
    set +o pipefail
    rsync "${RSYNC_RSH[@]}" -a --delete --partial --info=progress2 /boot/ "$(d_target "$esp_dest")/" \
      2>&1 | "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/progress.py" stream esp || true
    set -o pipefail
    step_done esp
  fi

  # The rescue partitions can only be refreshed with the USB plugged in here.
  if [[ $DEST_REMOTE != 1 && $(cfg '.backup.refresh_rescue_boot') == true ]]; then
    progress phase "rescue"
    if [[ -x $OMARCHY_TM_ROOT/refresh-rescue.sh ]]; then
      step "Refreshing the rescue USB's boot files"
      "$OMARCHY_TM_ROOT/refresh-rescue.sh" --boot-only || warn "rescue EFI refresh failed (backup data is still valid)"
    fi
  fi

  step "Saving this as a restore point"
  progress phase "finalize"
  # Each part is skipped if it's already there: a run interrupted while
  # saving just finishes the job when resumed.
  if [[ $HOME_ONLY != 1 ]] && ! d_exists "os/$ts"; then
    d_snapshot os/current "os/$ts"
  fi
  d_exists "home/$ts" || d_snapshot home/current "home/$ts"
  if [[ $esp_subvol == 1 ]] && ! d_exists "esp/$ts"; then
    d_snapshot esp/current "esp/$ts"
  fi

  if [[ $HOME_ONLY != 1 ]]; then
    run_quiet btrfs subvolume delete "$SRC_TOP/$SNAP_SUB/os-$ts" || true
  fi
  run_quiet btrfs subvolume delete "$SRC_TOP/$SNAP_SUB/home-$ts" || true
  local size_os size_home
  size_os="$(step_size os)" size_home="$(step_size home)"
  # Saved as a restore point: nothing left to resume.
  rm -f "$RESUME_FILE"

  local valid=true
  if [[ $HOME_ONLY == 1 ]]; then
    d_exists "home/$ts" || valid=false
  else
    { d_exists "os/$ts" && d_exists "home/$ts" && d_exists "esp/$ts"; } || valid=false
  fi

  # The restore point's size: what rsync reported for each part (kept in the
  # resume record, so a resumed backup still knows the parts done earlier).
  # Stored in machine.json and carried forward on every later scan; nothing
  # walks the tree to measure it.
  local size_total=$((size_os + size_home))

  local meta="$MNT/meta/machine.json"
  local user_name="${SUDO_USER:-${USER:-}}"
  local snaps_json
  if [[ $DEST_REMOTE == 1 ]]; then
    meta="$(mktemp)"
    snaps_json="$(rgate list 2>>"$OMARCHY_TM_LOG")"
  else
    snaps_json="$("$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/list_snapshots.py" "$MNT" --json)"
  fi
  snaps_json="$(printf '%s' "$snaps_json" | jq --arg ts "$ts" --argjson total "$size_total" \
    'map(if .timestamp == $ts then . + {size_total: $total} else . end)')"
  jq -n \
    --arg host "$HOSTNAME" --arg mid "$MACHINE_ID" --arg ker "$KERNEL" \
    --arg ver "$OS_VER" --arg user "$user_name" --argjson snaps "$snaps_json" \
    '{
      schema_version: 2,
      product: "oma-backups",
      hostname: $host,
      machine_id: $mid,
      kernel: $ker,
      omarchy_version: $ver,
      engine: "rsync",
      login_user: $user,
      snapshots: $snaps
    }' >"$meta.tmp"
  if [[ $DEST_REMOTE == 1 ]]; then
    rgate write-meta <"$meta.tmp" 2>>"$OMARCHY_TM_LOG" ||
      fail_backup "couldn't save the restore-point list on $REMOTE_HOST"
    rm -f "$meta" "$meta.tmp"
    # Restore points themselves are read-only snapshots, so only the
    # writable parents can be opened up.
    d_chmod755 os home esp meta os/current home/current
  else
    mv "$meta.tmp" "$meta"
    chmod 755 "$MNT" "$MNT/os" "$MNT/home" "$MNT/esp" "$MNT/meta" 2>/dev/null || true
    chmod 755 "$MNT/os/current" "$MNT/home/current" "$MNT/os/$ts" "$MNT/home/$ts" 2>/dev/null || true
    chmod 644 "$meta" 2>/dev/null || true
    # File manager on a restore point should show $USER, not an empty parent.
    if [[ -n $user_name && -d $MNT/home/$ts/$user_name ]]; then
      chmod 755 "$MNT/home/$ts/$user_name" 2>/dev/null || true
    fi
  fi
  trap - ERR
  if [[ $valid == true ]]; then
    echo "$run_started" >"$OMARCHY_TM_STATE/last-success"
    chmod 644 "$OMARCHY_TM_STATE/last-success" 2>/dev/null || true
    progress phase "tidy"
    prune_restore_points || warn "Couldn't tidy up old restore points (this backup is still saved)."
  fi
  cache_remote_df
  progress done "valid=$valid ts=$ts"
  log_file "backup $ts valid=$valid omarchy=$OS_VER kernel=$KERNEL"
  local listing
  if [[ $DEST_REMOTE == 1 ]]; then
    # Keeps the plugin's restore-point list current without it touching the network.
    listing="$(rgate list 2>>"$OMARCHY_TM_LOG" |
      "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/list_snapshots.py" --stdin || true)"
  else
    "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/list_snapshots.py" "$MNT" --json >/dev/null || true
    listing="$("$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/list_snapshots.py" "$MNT" || true)"
  fi
  echo
  gum style --bold --foreground 2 "● Backup finished."
  gum style --foreground 8 "  Restore points on this disk:"
  echo
  printf '%s\n' "$listing"
  echo
}

BROWSE_DIR=/run/omarchy-backups-browse
BROWSE_STATE=""

# The plugin polls $BROWSE_DIR/TS.json: {"state": "ready", "path": ...} or
# {"state": "error", "message": ...}.
browse_state() {
  local state=$1 value=${2:-}
  [[ -n $BROWSE_STATE ]] || return 0
  if [[ $state == ready ]]; then
    jq -n --arg p "$value" '{state: "ready", path: $p}' >"$BROWSE_STATE.tmp"
  else
    jq -n --arg m "$value" '{state: "error", message: $m}' >"$BROWSE_STATE.tmp"
  fi
  chmod 644 "$BROWSE_STATE.tmp"
  mv "$BROWSE_STATE.tmp" "$BROWSE_STATE"
}

# Open one restore point's copy of the user's home folder, read-only, until
# stopped (the plugin starts/stops oma-backups-browse@TS.service).
cmd_browse() {
  local ts=${1:-} user=${SUDO_USER:-${USER:-}}
  [[ $ts =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "usage: oma-backups browse SNAPSHOT"
  OMARCHY_TM_ALLOW_USER_DRY_RUN=0 require_root "${ORIG_ARGS[@]}"
  [[ $user =~ ^[a-z_][a-z0-9_-]*$ && $user != root ]] || die "couldn't tell whose files to open"
  mkdir -p "$BROWSE_DIR"
  chmod 755 "$BROWSE_DIR"
  BROWSE_STATE="$BROWSE_DIR/$ts.json"
  rm -f "$BROWSE_STATE"

  close_stale_mapper "$LUKS_MAPPER"
  pick_destination
  open_destination

  if [[ $DEST_REMOTE != 1 ]]; then
    local path="$MNT/home/$ts/$user"
    [[ -d $path ]] || fail_backup "No copy of your home folder in that restore point."
    trap 'rm -f "$BROWSE_STATE"' EXIT
    browse_state ready "$path"
    # Nothing to hold open for a plugged-in disk; just wait to be stopped.
    sleep infinity &
    wait $! || true
    return 0
  fi

  [[ $(rgate version 2>/dev/null || echo 0) -ge 3 ]] ||
    fail_backup "The Pi needs updating to open restore points. Run this on it: curl -fsSL $OMA_REPO_RAW/pi/pi-setup.sh | sudo bash -s -- --update"
  command -v sshfs >/dev/null || fail_backup "sshfs isn't installed (run: oma-backups link --refresh)."
  local mp="$BROWSE_DIR/$ts" pid
  mkdir -p "$mp"
  # Leave the disk unlocked if a backup is mid-way; it locks it when done.
  trap 'fusermount3 -u "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null; rmdir "$mp" 2>/dev/null; rm -f "$BROWSE_STATE"; backup_running || remote_close' EXIT
  # allow_other + default_permissions: mounted by root, readable by the user
  # exactly as far as each file's own owner/permissions allow.
  sshfs -f -o ro,allow_other,default_permissions,reconnect \
    -o ssh_command="$(remote_rsh)" -o sftp_server="/browse $ts $user" \
    "$REMOTE_HOST:/data" "$mp" 2>>"$OMARCHY_TM_LOG" &
  pid=$!
  local i
  for i in $(seq 1 60); do
    mountpoint -q "$mp" && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  mountpoint -q "$mp" || fail_backup "Couldn't open that restore point on $REMOTE_HOST (see $OMARCHY_TM_LOG)."
  browse_state ready "$mp"
  wait "$pid" || true
}

cmd_prune() {
  # Even a dry run has to unlock the disk to read its restore points.
  OMARCHY_TM_ALLOW_USER_DRY_RUN=0 require_root "${ORIG_ARGS[@]}"
  refuse_if_running
  close_stale_mapper "$LUKS_MAPPER"
  pick_destination
  open_destination
  write_pid
  trap 'remote_close; clear_pid' EXIT
  local dry=0
  is_dry_run && dry=1
  prune_restore_points "$dry"
  cache_remote_df
  if [[ $DEST_REMOTE == 1 && $dry == 0 ]]; then
    rgate list 2>>"$OMARCHY_TM_LOG" | "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/list_snapshots.py" --stdin --json >/dev/null || true
  fi
}

cmd_list() {
  findmnt -n "$MNT" >/dev/null 2>&1 || {
    echo "No restore points on this disk."
    return 0
  }
  if [[ $LIST_JSON == 1 ]]; then
    "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/list_snapshots.py" "$MNT" --json
  else
    "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/list_snapshots.py" "$MNT"
  fi
}

cmd_files() {
  local snap=${1:-} rel=${2:-}
  findmnt -n "$MNT" >/dev/null 2>&1 || die "not mounted"
  [[ -n $snap ]] || die "usage: oma-backups files SNAPSHOT [PATH]"
  local user_name="${SUDO_USER:-${USER:-}}"
  local base="$MNT/home/$snap"
  [[ -d $base ]] || die "no home snapshot $snap"
  if [[ -n $rel ]]; then
    ls -la "$base/$rel"
  elif [[ -n $user_name && -d $base/$user_name ]]; then
    ls -la "$base/$user_name"
  else
    ls -la "$base"
  fi
}

cmd_copy() {
  local snap=${1:-} src=${2:-} dest=${3:-}
  [[ -n $snap && -n $src && -n $dest ]] || die "usage: oma-backups copy SNAPSHOT SRC DEST"
  findmnt -n "$MNT" >/dev/null 2>&1 || die "not mounted"
  local from="$MNT/home/$snap/$src"
  [[ -e $from ]] || die "not in snapshot: $src"
  mkdir -p "$(dirname "$dest")"
  rsync -a --info=progress2 "$from" "$dest"
  log "copied $src from $snap -> $dest"
}

case "$MODE" in
  list) cmd_list ;;
  check) cmd_list ;;
  files) cmd_files "$@" ;;
  copy) cmd_copy "$@" ;;
  backup) cmd_backup ;;
  prune) cmd_prune ;;
  browse) cmd_browse "$@" ;;
esac
