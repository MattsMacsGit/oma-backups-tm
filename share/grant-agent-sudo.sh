#!/usr/bin/env bash
# One-time: passwordless sudo for this testrig user so the agent can work.
# Safe on this throwaway OS. Do not copy this to a real machine.
set -euo pipefail
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  exec sudo -k "$0" "$@"
fi
install -m 0440 /dev/stdin /etc/sudoers.d/test-yolo <<'EOF'
# testrig only — OmaBackups development
test ALL=(ALL) NOPASSWD: ALL
EOF
visudo -cf /etc/sudoers.d/test-yolo
echo "Passwordless sudo is on for user test. The agent can continue."
