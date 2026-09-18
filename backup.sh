#!/usr/bin/env bash
# Snapshot @ and @home, rsync onto LUKS dest, snapshot dest.
# Progress: phase JSON + rsync --info=progress2 on stderr. Never du, never pty.
set -euo pipefail

OMARCHY_TM_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export OMARCHY_TM_ROOT
# shellcheck source=lib/common.sh
source "$OMARCHY_TM_ROOT/lib/common.sh"

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

ensure_src_top() {
  mkdir -p "$SRC_TOP"
  if ! findmnt -n "$SRC_TOP" >/dev/null 2>&1; then
    run_quiet mount -o subvolid=5,compress=zstd:3 "$ROOT_DEV" "$SRC_TOP"
  fi
  if [[ ! -e $SRC_TOP/$SNAP_SUB ]]; then
    run_quiet btrfs subvolume create "$SRC_TOP/$SNAP_SUB"
  fi
}

ensure_dest_current() {
  local kind=$1
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
rsync -a --info=progress2 /boot/ $MNT/esp/$ts/
btrfs subvolume snapshot -r $MNT/os/current   $MNT/os/$ts
btrfs subvolume snapshot -r $MNT/home/current $MNT/home/$ts
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
  gum style --foreground 8 "  restore point: $ts"
  echo
}

# Parse rsync progress2 on stderr without a PTY and without du.
rsync_tree() {
  local src=$1 dest=$2 ex=$3 label=$4
  progress phase "$label"
  if is_dry_run; then
    echo "[dry-run] rsync -aHAX --numeric-ids --delete --info=progress2 --no-inc-recursive --exclude-from=$ex $src/ $dest/"
    return 0
  fi
  step "Backing up $label — live progress in the plugin panel"
  mkdir -p "$dest"
  set +e
  set +o pipefail
  # rsync 3.x sends --info=progress2 to stdout (not stderr) when not a TTY.
  stdbuf -e0 -o0 rsync -aHAX --numeric-ids --delete --delete-excluded \
    --info=progress2,name0,flist0 --no-inc-recursive \
    --exclude-from="$ex" "$src"/ "$dest"/ \
    2>&1 | "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/progress.py" stream "$label"
  local rc=${PIPESTATUS[0]}
  set -o pipefail
  set -e
  # 0 = ok, 23 = some files skipped (xattrs/ACLs), 24 = vanished during copy.
  # None of those should abort the restore point.
  if [[ $rc -ne 0 && $rc -ne 23 && $rc -ne 24 ]]; then
    fail_backup "rsync $label failed (exit $rc)"
  fi
  if [[ $rc -ne 0 ]]; then
    warn "rsync $label finished with warnings (exit $rc) — restore point will still be saved"
  fi
  progress set "$label" 100
}

on_backup_exit() {
  local rc=$?
  clear_pid
  if [[ $rc -ne 0 ]]; then
    progress idle
  else
    clear_incomplete
  fi
}

fail_backup() {
  echo
  gum style --bold --foreground 1 "Backup failed."
  gum style --foreground 8 "$*"
  gum style --foreground 8 "See $OMARCHY_TM_LOG for details."
  exit 130
}

cmd_backup() {
  require_excludes_visible
  dest_mounted() { findmnt -n "$MNT" >/dev/null 2>&1; }
  local ts
  ts="$(now_timestamp)"
  if [[ $(id -u) -eq 0 ]]; then
    refresh_excludes_from_user
  fi
  if is_dry_run; then
    print_plan "$ts"
    echo "Dry-run only."
    exit 0
  fi
  require_root "${ORIG_ARGS[@]}"
  refresh_excludes_from_user
  announce_backup "$ts"
  if ! dest_mounted; then
    step "Backup disk not mounted — unlocking"
    progress phase "unlock"
    "$OMARCHY_TM_ROOT/mount.sh" mount
  fi
  ensure_rw_mount "$MNT"
  dest_mounted || fail_backup "capsule not mounted at $MNT"
  while [[ -e $MNT/os/$ts || -e $MNT/home/$ts ]]; do
    sleep 1
    ts="$(now_timestamp)"
  done
  [[ ${OMARCHY_TM_YES:-0} == 1 ]] || confirm "Run this backup?"

  write_pid
  mark_incomplete
  trap on_backup_exit EXIT INT TERM
  trap 'fail_backup "unexpected failure"' ERR
  progress phase "snapshot"

  ensure_src_top
  ensure_dest_current os
  ensure_dest_current home
  mkdir -p "$MNT/esp" "$MNT/meta"

  step "Snapshotting the current system"
  if [[ $HOME_ONLY != 1 ]]; then
    run_quiet btrfs subvolume snapshot -r "$SRC_TOP/@" "$SRC_TOP/$SNAP_SUB/os-$ts"
  fi
  run_quiet btrfs subvolume snapshot -r "$SRC_TOP/@home" "$SRC_TOP/$SNAP_SUB/home-$ts"

  if [[ $HOME_ONLY != 1 ]]; then
    rsync_tree "$SRC_TOP/$SNAP_SUB/os-$ts" "$MNT/os/current" "$EX_OS" os
  fi
  rsync_tree "$SRC_TOP/$SNAP_SUB/home-$ts" "$MNT/home/current" "$EX_HOME" home
  mkdir -p "$MNT/esp/$ts"
  step "Backing up the boot partition"
  progress phase "esp"
  set +o pipefail
  rsync -a --info=progress2 /boot/ "$MNT/esp/$ts/" \
    2>&1 | "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/progress.py" stream esp || true
  set -o pipefail

  if [[ $(cfg '.backup.refresh_rescue_boot') == true ]]; then
    progress phase "rescue"
    if [[ -x $OMARCHY_TM_ROOT/refresh-rescue.sh ]]; then
      step "Refreshing the rescue USB's boot files"
      "$OMARCHY_TM_ROOT/refresh-rescue.sh" --boot-only || warn "rescue EFI refresh failed (backup data is still valid)"
    fi
  fi

  step "Saving this as a restore point"
  progress phase "finalize"
  if [[ -e $MNT/os/$ts ]]; then fail_backup "dest os/$ts already exists"; fi
  if [[ $HOME_ONLY != 1 ]]; then
    run_quiet btrfs subvolume snapshot -r "$MNT/os/current" "$MNT/os/$ts"
  fi
  run_quiet btrfs subvolume snapshot -r "$MNT/home/current" "$MNT/home/$ts"

  if [[ $HOME_ONLY != 1 ]]; then
    run_quiet btrfs subvolume delete "$SRC_TOP/$SNAP_SUB/os-$ts" || true
  fi
  run_quiet btrfs subvolume delete "$SRC_TOP/$SNAP_SUB/home-$ts" || true

  local valid=true
  if [[ $HOME_ONLY == 1 ]]; then
    [[ -e $MNT/home/$ts ]] || valid=false
  else
    [[ -e $MNT/os/$ts && -e $MNT/home/$ts && -e $MNT/esp/$ts ]] || valid=false
  fi

  # One btrfs filesystem du per side, right now while the snapshot is
  # fresh — the only place this is ever computed. Stored in machine.json
  # and carried forward by list_snapshots.py on every later (frequent,
  # plugin-polled) scan, never recomputed. "Total" is the snapshot's
  # apparent size; "exclusive" is what deleting *only* this snapshot
  # would actually free (btrfs COW shares data with other snapshots, so
  # total overstates that) — exclusive is what a future "delete to make
  # space" feature should sort/act on.
  step "Measuring this restore point's size"
  snapshot_du() {
    local path=$1 line
    line="$(btrfs filesystem du -s --raw "$path" 2>/dev/null | awk 'NR==2{print $1, $2}')"
    [[ -n $line ]] && printf '%s\n' "$line" || printf '0 0\n'
  }
  local os_total=0 os_excl=0 home_total=0 home_excl=0
  if [[ $HOME_ONLY != 1 && -d $MNT/os/$ts ]]; then
    read -r os_total os_excl < <(snapshot_du "$MNT/os/$ts")
  fi
  if [[ -d $MNT/home/$ts ]]; then
    read -r home_total home_excl < <(snapshot_du "$MNT/home/$ts")
  fi
  local size_total=$((os_total + home_total))
  local size_excl=$((os_excl + home_excl))

  local meta="$MNT/meta/machine.json"
  local user_name="${SUDO_USER:-${USER:-}}"
  local snaps_json
  snaps_json="$("$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/list_snapshots.py" "$MNT" --json)"
  snaps_json="$(printf '%s' "$snaps_json" | jq --arg ts "$ts" --argjson total "$size_total" --argjson excl "$size_excl" \
    'map(if .timestamp == $ts then . + {size_total: $total, size_exclusive: $excl} else . end)')"
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
  mv "$meta.tmp" "$meta"
  chmod 755 "$MNT" "$MNT/os" "$MNT/home" "$MNT/esp" "$MNT/meta" 2>/dev/null || true
  chmod 755 "$MNT/os/current" "$MNT/home/current" "$MNT/os/$ts" "$MNT/home/$ts" 2>/dev/null || true
  chmod 644 "$meta" 2>/dev/null || true
  # File manager on a restore point should show $USER, not an empty parent.
  if [[ -n $user_name && -d $MNT/home/$ts/$user_name ]]; then
    chmod 755 "$MNT/home/$ts/$user_name" 2>/dev/null || true
  fi
  trap - ERR
  progress done "valid=$valid ts=$ts"
  log_file "backup $ts valid=$valid omarchy=$OS_VER kernel=$KERNEL"
  "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/list_snapshots.py" "$MNT" --json >/dev/null || true
  echo
  gum style --bold --foreground 2 "● Backup finished."
  gum style --foreground 8 "  Restore points on this disk:"
  echo
  "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/list_snapshots.py" "$MNT" || true
  echo
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
esac
