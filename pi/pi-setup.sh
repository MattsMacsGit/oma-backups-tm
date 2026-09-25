#!/usr/bin/env bash
# Make a Raspberry Pi (Raspberry Pi OS / Debian) an always-on OmaBackups
# target. The laptop's pairing step prints the exact command, e.g.
#
#   curl -fsSL .../pi/pi-setup.sh | sudo bash -s -- --uuid UUID --key 'ssh-ed25519 ...'
#   curl -fsSL .../pi/pi-setup.sh | sudo bash -s -- --update     (newer gatekeeper, same pairing)
#   curl -fsSL .../pi/pi-setup.sh | sudo bash -s -- --uninstall
#
# Only installs what's missing (never upgrades), never touches Docker or any
# other disk. The laptop's key can only run oma-gate (see pi/oma-gate).
set -euo pipefail

REPO_RAW="${OMA_REPO_RAW:-https://raw.githubusercontent.com/MattsMacsGit/oma-backups-tm/main}"
ACCOUNT=omabackups
ACCOUNT_HOME=/var/lib/oma-backups
LIB=/usr/local/lib/oma-backups
GATE=$LIB/oma-gate
CONF_DIR=/etc/oma-backups
SUDOERS=/etc/sudoers.d/oma-backups

say() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\033[2m  %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  %s\033[0m\n' "$*"; }
die() {
  printf '\033[31m%s\033[0m\n' "$*" >&2
  exit 1
}

UUID="" KEY="" UNINSTALL=0 UPDATE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uuid) UUID=${2:-}; shift 2 ;;
    --key) KEY=${2:-}; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --update) UPDATE=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run this with sudo."
command -v apt-get >/dev/null || die "This script is for Raspberry Pi OS / Debian."

gate_as_account() {
  sudo -u "$ACCOUNT" env SSH_ORIGINAL_COMMAND="$1" sudo -n "$GATE"
}

if [[ $UNINSTALL == 1 ]]; then
  say "Removing OmaBackups from this Pi"
  if [[ -x $GATE ]]; then
    SSH_ORIGINAL_COMMAND=lock "$GATE" 2>/dev/null || true
  fi
  systemctl disable --now oma-gate-sweep.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/oma-gate-sweep.timer /etc/systemd/system/oma-gate-sweep.service
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -f "$SUDOERS"
  id "$ACCOUNT" >/dev/null 2>&1 && userdel -r "$ACCOUNT" 2>/dev/null || true
  rm -rf "$LIB" "$CONF_DIR"
  say "Done. Installed packages (btrfs-progs, cryptsetup-bin) were left in place."
  exit 0
fi

if [[ $UPDATE == 1 ]]; then
  [[ -f $CONF_DIR/gate.conf && -x $GATE ]] ||
    die "Nothing to update: this Pi isn't set up yet. Pair it from the laptop first."
  say "Updating OmaBackups on this Pi"
else
  [[ $UUID =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]] ||
    die "Missing or malformed --uuid (copy the full command from the laptop)."
  [[ $KEY =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+(\ [A-Za-z0-9@._-]+)?$ ]] ||
    die "Missing or malformed --key (copy the full command from the laptop)."
  say "Setting up this Pi as an OmaBackups target"
fi

need=()
command -v btrfs >/dev/null || need+=(btrfs-progs)
command -v cryptsetup >/dev/null || need+=(cryptsetup-bin)
command -v rrsync >/dev/null || need+=(rsync)
command -v python3 >/dev/null || need+=(python3)
# Opening restore points from the laptop: a sandboxed, read-only SFTP server.
command -v bwrap >/dev/null || need+=(bubblewrap)
[[ -x /usr/lib/openssh/sftp-server ]] || need+=(openssh-sftp-server)
if [[ ${#need[@]} -gt 0 ]]; then
  step "Installing ${need[*]} (nothing else is upgraded)"
  apt-get update -qq
  # needrestart would otherwise restart services (Docker included) after install.
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
    apt-get install -y -qq --no-upgrade --no-install-recommends "${need[@]}" >/dev/null
fi
command -v rrsync >/dev/null ||
  die "rsync here has no rrsync (needs Raspberry Pi OS / Debian 12 Bookworm or newer)."
for m in btrfs dm_crypt; do
  modprobe "$m" || die "This kernel can't load $m."
done

step "Installing the gatekeeper"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
here=""
[[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]] && here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for f in pi/oma-gate lib/list_snapshots.py; do
  if [[ -n $here && -f $here/$f ]]; then
    cp "$here/$f" "$tmp/"
  else
    curl -fsSL "$REPO_RAW/$f" -o "$tmp/$(basename "$f")" || die "Could not download $f."
  fi
done
python3 -m py_compile "$tmp/oma-gate" "$tmp/list_snapshots.py" || die "Downloaded files are broken."
install -d -m 755 "$LIB"
install -m 755 "$tmp/oma-gate" "$GATE"
install -m 644 "$tmp/list_snapshots.py" "$LIB/list_snapshots.py"

# The safety net behind the marks: everything that opens the disk leaves one
# and takes it away again, but something can always be killed before it gets
# the chance. This closes a disk nobody is holding once it has also been quiet
# for ten minutes -- both, so a slow transfer is never cut off.
step "Installing the idle lock"
cat >/etc/systemd/system/oma-gate-sweep.service <<UNIT
[Unit]
Description=OmaBackups: lock the backup disk when nobody is using it

[Service]
Type=oneshot
Environment=SSH_ORIGINAL_COMMAND=sweep
ExecStart=$GATE
UNIT
cat >/etc/systemd/system/oma-gate-sweep.timer <<'UNIT'
[Unit]
Description=OmaBackups: check every minute whether the backup disk can be locked

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now oma-gate-sweep.timer >/dev/null 2>&1 ||
  warn "Couldn't start the idle lock timer, so the disk locks the moment the last user lets go instead of after 10 quiet minutes."

if [[ $UPDATE == 1 ]]; then
  v=$(gate_as_account version) || die "Self-test failed: the gatekeeper didn't answer."
  echo
  say "Updated. Gatekeeper version $v."
  exit 0
fi

install -d -m 700 "$CONF_DIR"
printf 'uuid=%s\n' "$UUID" >"$CONF_DIR/gate.conf"
chmod 600 "$CONF_DIR/gate.conf"

step "Creating the $ACCOUNT account (key-only, gatekeeper-only)"
if ! id "$ACCOUNT" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "$ACCOUNT_HOME" --shell /bin/sh \
    --comment "OmaBackups remote target" "$ACCOUNT"
fi
# "*" = no password but not "locked", which some sshd setups refuse keys for.
usermod -p '*' "$ACCOUNT"
install -d -m 700 -o "$ACCOUNT" -g "$ACCOUNT" "$ACCOUNT_HOME/.ssh"
printf 'restrict,command="sudo -n %s" %s\n' "$GATE" "$KEY" >"$ACCOUNT_HOME/.ssh/authorized_keys"
chown "$ACCOUNT:$ACCOUNT" "$ACCOUNT_HOME/.ssh/authorized_keys"
chmod 600 "$ACCOUNT_HOME/.ssh/authorized_keys"

cat >"$tmp/sudoers" <<EOF
Defaults!$GATE env_keep += "SSH_ORIGINAL_COMMAND"
$ACCOUNT ALL=(root) NOPASSWD: $GATE
EOF
visudo -cqf "$tmp/sudoers" || die "Generated sudoers rule is invalid; nothing was changed."
install -m 440 "$tmp/sudoers" "$SUDOERS"

if sshd_cfg=$(sshd -T 2>/dev/null); then
  if grep -qiE '^(allowusers|allowgroups) ' <<<"$sshd_cfg" && ! grep -qiE "^allowusers .*\b$ACCOUNT\b" <<<"$sshd_cfg"; then
    warn "sshd has AllowUsers/AllowGroups set; add $ACCOUNT there or the laptop can't log in."
  fi
  grep -qi '^pubkeyauthentication no' <<<"$sshd_cfg" && warn "sshd has PubkeyAuthentication off; the laptop can't log in."
fi

step "Checking the gatekeeper"
[[ $(gate_as_account version) =~ ^[0-9]+$ ]] || die "Self-test failed: the gatekeeper didn't answer."
present=$(gate_as_account status | python3 -c 'import json,sys; print(json.load(sys.stdin)["present"])')

echo
say "This Pi is ready."
if [[ $present == True ]]; then
  step "The backup disk is already plugged in."
else
  step "Now plug in the backup disk. The laptop does the rest."
fi
warn "Plugging a USB-powered drive into a shared hub can briefly knock the other"
warn "drives on it offline. Stop services that use them first (e.g. Docker), or"
warn "give the backup disk its own power."
