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

REMOTE_HOST=""      # the name it was paired under: what the user sees
REMOTE_ADDR=""      # what we actually connect to, LAN address when it answers
REMOTE_SSH=()

# A LAN address the Pi answers on is worth preferring over the Tailscale name:
# the tunnel is slower and, on a Pi 4, tailscaled can peg a core during a big
# backup. The addresses come from the Pi itself (gatekeeper "addresses") at
# pairing time and are refreshed after each backup, so a new DHCP lease is
# picked up on its own. The pick is cached in /run for a few minutes, since
# remote_load runs many times per backup.
OMA_REMOTE_PICK=/run/omarchy-backups-remote-host
OMA_REMOTE_PICK_TTL=300

remote_configured() {
  [[ -f $OMA_REMOTE_CONF && -f $OMA_REMOTE_KEY ]] && capsule_key_present
}

# Every way a restore can have written down the paired Pi's disk (the dest_id
# form, one per line). The proper one is the name it was paired under plus
# its disk. Rescue sticks before 1.4.3 wrote whichever address they reached
# the Pi at, and no disk: those count when the address is one the Pi reported
# about itself. detect.py's remote_source_ids says the same.
remote_source_ids() {
  jq -r '"remote:\(.host // ""):\(.luks_uuid // "")",
    ([.host] + (.lan // []) | .[] | select(type == "string" and . != "") | "remote:\(.):")' \
    "$OMA_REMOTE_CONF" 2>/dev/null
}

remote_load() {
  REMOTE_HOST="$(jq -r '.host // empty' "$OMA_REMOTE_CONF")"
  local port
  port="$(jq -r '.port // 22' "$OMA_REMOTE_CONF")"
  [[ -n $REMOTE_HOST ]] || die "$OMA_REMOTE_CONF has no host"
  # A rescue stick reaches the Pi by whichever address works, so it checks
  # the Pi's key under a fixed name and never accepts a different one.
  local alias hostkey
  alias="$(jq -r '.host_key_alias // empty' "$OMA_REMOTE_CONF")"
  if [[ -n $alias ]]; then
    hostkey=(-o StrictHostKeyChecking=yes -o HostKeyAlias="$alias")
  else
    # Whichever address we end up on, check the Pi's key under the one name
    # it was paired as: moving between the LAN and Tailscale then doesn't
    # mean a second known_hosts entry (or a scary mismatch).
    hostkey=(-o StrictHostKeyChecking=accept-new -o HostKeyAlias="$REMOTE_HOST")
  fi
  REMOTE_SSH=(ssh -i "$OMA_REMOTE_KEY" -p "$port" -l "$OMA_REMOTE_ACCOUNT"
    -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR
    -o ServerAliveInterval=15 -o ServerAliveCountMax=4
    "${hostkey[@]}" -o UserKnownHostsFile="$OMA_REMOTE_KNOWN"
    # One connection for the whole backup instead of a new handshake for
    # each of the dozen small gatekeeper calls (slow over a network). Every
    # command still goes through the gatekeeper on the Pi. Root-only socket.
    #
    # One per job ($$), never shared between jobs. The first job to connect
    # owns the connection and it lives in that job's service, so when a
    # restore point was closed, systemd took the connection down with it --
    # and the models put-back that had been riding on it died mid-copy. The
    # gatekeeper's marks kept the disk open for it; the pipe was what went.
    -o ControlMaster=auto -o ControlPath="/run/omarchy-backups-ssh-$$-%C" -o ControlPersist=60)
  REMOTE_ADDR="$(remote_pick_addr)"
}

# LAN addresses the Pi reported about itself. Tailscale's own 100.64/10
# addresses are skipped: taking the tunnel is the thing we're avoiding.
remote_lan_addresses() {
  jq -r '(.lan // [])[]? | select(test("^100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.") | not)' \
    "$OMA_REMOTE_CONF" 2>/dev/null || true
}

# ssh's first value for an option wins, so the short timeout has to go in
# front of the defaults rather than after them.
remote_probe() {
  local out
  out="$("${REMOTE_SSH[@]:0:1}" -o ConnectTimeout=2 -o ControlPath=none \
    "${REMOTE_SSH[@]:1}" "$1" version 2>/dev/null)" || return 1
  [[ $out =~ ^[0-9]+$ ]]
}

remote_pick_addr() {
  local now cached_at cached a
  now=$(date +%s)
  if [[ -r $OMA_REMOTE_PICK ]]; then
    read -r cached_at cached 2>/dev/null <"$OMA_REMOTE_PICK" || true
    if [[ -n ${cached:-} && ${cached_at:-0} =~ ^[0-9]+$ ]] &&
      ((now - cached_at < OMA_REMOTE_PICK_TTL)); then
      printf '%s' "$cached"
      return 0
    fi
  fi
  for a in $(remote_lan_addresses); do
    [[ $a == "$REMOTE_HOST" ]] && continue
    if remote_probe "$a"; then
      printf '%s %s\n' "$now" "$a" >"$OMA_REMOTE_PICK" 2>/dev/null || true
      printf '%s' "$a"
      return 0
    fi
  done
  printf '%s %s\n' "$now" "$REMOTE_HOST" >"$OMA_REMOTE_PICK" 2>/dev/null || true
  printf '%s' "$REMOTE_HOST"
}

# Ask the Pi where it is now and remember it, so a changed lease doesn't
# quietly send every future backup back down the tunnel.
remote_refresh_addresses() {
  local addrs tmp
  addrs="$(rgate addresses 2>/dev/null || true)"
  jq -e 'type == "array"' <<<"$addrs" >/dev/null 2>&1 || return 0
  tmp="$OMA_REMOTE_CONF.tmp"
  jq --argjson lan "$addrs" '.lan = $lan' "$OMA_REMOTE_CONF" >"$tmp" 2>/dev/null || return 0
  chmod 644 "$tmp" && mv "$tmp" "$OMA_REMOTE_CONF"
}

# What this laptop's copy of the gatekeeper speaks. Older Pis still work,
# but they lock the disk when the first session finishes, not the last.
OMA_GATE_WANT=9

# The one-liner that updates (or with --uninstall, removes) the Pi's side.
# OMA_REPO_RAW is where this copy came from, so someone testing another
# branch points it there and gets that branch's gatekeeper.
pi_update_cmd() {
  printf 'curl -fsSL %s/pi/pi-setup.sh | sudo bash -s -- %s' "$OMA_REPO_RAW" "${1:---update}"
}

# Remember the version where the panel and doctor can read it. The SSH key
# is root-only, so a user-level poll cannot ask the Pi itself. --quiet
# records it without printing: the hourly check would say it every hour.
note_pi_gate() {
  local quiet=0
  if [[ ${1:-} == --quiet ]]; then quiet=1; shift; fi
  local v=${1:-0} f="$OMARCHY_TM_STATE/pi-gate.json" behind=false
  [[ $v =~ ^[0-9]+$ ]] || v=0
  # 0 means we never heard a version (Pi off, SSH down). That is not
  # "the Pi is old", and saying so every hour would be a false alarm.
  ((v > 0)) || return 0
  if ((v < OMA_GATE_WANT)); then
    behind=true
  fi
  # A note about the Pi must never stop the backup. mkdir/jq can fail, and
  # this function used to abort the whole run: `behind` is the word true or
  # false, and `((behind))` with `set -u` looks that word up as a variable.
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  jq -n --argjson v "$v" --argjson want "$OMA_GATE_WANT" --argjson behind "$behind" \
    --arg update "$(pi_update_cmd)" \
    '{version: $v, want: $want, behind: $behind, update: $update}' >"$f.tmp" \
    && chmod 644 "$f.tmp" && mv "$f.tmp" "$f" || return 0
  [[ $behind == true && $quiet == 0 ]] || return 0
  warn "The Pi's gatekeeper is v${v}. This laptop wants v${OMA_GATE_WANT}. One session can still lock the disk out from under another." || true
  gum style --foreground 8 "  Update it by running this on the Pi (keeps the pairing):" || true
  gum style --foreground 8 "  $(pi_update_cmd)" || true
  return 0
}

# Run one gatekeeper verb on the Pi, e.g. `rgate snapshot home/current home/TS`.
rgate() {
  "${REMOTE_SSH[@]}" "${REMOTE_ADDR:-$REMOTE_HOST}" "$@"
}

# The address to put in front of a remote path, for rsync and sshfs.
remote_target() {
  printf '%s' "${REMOTE_ADDR:-$REMOTE_HOST}"
}

# The same ssh command as one string, for rsync -e (no paths contain spaces).
remote_rsh() {
  printf '%s' "${REMOTE_SSH[*]}"
}
