#!/usr/bin/env bash
# Automatic backups. A root systemd timer fires every hour; `run` decides
# whether a backup is actually due from the user's settings (lib/schedule.py,
# edited from the plugin), so changing how often needs no root.
#
#   oma-backups schedule enable    install the timer, add this laptop's key to
#                                  a plugged-in backup USB (asks for its password once)
#   oma-backups schedule disable
#   oma-backups schedule status
#   oma-backups schedule run       what the timer runs
set -euo pipefail

OMARCHY_TM_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export OMARCHY_TM_ROOT
# shellcheck source=lib/common.sh
source "$OMARCHY_TM_ROOT/lib/common.sh"
# shellcheck source=lib/remote.sh
source "$OMARCHY_TM_ROOT/lib/remote.sh"

TIMER=/etc/systemd/system/oma-backups-scheduled.timer

settings() {
  "$OMARCHY_TM_PYTHON" "$OMARCHY_TM_ROOT/lib/schedule.py" "$@"
}

press_enter() {
  [[ -r /dev/tty ]] && read -r -p "Press Enter to close." _ </dev/tty || true
}

fail() {
  echo
  gum style --bold --foreground 1 "Couldn't turn on automatic backups."
  gum style --foreground 8 "$*"
  press_enter
  exit 1
}

cmd_enable() {
  require_root enable

  echo
  gum style --bold "Turn on automatic backups"
  echo
  # Linking installs the hourly check and the unlock key; after that the
  # plugin's switch just flips the setting.
  "$OMARCHY_TM_ROOT/link.sh" --quiet ||
    fail "Plug in the backup USB (or pair a Pi) first, so this laptop's unlock key can be added to it."
  settings set enabled true

  echo
  gum style --bold --foreground 2 "● Automatic backups are on ($(settings get every))."
  gum style --foreground 8 "  Change how often in the plugin's Settings. Backups skip quietly when the"
  gum style --foreground 8 "  disk isn't reachable or the battery is under 20%."
  press_enter
}

cmd_disable() {
  settings set enabled false
  echo "Automatic backups are off."
}

last_success() {
  local f="$OMARCHY_TM_STATE/last-success" v
  v="$(cat "$f" 2>/dev/null || true)"
  [[ $v =~ ^[0-9]+$ ]] && echo "$v" || echo 0
}

cmd_status() {
  local installed=false
  [[ -f $TIMER ]] && installed=true
  settings get | jq -c --argjson installed "$installed" --argjson last "$(last_success)" \
    '. + {installed: $installed, last_success: $last}'
}

on_low_battery() {
  local b
  for b in /sys/class/power_supply/*; do
    [[ $(cat "$b/type" 2>/dev/null) == Battery ]] || continue
    if [[ $(cat "$b/status" 2>/dev/null) == Discharging ]] &&
      (($(cat "$b/capacity" 2>/dev/null || echo 100) < 20)); then
      return 0
    fi
  done
  return 1
}

# Nag once three intervals have passed without a successful backup (3 hours
# for hourly, 3 days for daily, 3 weeks for weekly); at most once a day.
nag_if_overdue() {
  local why=$1 interval=$2 since=$3 now
  now=$(date +%s)
  ((now - since >= 3 * interval)) || return 0
  local when="never"
  (($(last_success) > 0)) && when="$(date -d "@$(last_success)" '+%a %d %b, %H:%M')"
  notify_user "No backup for a while" "Last backup: $when. $why" overdue
}

cmd_run() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "schedule run is started by the system timer"
  local s interval since last now grace
  s="$(settings get)"
  [[ $(jq -r .enabled <<<"$s") == true ]] || exit 0
  interval=$(jq -r .interval <<<"$s")
  last=$(last_success)
  since=$(jq -r .enabled_at <<<"$s")
  ((last > since)) && since=$last
  now=$(date +%s)
  # Due a little early rather than a whole timer tick late. The timer's
  # random delay can leave two ticks under an hour apart, so on the hourly
  # setting the margin must be wider than that jitter or a tick is turned
  # away and the backup waits another whole hour.
  grace=$((interval / 12))
  ((grace < 600)) && grace=600
  ((now - last >= interval - grace)) || exit 0

  # Only ever back up a system that is at rest. Anything of ours already in
  # flight means wait for the next tick, never elbow in alongside it.
  local pidf other
  pidf="$(pid_file)"
  other="$(tr -d '[:space:]' <"$pidf" 2>/dev/null || true)"
  # backup_pid_alive, not pid_alive: a recycled process number used to look
  # like a backup that never ended, and automatic backups then stopped
  # happening at all until the next reboot.
  if [[ -n $other ]] && backup_pid_alive "$other"; then
    exit 0
  fi
  # A restore point open for browsing holds the backup disk (or the Pi's)
  # unlocked, and this backup would lock it again on its way out — from under
  # the window someone is still reading. It is a deliberate, short-lived
  # thing, so wait quietly for the next tick rather than nagging about it.
  if browse_in_progress; then
    log_file "scheduled backup skipped: a restore point is open"
    exit 0
  fi

  # A system restored without its files must never back up on its own: it
  # would push that gap over the real backup. Only bringing the files back,
  # or a deliberate forced backup, starts automatic backups again. Ctrl-
  # forcing is a manual act by design, so it never reaches this path.
  if [[ -s $OMARCHY_TM_STATE/partial-restore.json ]]; then
    log_file "scheduled backup skipped: this system was restored without its files"
    local what="This system was restored without your files. Open OmaBackups and press \"Restore my files\"."
    [[ $(jq -r '.files_done // false' "$OMARCHY_TM_STATE/partial-restore.json" 2>/dev/null) == true ]] &&
      what="Your AI models are still on the backup. Open OmaBackups and press \"Put AI models back\"."
    notify_user "Automatic backups are paused" "$what" partial-restore
    exit 0
  fi

  local why=""
  if on_low_battery; then
    why="The battery is under 20%."
  elif capsule_is_not_the_recorded_one; then
    why="The backup disk plugged in isn't the one you set up."
  elif [[ -n $(capsule_luks_partition 2>/dev/null || true) ]]; then
    :
  elif remote_configured; then
    remote_load
    if [[ $(rgate status 2>/dev/null | jq -r .present 2>/dev/null) != true ]]; then
      why="The backup disk on $REMOTE_HOST couldn't be reached."
    fi
  else
    why="The backup disk isn't plugged in."
  fi
  if [[ -n $why ]]; then
    log_file "scheduled backup skipped: $why"
    nag_if_overdue "$why" "$interval" "$since"
    exit 0
  fi

  log_file "scheduled backup starting"
  # Marks this run as automatic: backup.sh must not honour a force note here.
  if ! OMARCHY_TM_SCHEDULED=1 "$OMARCHY_TM_ROOT/backup.sh" --yes; then
    log_file "scheduled backup failed"
    nag_if_overdue "The last automatic backup failed." "$interval" "$since"
    exit 1
  fi
}

sub=${1:-}
shift || true
case "$sub" in
  enable) cmd_enable ;;
  disable) cmd_disable ;;
  status) cmd_status ;;
  run) cmd_run ;;
  *) die "usage: oma-backups schedule enable | disable | status | run" ;;
esac
