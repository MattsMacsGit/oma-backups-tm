#!/usr/bin/env bash
# Link this laptop to its backup disk, once, so everyday actions never ask
# for a password again.
#
#   oma-backups link             add this laptop's unlock key to the backup disk
#                                (asks for its password once if needed), install
#                                the services, and let this user run them
#   oma-backups link --refresh   after updating OmaBackups: refresh the root-owned
#                                copy and the services, change nothing else
#
# The polkit rule lets only this user, only from an active local session,
# start/stop only the OmaBackups services: back up now, stop, open a restore
# point read-only, the hourly check. Setting up or erasing a disk, restoring,
# and pairing a Pi still ask for a password.
set -euo pipefail

OMARCHY_TM_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export OMARCHY_TM_ROOT
# shellcheck source=lib/common.sh
source "$OMARCHY_TM_ROOT/lib/common.sh"
# shellcheck source=lib/remote.sh
source "$OMARCHY_TM_ROOT/lib/remote.sh"

UNIT_DIR=/etc/systemd/system
POLKIT_RULE=/etc/polkit-1/rules.d/50-oma-backups.rules
UDEV_RULE=/etc/udev/rules.d/99-oma-backups.rules
OMA_LINKED=/etc/omarchy-backups/linked.json

REFRESH=0 QUIET=0
for a in "$@"; do
  case "$a" in
    --refresh) REFRESH=1 ;;
    --quiet) QUIET=1 ;;
    *) die "usage: oma-backups link [--refresh]" ;;
  esac
done

press_enter() {
  [[ $QUIET == 1 ]] && return 0
  [[ -r /dev/tty ]] && read -r -p "Press Enter to close." _ </dev/tty || true
}

fail() {
  echo
  gum style --bold --foreground 1 "Couldn't link this laptop."
  gum style --foreground 8 "$*"
  press_enter
  exit 1
}

write_units() {
  local user=$1 base=$OMA_ROOT_COPY/omarchy-backups
  cat >"$UNIT_DIR/oma-backups-backup.service" <<EOF
[Unit]
Description=OmaBackups backup
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=SUDO_USER=$user
Environment=OMARCHY_TM_UNATTENDED=1
ExecStart=$base backup --yes
# Stop exits 143 on purpose, after tidying up. Not a failure.
SuccessExitStatus=143
# Tidying up after a Stop can wait on the other end: locking a disk on a Pi
# takes seconds, and a lock has to queue behind an unlock still in flight.
# Never inherit a short DefaultTimeoutStopSec here -- being killed in the
# middle of that is what leaves a disk unlocked.
TimeoutStopSec=180
EOF
  cat >"$UNIT_DIR/oma-backups-browse@.service" <<EOF
[Unit]
Description=OmaBackups: open restore point %i read-only
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Environment=SUDO_USER=$user
Environment=OMARCHY_TM_UNATTENDED=1
ExecStart=$base browse %i
TimeoutStopSec=30
EOF
  cat >"$UNIT_DIR/oma-backups-scheduled.service" <<EOF
[Unit]
Description=OmaBackups automatic backup
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=SUDO_USER=$user
Environment=OMARCHY_TM_UNATTENDED=1
ExecStart=$base schedule run
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
SuccessExitStatus=143
TimeoutStopSec=180
EOF
  cat >"$UNIT_DIR/oma-backups-scheduled.timer" <<'EOF'
[Unit]
Description=OmaBackups automatic backup check

[Timer]
OnCalendar=hourly
Persistent=true
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
EOF
  chmod 644 "$UNIT_DIR"/oma-backups-*.service "$UNIT_DIR"/oma-backups-*.timer
  systemctl daemon-reload
  # Always on: `schedule run` exits at once unless the user switched it on.
  systemctl enable --now oma-backups-scheduled.timer >/dev/null 2>&1 || true
}

# Stops the desktop auto-mounting our own partitions and popping a window for
# each one. The tool mounts what it needs itself.
write_udev_rule() {
  local src=$OMARCHY_TM_ROOT/share/99-oma-backups.rules
  [[ -f $src ]] || return 0
  install -d -m 755 "$(dirname "$UDEV_RULE")"
  install -m 644 "$src" "$UDEV_RULE"
  udevadm control --reload >/dev/null 2>&1 || true
  # Existing disks keep the old flags until they're re-probed.
  udevadm trigger --subsystem-match=block >/dev/null 2>&1 || true
}

write_polkit_rule() {
  local user=$1
  install -d -m 750 -g polkitd "$(dirname "$POLKIT_RULE")" 2>/dev/null || true
  cat >"$POLKIT_RULE.tmp" <<EOF
// OmaBackups: let $user run everyday backup actions without a password, only
// from an active local session. Setting up or erasing disks, restoring and
// pairing still ask. Written by \`oma-backups link\`; removed by uninstall.sh.
polkit.addRule(function (action, subject) {
  if (action.id !== "org.freedesktop.systemd1.manage-units") return;
  if (subject.user !== "$user" || !subject.local || !subject.active) return;
  var verb = action.lookup("verb");
  if (verb !== "start" && verb !== "stop") return;
  var unit = action.lookup("unit");
  if (unit === "oma-backups-backup.service" || unit === "oma-backups-scheduled.service" ||
      /^oma-backups-browse@[0-9]{8}T[0-9]{6}Z\.service$/.test(unit))
    return polkit.Result.YES;
});
EOF
  chmod 644 "$POLKIT_RULE.tmp"
  mv "$POLKIT_RULE.tmp" "$POLKIT_RULE"
}

main() {
  require_root "$@"
  local user=${SUDO_USER:-}
  if [[ -z $user && -f $OMA_LINKED ]]; then
    user="$(jq -r '.user // empty' "$OMA_LINKED")"
  fi
  [[ $user =~ ^[a-z_][a-z0-9_-]*$ && $user != root ]] ||
    die "run this as your normal user; it asks for sudo itself"

  # Opening restore points on a paired Pi mounts them with sshfs.
  if remote_configured; then ensure_deps sshfs; fi

  if [[ $REFRESH == 1 ]]; then
    [[ -f $OMA_LINKED ]] || die "this laptop isn't linked yet: run oma-backups link"
    refresh_root_copy
    write_units "$user"
    write_polkit_rule "$user"
    write_udev_rule
    [[ $QUIET == 1 ]] || echo "Updated the copy automatic and password-free backups run from."
    return 0
  fi

  [[ $QUIET == 1 ]] || { echo; gum style --bold "Link this laptop to its backup disk"; echo; }
  local part
  part="$(capsule_luks_partition 2>/dev/null || true)"
  if [[ -n $part && -b $part ]]; then
    ensure_capsule_key "$part" || fail "Couldn't add the unlock key (wrong password?)."
  elif ! remote_configured; then
    fail "Plug in the backup USB first, so this laptop's unlock key can be added to it."
  fi

  step "Installing the backup services"
  refresh_root_copy
  write_units "$user"
  step "Letting $user run them without a password"
  write_polkit_rule "$user"
  write_udev_rule
  jq -n --arg u "$user" --arg at "$(ts)" '{user: $u, linked_at: $at}' >"$OMA_LINKED.tmp"
  chmod 644 "$OMA_LINKED.tmp"
  mv "$OMA_LINKED.tmp" "$OMA_LINKED"

  if [[ $QUIET != 1 ]]; then
    echo
    gum style --bold --foreground 2 "● This laptop is linked."
    gum style --foreground 8 "  Backing up, stopping and opening restore points no longer ask for a password."
    press_enter
  fi
}

main "$@"
