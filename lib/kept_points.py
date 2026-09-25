#!/usr/bin/env python3
"""Restore points this machine must never thin away.

A quick restore onto a smaller disk leaves things behind on purpose. Once
the rest is back the system is whole enough to carry on backing up — but the
restore point those left-out things came from is now the only copy of them,
and smart thinning would eventually take it. So it gets earmarked here and
prune_restore_points leaves it alone, for as long as the user wants it.

  kept_points.py --list                       print the file as JSON
  kept_points.py --add TS [--source ID] [ENTRY...]
                                              earmark TS, noting what is on it
                                              and which disk it is on
  kept_points.py --set-skip TS [ENTRY...]     what to leave out next time TS
                                              is restored from (the panel's list)
  kept_points.py --remove TS                  let TS be thinned again

Lives beside partial-restore.json in the user's own state folder, so the
plugin (running as that user) can write it and a root prune can read it.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

STAMP = re.compile(r"^\d{8}T\d{6}Z$")


def state_file() -> Path:
    # SUDO_USER first: a root prune reads the list of the user it belongs to.
    sudo = os.environ.get("SUDO_USER")
    if sudo and os.geteuid() == 0:
        import pwd

        try:
            home = Path(pwd.getpwnam(sudo).pw_dir)
        except KeyError:
            home = Path(os.environ.get("HOME", str(Path.home())))
    else:
        home = Path(os.environ.get("HOME", str(Path.home())))
    return home / ".local" / "state" / "omarchy-backups" / "kept-points.json"


def load(p: Path) -> dict:
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    # Only ever hand back real timestamps: this file is read by a root prune.
    return {k: v for k, v in data.items() if STAMP.match(str(k))}


def save(p: Path, data: dict) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, p)


def main() -> int:
    argv = sys.argv[1:]
    cmd = argv[0] if argv else "--list"
    p = state_file()
    data = load(p)
    if cmd == "--list":
        json.dump(data, sys.stdout)
        sys.stdout.write("\n")
        return 0
    ts = argv[1] if len(argv) > 1 else ""
    if not STAMP.match(ts):
        print("not a restore point: " + ts, file=sys.stderr)
        return 2
    if cmd == "--add":
        from datetime import datetime, timezone

        rest = argv[2:]
        source = ""
        # Entries are paths (they start with "/"), so the flag can't be one.
        if len(rest) >= 2 and rest[0] == "--source":
            source, rest = rest[1], rest[2:]
        old = data.get(ts) if isinstance(data.get(ts), dict) else {}
        data[ts] = {
            "since": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "reason": "left-out",
            "left_out": [a for a in rest if a],
        }
        # The leave-out list someone chose for it outlives a re-mark.
        if isinstance(old.get("skip"), list):
            data[ts]["skip"] = old["skip"]
        # Which disk it is on (backup.sh's dest_id), so going back for what
        # was left out reads from that disk, wherever backups go by then.
        if re.match(r"^(local|remote):", source):
            data[ts]["source"] = source
    elif cmd == "--set-skip":
        if ts not in data:
            print("not kept: " + ts, file=sys.stderr)
            return 1
        data[ts]["skip"] = [a for a in argv[2:] if a]
    elif cmd == "--remove":
        data.pop(ts, None)
    else:
        print("usage: kept_points.py --list | --add TS [--source ID] [ENTRY...] | --set-skip TS [ENTRY...] | --remove TS", file=sys.stderr)
        return 2
    save(p, data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
