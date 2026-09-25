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
  oma-backups backup [--dry-run] [--yes] [--home-only] [--force-after-restore]
  oma-backups snapshots
  oma-backups files TIMESTAMP [PATH]
  oma-backups copy TIMESTAMP SRC DEST

Engine: btrfs RO snapshot of @/@home → rsync (excludes) → dest RO snapshot.
EOF
}

MODE=backup
HOME_ONLY=0
FORCE_AFTER_RESTORE=0
LIST_JSON=0
ORIG_ARGS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) export OMARCHY_TM_DRY_RUN=1; shift ;;
    --yes) export OMARCHY_TM_YES=1; shift ;;
    --home-only) HOME_ONLY=1; export OMARCHY_TM_HOME_ONLY=1; shift ;;
    --force-after-restore) FORCE_AFTER_RESTORE=1; shift ;;
    --list) MODE=list; shift ;;
    --prune) MODE=prune; shift ;;
    --browse) MODE=browse; shift; break ;;
    --json) LIST_JSON=1; shift ;;
    --files) MODE=files; shift; break ;;
    --copy) MODE=copy; shift; break ;;
    --put-back-system) MODE=put_back_system; shift ;;
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
  local f
  for f in "$EX_HOME" "$EX_OS"; do
    [[ -f $f ]] || die "missing skip list $f — run: sudo oma-backups init-config"
  done
}

refresh_excludes_from_user() {
  "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/compile_excludes.py"
  load_config_json
  EX_HOME="$(cfg '._excludes_home')"
  EX_OS="$(cfg '._excludes_os')"
  local n_home n_os line
  # `grep -c` exits 1 when the count is zero, and under `set -e` that used to
  # end the backup right here — after it had already claimed the
  # running-backup marker. An empty skip list is a number, not a failure.
  n_home=$(grep -v '^#' "$EX_HOME" 2>/dev/null | grep -vc '^$' || true)
  n_os=$(grep -v '^#' "$EX_OS" 2>/dev/null | grep -vc '^$' || true)
  n_home=${n_home:-0} n_os=${n_os:-0}
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

# ---- Progress ---------------------------------------------------------------
# The panel shows two bars: the step running now, and the whole backup. The
# overall one is weighted by how much data each step has to move, so a huge
# "your files" step doesn't sit at "1 of 4" for hours. A resumed run marks
# what is already finished so the bar starts where the last attempt got to.
plan_progress() {
  local steps=() item name finished json='[]'
  # Getting ready and snapshotting have both happened by the time the plan is
  # built, so they go in as finished: their share of the run is time already
  # spent, and the overall bar should say so rather than owing it twice.
  steps+=("prepare:1")
  [[ $RESUMED == 1 ]] || steps+=("snapshot:1")
  steps+=("measure:0")
  if [[ $HOME_ONLY != 1 ]]; then
    steps+=("os:$(is_done os && echo 1 || echo 0)")
  fi
  steps+=("home:$(is_done home && echo 1 || echo 0)")
  steps+=("esp:$(is_done esp && echo 1 || echo 0)")
  steps+=("finalize:0")
  steps+=("tidy:0")
  for item in "${steps[@]}"; do
    name=${item%%:*}
    finished=false
    [[ ${item##*:} == 1 ]] && finished=true
    json="$(jq -c --arg n "$name" --argjson d "$finished" '. + [{name: $n, done: $d}]' <<<"$json")"
  done
  progress plan "$(jq -cn --argjson s "$json" '{steps: $s}')"
}

# How much a step has to get through, so both bars have a real denominator
# instead of rsync's percentage against a file list it is still building.
# A dry run against an empty folder: the source side only, no file contents
# read, nothing sent over the network, and the same skip list the real copy
# uses — so the total is what will actually be copied, not what du would say.
measure_tree() {
  local src=$1 ex=${2:-} step=$3 empty
  is_dry_run && return 0
  empty="$(mktemp -d)" || return 0
  local args=(-a --dry-run --stats --info=flist2)
  [[ -n $ex ]] && args+=(--exclude-from="$ex")
  set +o pipefail
  rsync "${args[@]}" "$src"/ "$empty"/ 2>&1 |
    "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/progress.py" measure "$step" || true
  set -o pipefail
  rmdir "$empty" 2>/dev/null || true
}

# Where this backup goes: the backup USB plugged into this laptop, or (once
# paired, and only while the USB isn't plugged in here) the Pi it lives on.
# Every d_* helper takes paths relative to the backup disk's top level.
DEST_REMOTE=0
RSYNC_RSH=()
# Filled in once the destination is known. Whole changed files on USB and
# LAN. Over Tailscale, keep the delta and compress: a one-byte change in a
# big file should not cross the slow link in full.
RSYNC_LINK=()
# Gatekeeper 9 hands back a mark when it unlocks: one per thing using the disk.
# It locks when the LAST mark goes, not the first, so a browse session closing
# can no longer pull the disk out from under a models put-back. Empty against
# an older gatekeeper, where lock still means lock.
REMOTE_HOLD=""
REMOTE_HOLD_PID=""
# Whether this gatekeeper issues marks at all, which is a different question
# from whether we are still holding one. Without it, a second remote_close --
# an explicit one followed by the EXIT trap -- would look like "no mark" and
# fall through to the blunt lock that takes the disk off everybody.
REMOTE_HOLD_ISSUED=0

pick_destination() {
  # "No backup disk plugged in here" also covers "a backup disk is plugged in,
  # but not the one that was set up": that disk is not a destination, and the
  # Pi is. Plugging an old backup USB in to fetch something off it should not
  # divert tonight's backup onto it.
  if remote_configured && ! findmnt -n "$MNT" >/dev/null 2>&1 &&
    { [[ -z $(capsule_luks_partition 2>/dev/null || true) ]] || capsule_is_not_the_recorded_one; }; then
    DEST_REMOTE=1
    remote_load
    RSYNC_RSH=(-e "$(remote_rsh)")
  fi
}

# Reading back (a restore's files, its AI models, things a restore left out)
# comes from the disk those files are on, recorded when the restore was made —
# not from wherever the next backup would go. Backups write to one disk; a
# restore point can be on another: the Pi, or an older backup USB. Restore
# points without a record (anything opened from the list) are on the disk the
# list came from, which is the destination.
SOURCE_PART=""
pick_source() {
  local ts=$1 want uuid
  want="$(source_for_ts "$ts")"
  case $want in
    remote:*)
      remote_configured ||
        fail_backup "That restore point is on a Pi this laptop isn't paired with any more. Pair it again (Settings → Back up to a Pi), then try again."
      grep -qxF -- "$want" <<<"$(remote_source_ids)" ||
        fail_backup "That restore point is on the backup disk of a Pi this laptop was paired with before. Pair with that one again to bring it back."
      DEST_REMOTE=1
      remote_load
      RSYNC_RSH=(-e "$(remote_rsh)")
      ;;
    local:?*)
      uuid=${want#local:}
      SOURCE_PART="$(lsblk -nrp -o PATH,FSTYPE,UUID 2>/dev/null |
        awk -v u="$uuid" '$2=="crypto_LUKS" && $3==u {print $1; exit}')"
      [[ -n $SOURCE_PART ]] ||
        fail_backup "That restore point is on a backup USB that isn't plugged in (the one it was restored from). Plug it in and try again."
      DEST_REMOTE=0
      ;;
    *) pick_destination ;;
  esac
}

# A disk opened only to read from (pick_source) is locked again afterwards,
# unless it is the backup disk anyway. Left open, it sits where backups look,
# and the next one refuses it as "not the backup disk you set up".
release_source() {
  [[ -n $SOURCE_PART ]] || return 0
  [[ $(luks_uuid_of "$SOURCE_PART") == "$(current_capsule_uuid)" ]] && return 0
  backup_running && return 0
  "$OMARCHY_TM_ROOT/mount.sh" umount >/dev/null 2>&1 || true
}

remote_open() {
  local st
  st="$(rgate status 2>>"$OMARCHY_TM_LOG")" ||
    fail_backup "Can't reach $REMOTE_HOST. Is it switched on, and on the same network (or Tailscale) as this laptop?"
  note_pi_gate "$(jq -r '.version // 0' <<<"$st")"
  [[ $(jq -r .present <<<"$st") == true ]] ||
    fail_backup "The backup disk isn't plugged into $REMOTE_HOST (or its USB hub has no power)."
  # A gatekeeper before v8 can refuse an unlock that arrives while the lock
  # from a restore point just closed is still queued — it decided it wouldn't
  # need the key before it found out it would. That clears itself in seconds,
  # so it is worth one more try before telling anyone their pairing is broken,
  # which in that case it isn't.
  local out
  if ! out="$(rgate unlock <"$OMA_CAPSULE_KEY" 2>>"$OMARCHY_TM_LOG")"; then
    sleep 5
    out="$(rgate unlock <"$OMA_CAPSULE_KEY" 2>>"$OMARCHY_TM_LOG")" ||
      fail_backup "$REMOTE_HOST couldn't unlock the backup disk. Give it a moment and try again — if it keeps happening, re-pair it: oma-backups remote pair $REMOTE_HOST"
  fi
  # Matched whole, not filtered: anything that isn't exactly a mark means we
  # are talking to a gatekeeper that doesn't issue them.
  REMOTE_HOLD=""
  if [[ $out =~ ^[0-9a-f]{16}$ ]]; then
    REMOTE_HOLD="$out"
    REMOTE_HOLD_ISSUED=1
  fi
  remote_hold_start
}

# A mark nothing refreshes for ten minutes is taken to belong to something
# that died, so anything long-running says "still here" as it goes. The loop
# stops of its own accord the moment the gatekeeper stops recognising it.
remote_hold_start() {
  [[ -n $REMOTE_HOLD ]] || return 0
  (
    # Not the caller's cleanup: this loop ending, or being killed, must never
    # be mistaken for the job itself finishing.
    trap - EXIT INT TERM
    while sleep 120; do
      rgate hold "$REMOTE_HOLD" >/dev/null 2>&1 || exit 0
    done
  ) &
  REMOTE_HOLD_PID=$!
}

remote_hold_stop() {
  [[ -n $REMOTE_HOLD_PID ]] || return 0
  kill "$REMOTE_HOLD_PID" 2>/dev/null || true
  wait "$REMOTE_HOLD_PID" 2>/dev/null || true
  REMOTE_HOLD_PID=""
}

remote_close() {
  [[ $DEST_REMOTE == 1 ]] || return 0
  remote_hold_stop
  if ((REMOTE_HOLD_ISSUED)); then
    # Let go of our own mark and nothing else. Whether the disk actually locks
    # is the gatekeeper's call: if a backup, a browse session or a put-back is
    # still on it, staying open is the right answer, not a failure.
    [[ -n $REMOTE_HOLD ]] || return 0
    local hold=$REMOTE_HOLD
    REMOTE_HOLD=""
    rgate lock "$hold" >/dev/null 2>>"$OMARCHY_TM_LOG" ||
      warn "Couldn't let go of the backup disk on $REMOTE_HOST (it locks itself when nobody is using it)."
    return 0
  fi
  # Gatekeeper 8 and older: no marks, so lock means lock. Those before v6 also
  # don't queue a lock behind an unlock, so a Stop pressed while unlocking
  # could lock nothing and leave the disk open once the unlock landed. Check,
  # and lock again if it's still open.
  local i
  for i in 1 2 3; do
    rgate lock >/dev/null 2>>"$OMARCHY_TM_LOG" || true
    [[ $(rgate status 2>/dev/null | jq -r '.unlocked // false' 2>/dev/null) == true ]] || return 0
    sleep 5
  done
  warn "Couldn't lock the backup disk on $REMOTE_HOST — it may still be unlocked there."
  return 0
}

d_target() {
  if [[ $DEST_REMOTE == 1 ]]; then printf '%s:%s\n' "$(remote_target)" "$1"; else printf '%s\n' "$MNT/$1"; fi
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

# Whole files, or delta plus zstd, depending on how we reach the disk.
# No --checksum-choice: two rsyncs that both know xxh128 pick it anyway,
# and forcing it fails outright against a Pi whose rsync was built without.
rsync_link_flags() {
  RSYNC_LINK=()
  # A local copy already sends whole files; rsync only deltas over a network.
  [[ $DEST_REMOTE == 1 ]] || return 0
  # remote_pick_addr hands back a LAN address when one answers, and the
  # paired name otherwise. Away from home that name is how Tailscale gets
  # there, and it is a MagicDNS name far more often than a bare 100.x
  # address, so "not the LAN address" is the test for the slow link.
  if [[ -n ${REMOTE_ADDR:-} && $REMOTE_ADDR != "$REMOTE_HOST" ]]; then
    RSYNC_LINK+=(-W)
  elif rsync --help 2>&1 | grep -q -- '--compress-choice'; then
    RSYNC_LINK+=(--compress --compress-choice=zstd)
  fi
}

# Short fingerprint of an exclude file, so a remembered size is only used
# with the skip list it was measured under. Empty when there is no file.
skip_list_id() {
  [[ -n ${1:-} && -r $1 ]] || return 0
  sha256sum <"$1" | cut -c1-16
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
  # --no-inc-recursive: build the whole file list before copying, so rsync
  # knows the real total from its first progress line. Folder-by-folder it
  # reports a total that keeps growing, which is why the bar could only ever
  # say "working" through the longest step of the backup.
  stdbuf -e0 -o0 rsync "${RSYNC_RSH[@]}" "${RSYNC_LINK[@]}" -aHAX --numeric-ids --delete --delete-excluded --partial \
    --no-inc-recursive --info=progress2,name0,flist2 --stats \
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
  gum style --bold --foreground 1 "${FAIL_TITLE:-Backup failed.}"
  gum style --foreground 8 "$*"
  gum style --foreground 8 "See $OMARCHY_TM_LOG for details."
  # The plugin shows this; backups started without a terminal have no other
  # way to say why they stopped.
  [[ $STOPPED == 1 ]] && exit 143
  BACKUP_FAILED=1
  if [[ -n ${BROWSE_STATE:-} ]]; then
    browse_state error "$*"
  else
    OMA_DEST_ID="$(dest_id 2>/dev/null || true)" progress fail "Backup failed: $*"
  fi
  # 1, not 130: by convention 130 means "the user pressed Ctrl-C", which is a
  # different thing from "this failed". 143 (asked to stop) stays as it is.
  exit 1
}

backup_running() {
  local p f
  # Checked for readability first: a `<missing-file` redirection is reported by
  # the shell before the command's own `2>/dev/null` can be applied, so the
  # "No such file or directory" went to the journal on every browse stop --
  # there is no pid file unless a backup is actually running.
  f="$(pid_file)"
  [[ -r $f ]] || return 1
  p="$(tr -d '[:space:]' 2>/dev/null <"$f" || true)"
  [[ -n $p && $p != "$$" ]] && pid_alive "$p" && grep -qa backup.sh "/proc/$p/cmdline" 2>/dev/null
}

# After a "system + settings" restore this system isn't whole yet: the files
# that haven't been brought back are on the backup and not here. Backing up
# now would push that gap over the top of the real backup (rsync --delete)
# and make a restore point out of it -- which is exactly what happens when a
# restored spare disk is booted to check it. So every backup is refused
# until the files are back, unless someone deliberately forces one, meaning
# "this is my system now; keep only what's on it".
partial_restore_snapshot() {
  jq -r '.snapshot // empty' "$OMARCHY_TM_STATE/partial-restore.json" 2>/dev/null || true
}

OMA_FORCE_NOTE() { printf '%s' "$OMARCHY_TM_STATE/force-after-restore"; }

# A systemd unit takes no arguments, so the plugin leaves a note instead of
# passing a flag. Only a hand-started backup may use it; an automatic one
# never does, and never eats the note either.
take_force_note() {
  [[ ${OMARCHY_TM_SCHEDULED:-0} == 1 ]] && return 1
  [[ -f $(OMA_FORCE_NOTE) ]] || return 1
  [[ ${1:-} == peek ]] || rm -f "$(OMA_FORCE_NOTE)"
  return 0
}

# A forced backup ends the restore, but not the restore point's job: what
# never came back is still on it, and nowhere else. Clearing the marker used
# to be all that happened, which took away the only thing stopping thinning
# from deleting it -- and the panel's "still holds" row that says where it
# is. Earmark it the way a restore that left things out does.
keep_forced_point() {
  local m="$OMARCHY_TM_STATE/partial-restore.json" snap source kf
  local -a what=()
  snap="$(jq -r '.snapshot // empty' "$m" 2>/dev/null || true)"
  [[ $snap =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || return 0
  source="$(jq -r '.source // empty' "$m" 2>/dev/null || true)"
  [[ $(jq -r '.files_done // false' "$m" 2>/dev/null) == true ]] || what+=("your files")
  [[ $(jq -r '.skipped_system // [] | length' "$m" 2>/dev/null || echo 0) == 0 ]] || what+=("your AI models")
  ((${#what[@]})) || return 0
  if "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/kept_points.py" --add "$snap" \
    ${source:+--source "$source"} "${what[@]}" >/dev/null 2>>"$OMARCHY_TM_LOG"; then
    # Written as root into the user's own folder: hand it back, so the
    # plugin can let it go later.
    # What they had chosen to leave out of this restore goes with it, so
    # going back for the rest starts from their answer rather than nothing.
    local -a skips=()
    mapfile -t skips < <(grep -v '^[[:space:]]*\(#\|$\)' "$OMARCHY_TM_STATE/restore-skips.txt" 2>/dev/null || true)
    if ((${#skips[@]})); then
      "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/kept_points.py" --set-skip "$snap" "${skips[@]}" \
        >/dev/null 2>>"$OMARCHY_TM_LOG" || true
    fi
    kf="$OMARCHY_TM_STATE/kept-points.json"
    chown --reference="$OMARCHY_TM_STATE" "$kf" 2>/dev/null || true
    log_file "forced backup: kept restore point $snap (still holds: ${what[*]})"
  else
    warn "Couldn't mark $snap to be kept. It still holds ${what[*]}; thinning may take it."
  fi
}

# Called twice: once before the sudo re-exec so a refusal costs no password
# prompt ("peek", consumes nothing), then again as root for real.
refuse_if_partial_restore() {
  local peek=${1:-} snap
  snap="$(partial_restore_snapshot)"
  [[ -n $snap ]] || return 0
  if [[ $FORCE_AFTER_RESTORE == 1 ]] || take_force_note "$peek"; then
    FORCE_AFTER_RESTORE=1
    [[ $peek == peek ]] && return 0
    warn "Backing up anyway. From here on the backup keeps only what's on this system."
    log_file "forced backup after a partial restore from $snap"
    return 0
  fi
  echo
  gum style --bold "This system isn't whole yet, so backups are paused."
  local m="$OMARCHY_TM_STATE/partial-restore.json"
  if [[ $(jq -r '.files_done // false' "$m" 2>/dev/null) == true ]]; then
    gum style --foreground 8 "  Your files are back, but the AI models the quick restore left behind"
    gum style --foreground 8 "  are still on the backup and not on this system, so backing up now"
    gum style --foreground 8 "  would delete them from the backup's current copy."
    echo
    gum style --foreground 8 "  Bring them back first: open the plugin and press \"Put AI models back\"."
  else
    gum style --foreground 8 "  Only your settings came back from $snap. Your documents, photos and"
    gum style --foreground 8 "  other files are still on the backup and not on this system, so backing"
    gum style --foreground 8 "  up now would delete them from the backup's current copy."
    if [[ $(jq -r '.skipped_system // [] | length' "$m" 2>/dev/null || echo 0) != 0 ]]; then
      gum style --foreground 8 "  The same goes for your AI models, which the quick restore left behind."
    fi
    echo
    gum style --foreground 8 "  Bring them back first: open the plugin and press \"Restore my files\"."
  fi
  gum style --foreground 8 "  To back up anyway and keep only what's here, hold Ctrl and press"
  gum style --foreground 8 "  \"Backup now\" in the plugin, or run:"
  gum style --foreground 8 "    oma-backups backup --force-after-restore"
  echo
  exit 0
}

# Checks for another backup and claims the pid file in one step, under a
# short lock. The pid file used to be written only after the disk was
# unlocked (several seconds on a Pi), so an automatic backup and a Resume
# press close together could both get through.
refuse_if_running() {
  local other
  exec 9>"$(pid_file).lock"
  # Giving up and continuing used to let Backup now and the hourly timer
  # both pass the check and both write the disk.
  if ! flock -w 10 9; then
    exec 9>&-
    gum style --bold "A backup is already starting. Leaving it to finish."
    exit 0
  fi
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
  # Local destination: whatever is plugged in has to be the disk that was set
  # up. With a Pi paired, pick_destination has already sent us there instead.
  # Reading from the disk a restore came from (pick_source) is the exception:
  # nothing is written to it, so it needn't be the one set up.
  [[ -n $SOURCE_PART ]] || refuse_other_capsule
  local want mapper
  want="${SOURCE_PART:-$(capsule_luks_partition 2>/dev/null || true)}"
  if [[ -n $want ]] && findmnt -n "$MNT" >/dev/null 2>&1; then
    mapper="$(backup_mapper "$MNT")"
    if ! lsblk -nr -o NAME,TYPE "$want" 2>/dev/null | awk '$2=="crypt"{print $1}' | grep -qx "$mapper"; then
      # Never pull the disk out from under a backup that is writing to it.
      [[ -n $SOURCE_PART ]] && backup_running &&
        fail_backup "A backup is using the other backup disk. Try again once it has finished."
      step "Switching to the $([[ -n $SOURCE_PART ]] && echo "backup disk it came from" || echo "current backup disk")"
      "$OMARCHY_TM_ROOT/mount.sh" umount >/dev/null 2>&1 || true
    fi
  fi
  if ! findmnt -n "$MNT" >/dev/null 2>&1; then
    step "Backup disk not mounted — unlocking"
    progress phase "unlock"
    if [[ -n $SOURCE_PART ]]; then
      "$OMARCHY_TM_ROOT/mount.sh" mount --disk "/dev/$(lsblk -n -o PKNAME "$SOURCE_PART" | head -1)"
    else
      "$OMARCHY_TM_ROOT/mount.sh" mount
    fi
  fi
  ensure_rw_mount "$MNT"
  findmnt -n "$MNT" >/dev/null 2>&1 || fail_backup "The backup disk isn't mounted. Unplug it, plug it back in, and try again."
  { touch "$MNT/.oma-write-test" && rm -f "$MNT/.oma-write-test"; } 2>/dev/null ||
    fail_backup "The backup disk can't be written to. Unplug it, plug it back in, and try again."
  if [[ ! -f $OMA_CURRENT_CAPSULE && -n $want && -z $SOURCE_PART ]]; then
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
    warn "The Pi's gatekeeper is out of date, so old restore points weren't tidied up."
    warn "Update it by running this on the Pi: $(pi_update_cmd)"
    return 0
  fi
  plan="$(d_list_json | jq -r '.[].timestamp' |
    "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/retention.py" plan --mode "$mode")"
  # Two kinds of restore point thinning must never touch. The one a restore
  # is still mid-way through (partial-restore.json), and the ones earmarked
  # because a restore deliberately left something behind on them — those are
  # the only copy of what was left out, and the system carries on backing up
  # around them (kept-points.json, written by the plugin).
  local protect_json
  protect_json="$(
    {
      jq -r '.snapshot // empty' "$OMARCHY_TM_STATE/partial-restore.json" 2>/dev/null || true
      "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/kept_points.py" --list 2>/dev/null |
        jq -r 'keys[]?' 2>/dev/null || true
    } | grep -E '^[0-9]{8}T[0-9]{6}Z$' | jq -R . | jq -s 'unique'
  )"
  if [[ $(jq 'length' <<<"$protect_json") -gt 0 ]]; then
    # Intersect with what is actually on the disk first, or a restore point
    # deleted by hand would inflate the "Keep:" count in the dry run for good.
    plan="$(jq --argjson p "$protect_json" '
      ($p - ($p - (.keep + .thin + .space_order))) as $k
      | .thin -= $k | .space_order -= $k | .keep = (.keep + $k | unique)' <<<"$plan")"
    log_file "thinning will not touch: $(jq -r 'join(" ")' <<<"$protect_json")"
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
  refuse_if_partial_restore peek
  require_root "${ORIG_ARGS[@]}"
  refuse_if_partial_restore
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
  rsync_link_flags
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

  # Both bars need to know the size of the job before the copying starts.
  # Steps already finished by an earlier attempt are not measured again.
  plan_progress
  progress phase "measure"
  step "Working out how much there is to copy"
  # An incremental reuses the previous run's size and skips the dry-run
  # walk. The copy still walks the tree once, and rsync still counts the
  # files exactly; only the byte total is last time's. That size is only
  # trusted with the skip list it was measured under: un-skipping a big
  # folder would otherwise leave the bar hundreds of GB short.
  seed_or_measure() {
    local step=$1 src=$2 ex=$3 known=0 want had
    want="$(skip_list_id "$ex")"
    known="$(jq -r --arg s "$step" '.[$s] // 0' "$OMARCHY_TM_STATE/last-sizes.json" 2>/dev/null || echo 0)"
    had="$(jq -r --arg s "${step}_skips" '.[$s] // ""' "$OMARCHY_TM_STATE/last-sizes.json" 2>/dev/null || true)"
    if [[ $known =~ ^[0-9]+$ && $known -gt 0 && -n $want && $had == "$want" ]]; then
      progress seed "$step" "$known"
      log_file "using the last backup's size for $step ($known bytes)"
      return 0
    fi
    measure_tree "$src" "$ex" "$step"
  }
  if [[ $HOME_ONLY != 1 ]]; then
    if ! is_done os; then
      seed_or_measure os "$SRC_TOP/$SNAP_SUB/os-$ts" "$EX_OS"
    fi
  fi
  if ! is_done home; then
    seed_or_measure home "$SRC_TOP/$SNAP_SUB/home-$ts" "$EX_HOME"
  fi
  if ! is_done esp; then
    measure_tree /boot "" esp
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
    local esp_dest=esp/current esp_rc=0
    [[ $esp_subvol == 1 ]] || { esp_dest="esp/$ts"; d_mkdir "$esp_dest"; }
    # Same rule as rsync_tree: 23 and 24 are warnings, anything else is a
    # failed backup. The status used to be thrown away, so a broken boot
    # copy was still saved as a valid restore point.
    set +e
    set +o pipefail
    rsync "${RSYNC_RSH[@]}" "${RSYNC_LINK[@]}" -a --delete --partial --no-inc-recursive --info=progress2 \
      /boot/ "$(d_target "$esp_dest")/" \
      2>&1 | "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/progress.py" stream esp
    esp_rc=${PIPESTATUS[0]}
    set -o pipefail
    set -e
    if [[ $esp_rc -ne 0 && $esp_rc -ne 23 && $esp_rc -ne 24 ]]; then
      fail_backup "$(rsync_failure_text "$esp_rc")"
    fi
    if [[ $esp_rc -ne 0 ]]; then
      warn "rsync boot files finished with warnings (exit $esp_rc) — restore point will still be saved"
    fi
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
  [[ $size_os =~ ^[0-9]+$ ]] || size_os=0
  [[ $size_home =~ ^[0-9]+$ ]] || size_home=0
  # Kept for the next incremental, which skips the measuring walk when a
  # size is already here. A home-only run must not wipe a real OS size.
  # Remembering the size is not the backup: a failure here still finishes.
  local sizes_file="$OMARCHY_TM_STATE/last-sizes.json"
  jq empty "$sizes_file" 2>/dev/null || echo '{}' >"$sizes_file"
  jq --argjson os "$size_os" --argjson home "$size_home" \
    --arg os_skips "$(skip_list_id "$EX_OS")" --arg home_skips "$(skip_list_id "$EX_HOME")" \
    'if $os > 0 then .os = $os | .os_skips = $os_skips else . end
     | if $home > 0 then .home = $home | .home_skips = $home_skips else . end' \
    "$sizes_file" >"$sizes_file.tmp" && chmod 644 "$sizes_file.tmp" && mv "$sizes_file.tmp" "$sizes_file" \
    || log_file "couldn't remember this backup's size for next time"
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
    # A forced backup settles the question: this system is the real one now,
    # so the plugin stops offering "Restore my files" and automatic backups
    # start again. Cleared after the prune above, so the restore point the
    # files are still in survives this run rather than being thinned on the
    # way out.
    if [[ $FORCE_AFTER_RESTORE == 1 && -f $OMARCHY_TM_STATE/partial-restore.json ]]; then
      keep_forced_point
      rm -f "$OMARCHY_TM_STATE/partial-restore.json"
      log_file "partial-restore marker cleared by a forced backup"
    fi
  fi
  cache_remote_df
  [[ $DEST_REMOTE == 1 ]] && remote_refresh_addresses || true
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

BROWSE_DIR="$OMA_BROWSE_DIR"
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

# Tidying up after a browse, as one function rather than a string of commands
# in the trap. Under `set -e` a failing command in a trap takes the rest of
# the trap with it, and the first thing here is an unmount that routinely
# fails: systemd's SIGTERM reaches sshfs and this script at the same moment,
# so by the time this runs the mount is often already gone. That left the
# state file behind (which pauses every automatic backup, for good), the
# mount point behind, and — the one that matters — the disk on the Pi
# unlocked, because remote_close never got its turn.
browse_cleanup() {
  local mp=${1:-}
  if [[ -n $mp ]]; then
    fusermount3 -u "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
    rmdir "$mp" 2>/dev/null || true
  fi
  rm -f "$BROWSE_STATE" 2>/dev/null || true
  release_source
  # With a mark of our own, letting go is safe whatever else is going on: the
  # gatekeeper locks the disk when the last user leaves, not the first. Without
  # one, the old guard stands -- and it only ever asked about backups, which is
  # exactly how closing a browse session locked the disk out from under a
  # models put-back and threw away everything it had copied.
  if ((${REMOTE_HOLD_ISSUED:-0})); then
    remote_close || true
  else
    backup_running || remote_close || true
  fi
}

# Open one restore point's copy of the user's home folder, read-only, until
# stopped (the plugin starts/stops oma-backups-browse@TS.service).
cmd_browse() {
  local ts=${1:-} user=${SUDO_USER:-${USER:-}}
  [[ $ts =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "usage: oma-backups browse TIMESTAMP"
  OMARCHY_TM_ALLOW_USER_DRY_RUN=0 require_root "${ORIG_ARGS[@]}"
  [[ $user =~ ^[a-z_][a-z0-9_-]*$ && $user != root ]] || die "couldn't tell whose files to open"
  mkdir -p "$BROWSE_DIR"
  chmod 755 "$BROWSE_DIR"
  BROWSE_STATE="$BROWSE_DIR/$ts.json"
  rm -f "$BROWSE_STATE"

  close_stale_mapper "$LUKS_MAPPER"
  pick_source "$ts"
  open_destination

  if [[ $DEST_REMOTE != 1 ]]; then
    local path="$MNT/home/$ts/$user"
    # Not through browse_cleanup: that takes the error away with it, before
    # the panel has read it.
    [[ -d $path ]] || { release_source; fail_backup "No copy of your home folder in that restore point."; }
    trap 'browse_cleanup' EXIT
    browse_state ready "$path"
    # Nothing to hold open for a plugged-in disk; just wait to be stopped.
    sleep infinity &
    wait $! || true
    return 0
  fi

  local gate_ver
  gate_ver="$(rgate version 2>/dev/null || echo 0)"
  [[ $gate_ver -ge 3 ]] ||
    fail_backup "The Pi needs updating to open restore points. Run this on it: $(pi_update_cmd)"
  command -v sshfs >/dev/null || fail_backup "sshfs isn't installed (run: sudo oma-backups link --refresh)."
  local mp="$BROWSE_DIR/$ts" pid
  mkdir -p "$mp"
  # Leave the disk unlocked if a backup is mid-way; it locks it when done.
  trap 'browse_cleanup "$mp"' EXIT
  # allow_other + default_permissions: mounted by root, readable by the user
  # exactly as far as each file's own owner/permissions allow.
  sshfs -f -o ro,allow_other,default_permissions,reconnect \
    -o ssh_command="$(remote_rsh)" -o sftp_server="/browse $ts $user" \
    "$(remote_target):/data" "$mp" 2>>"$OMARCHY_TM_LOG" &
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

# After a quick restore: put back what restore-to-disk left in the system area
# (AI models, listed as skipped_system in partial-restore.json). The plugin's
# "Restore my files" runs this in a terminal before bringing the files back,
# and it needs root because those folders belong to a system service. When
# it's done it takes them off the list, and removes the marker altogether if
# the files are already back (files_done).
cmd_put_back_system() {
  local marker="$OMARCHY_TM_STATE/partial-restore.json" snap rel was_active=0 failed=0 remaining
  local -a paths=()
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo
    gum style --bold "Putting your AI models back"
    gum style --foreground 8 "  The quick restore left your AI models on the backup so you could get"
    gum style --foreground 8 "  going sooner. They live in the system area (Ollama keeps them there,"
    gum style --foreground 8 "  not in your home folder), so putting them back needs your password."
    gum style --foreground 8 "  If you'd rather not now, press Ctrl+C: your files still come back, and"
    gum style --foreground 8 "  the panel offers \"Put AI models back\" for later."
    echo
  fi
  require_root "${ORIG_ARGS[@]}"
  snap="$(jq -r '.snapshot // empty' "$marker" 2>/dev/null || true)"
  mapfile -t paths < <(jq -r '.skipped_system // [] | .[]' "$marker" 2>/dev/null || true)
  if [[ -z $snap || ${#paths[@]} -eq 0 ]]; then
    gum style --foreground 8 "  Nothing to put back: no AI models were left on the backup."
    return 0
  fi
  for rel in "${paths[@]}"; do
    # Written by restore-to-disk, but it is a file in the user's home: never
    # let it name anything outside the system folders models live in.
    [[ $rel =~ ^(var|usr|opt|srv)/[A-Za-z0-9._/-]+$ && $rel != *..* ]] ||
      die "partial-restore.json lists a folder that isn't allowed: $rel"
  done
  [[ $snap =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "partial-restore.json names a restore point that isn't one: $snap"
  backup_running && die "A backup is running. Try again once it has finished."

  NOT_A_BACKUP=1
  FAIL_TITLE="Couldn't put your AI models back."
  close_stale_mapper "$LUKS_MAPPER"
  pick_source "$snap"
  rsync_link_flags
  open_destination
  if [[ -n $SOURCE_PART ]]; then trap release_source EXIT; fi
  d_exists "os/$snap" || fail_backup "The restore point $snap isn't on the backup any more."

  # Ollama holds its models open; stop it while they're copied.
  if systemctl is-active --quiet ollama.service 2>/dev/null; then
    was_active=1
    step "Stopping Ollama while its models are copied"
    systemctl stop ollama.service || true
  fi
  for rel in "${paths[@]}"; do
    step "Copying /$rel from $snap"
    mkdir -p "$(dirname "/$rel")"
    if ! rsync "${RSYNC_RSH[@]}" "${RSYNC_LINK[@]}" -aHAX --numeric-ids --info=progress2 \
      "$(d_target "os/$snap/$rel")"/ "/$rel/"; then
      warn "Couldn't copy /$rel."
      failed=1
    fi
  done
  if ((was_active)); then
    step "Starting Ollama again"
    systemctl start ollama.service || warn "Ollama didn't start again. Try: sudo systemctl start ollama"
  fi
  ((failed)) && fail_backup "Some models didn't copy. Nothing was removed; press \"Put AI models back\" to try again. Details are in $OMARCHY_TM_LOG."

  # Rewritten in place so the file keeps its owner (the user's plugin clears it).
  remaining="$(jq 'del(.skipped_system)' "$marker")"
  if [[ $(jq -r '.files_done // false' <<<"$remaining") == true ]]; then
    rm -f "$marker"
    log_file "AI models put back from $snap; restore complete, partial-restore marker cleared"
  else
    printf '%s\n' "$remaining" >"$marker"
    log_file "AI models put back from $snap"
  fi
  echo
  gum style --bold --foreground 2 "● Your AI models are back."
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
  [[ -n $snap ]] || die "usage: oma-backups files TIMESTAMP [PATH]"
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
  [[ -n $snap && -n $src && -n $dest ]] || die "usage: oma-backups copy TIMESTAMP SRC DEST"
  findmnt -n "$MNT" >/dev/null 2>&1 || die "not mounted"
  local from="$MNT/home/$snap/$src"
  [[ -e $from ]] || die "not in snapshot: $src"
  mkdir -p "$(dirname "$dest")"
  rsync -a --info=progress2 "$from" "$dest"
  log "copied $src from $snap -> $dest"
}

case "$MODE" in
  list) cmd_list ;;
  files) cmd_files "$@" ;;
  copy) cmd_copy "$@" ;;
  backup) cmd_backup ;;
  prune) cmd_prune ;;
  browse) cmd_browse "$@" ;;
  put_back_system) cmd_put_back_system ;;
esac
