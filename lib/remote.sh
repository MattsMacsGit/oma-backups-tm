# shellcheck shell=bash
# A paired remote capsule: the backup USB plugged into an always-on Pi that
# runs pi/oma-gate. remote.json is readable by the plugin; everything under
# remote/ (SSH key, disk unlock key) is root-only.

OMA_REMOTE_CONF=/etc/omarchy-backups/remote.json
OMA_REMOTE_DIR=/etc/omarchy-backups/remote
OMA_REMOTE_KEY=$OMA_REMOTE_DIR/id_ed25519
OMA_REMOTE_KNOWN=$OMA_REMOTE_DIR/known_hosts
OMA_REMOTE_ACCOUNT=omabackups
OMA_REPO_RAW="${OMA_REPO_RAW:-https://raw.githubusercontent.com/MattsMacsGit/oma-backups-tm/main}"

REMOTE_HOST=""
REMOTE_SSH=()

remote_configured() {
  [[ -f $OMA_REMOTE_CONF && -f $OMA_REMOTE_KEY ]] && capsule_key_present
}

remote_load() {
  REMOTE_HOST="$(jq -r '.host // empty' "$OMA_REMOTE_CONF")"
  local port
  port="$(jq -r '.port // 22' "$OMA_REMOTE_CONF")"
  [[ -n $REMOTE_HOST ]] || die "$OMA_REMOTE_CONF has no host"
  REMOTE_SSH=(ssh -i "$OMA_REMOTE_KEY" -p "$port" -l "$OMA_REMOTE_ACCOUNT"
    -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR
    -o ServerAliveInterval=15 -o ServerAliveCountMax=4
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$OMA_REMOTE_KNOWN"
    # One connection for the whole backup instead of a new handshake for
    # each of the dozen small gatekeeper calls (slow over a network). Every
    # command still goes through the gatekeeper on the Pi. Root-only socket.
    -o ControlMaster=auto -o ControlPath=/run/omarchy-backups-ssh-%C -o ControlPersist=60)
}

# Run one gatekeeper verb on the Pi, e.g. `rgate snapshot home/current home/TS`.
rgate() {
  "${REMOTE_SSH[@]}" "$REMOTE_HOST" "$@"
}

# The same ssh command as one string, for rsync -e (no paths contain spaces).
remote_rsh() {
  printf '%s' "${REMOTE_SSH[*]}"
}
