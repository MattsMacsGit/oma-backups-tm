#!/usr/bin/env bash
# Fallback if the TUI is missing. Prefer: python3 /opt/omarchy-backups/lib/restore_tui.py
exec python3 /opt/omarchy-backups/lib/restore_tui.py "$@"
