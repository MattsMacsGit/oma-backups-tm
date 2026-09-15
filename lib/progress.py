#!/usr/bin/env python3
"""Write /run/omarchy-backups.status JSON for the plugin.

Each phase (os / home / rescue) is its own 0–100 bar, matching rsync.
Uses rsync's % when it moves, otherwise to-chk=left/total.
Never calls du.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

STATUS = Path(os.environ.get("OMARCHY_TM_STATUS_FILE", "/run/omarchy-backups.status"))

RSYNC_RE = re.compile(
    r"(?P<pct>\d+)\s*%(?:\s+(?P<speed>\S+/s))?(?:\s+(?P<eta>\d+:\d+(?::\d+)?))?"
)
TOCHK_RE = re.compile(r"to-chk=(?P<left>\d+)/(?P<total>\d+)")

PHASE_LABEL = {
    "os": "OS",
    "home": "Home",
    "esp": "Boot",
    "rescue": "Rescue",
    "snapshot": "Snapshot",
    "unlock": "Unlock",
    "setup": "Setting up USB",
    "finalize": "Finish",
}


def _user_status_path() -> Path | None:
    sudo = os.environ.get("SUDO_USER")
    if not sudo:
        return None
    try:
        import pwd

        home = Path(pwd.getpwnam(sudo).pw_dir)
    except KeyError:
        return None
    return home / ".local" / "state" / "omarchy-backups" / "status.json"


def write(data: dict) -> None:
    payload = json.dumps(data) + "\n"
    STATUS.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(str(STATUS) + ".tmp")
    tmp.write_text(payload, encoding="utf-8")
    os.chmod(tmp, 0o644)
    tmp.replace(STATUS)
    user_path = _user_status_path()
    if user_path is None:
        return
    try:
        user_path.parent.mkdir(parents=True, exist_ok=True)
        utmp = user_path.with_suffix(".tmp")
        utmp.write_text(payload, encoding="utf-8")
        os.chmod(utmp, 0o644)
        st = os.stat(user_path.parent)
        os.chown(utmp, st.st_uid, st.st_gid)
        utmp.replace(user_path)
    except OSError:
        pass


def load() -> dict:
    try:
        return json.loads(STATUS.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _label(phase: str) -> str:
    return PHASE_LABEL.get(phase, phase or "backup")


def main() -> int:
    if len(sys.argv) < 2:
        return 1
    cmd = sys.argv[1]
    if cmd == "idle":
        write(
            {
                "running": False,
                "phase": "idle",
                "percent": 0,
                "speed": "",
                "eta": "",
                "line": "",
            }
        )
        return 0
    if cmd == "phase":
        phase = sys.argv[2] if len(sys.argv) > 2 else ""
        write(
            {
                "running": True,
                "phase": phase,
                "percent": 0,
                "speed": "",
                "eta": "",
                "line": _label(phase),
            }
        )
        return 0
    if cmd == "done":
        write(
            {
                "running": False,
                "phase": "done",
                "percent": 100,
                "speed": "",
                "eta": "0:00",
                "line": "Done",
            }
        )
        return 0
    if cmd == "fail":
        write(
            {
                "running": False,
                "phase": "error",
                "percent": 0,
                "speed": "",
                "eta": "",
                "line": " ".join(sys.argv[2:]) or "Setup failed",
            }
        )
        return 0
    if cmd == "set":
        phase = sys.argv[2] if len(sys.argv) > 2 else ""
        pct = int(sys.argv[3]) if len(sys.argv) > 3 and str(sys.argv[3]).isdigit() else 0
        write(
            {
                "running": True,
                "phase": phase,
                "percent": max(0, min(100, pct)),
                "speed": sys.argv[4] if len(sys.argv) > 4 else "",
                "eta": sys.argv[5] if len(sys.argv) > 5 else "",
                "line": f"{_label(phase)}  {pct}%",
            }
        )
        return 0
    if cmd == "rsync":
        _apply_rsync_line(sys.argv[2] if len(sys.argv) > 2 else "rsync", sys.argv[3] if len(sys.argv) > 3 else "")
        return 0
    if cmd == "stream":
        phase = sys.argv[2] if len(sys.argv) > 2 else "rsync"
        leftover = ""
        while True:
            chunk = sys.stdin.buffer.read1(256)
            if not chunk:
                break
            try:
                sys.stderr.buffer.write(chunk)
                sys.stderr.buffer.flush()
            except OSError:
                pass
            leftover += chunk.decode("utf-8", "replace").replace("\r", "\n")
            while "\n" in leftover:
                line, leftover = leftover.split("\n", 1)
                if line.strip():
                    _apply_rsync_line(phase, line)
        return 0
    return 1


def _apply_rsync_line(phase: str, line: str) -> None:
    compact = line.replace(",", "")
    m = RSYNC_RE.search(compact)
    speed = eta = ""
    pct = 0
    if m:
        pct = int(m.group("pct"))
        speed = m.group("speed") or ""
        eta = m.group("eta") or ""
    t = TOCHK_RE.search(compact)
    if t:
        left = int(t.group("left"))
        total = int(t.group("total"))
        if total > 0 and pct == 0:
            pct = max(0, min(100, int(round(100 * (total - left) / total))))
    if not m and not t:
        return
    write(
        {
            "running": True,
            "phase": phase,
            "percent": pct,
            "rsync_percent": pct,
            "speed": speed,
            "eta": eta,
            "line": f"{_label(phase)}  {pct}%",
        }
    )


if __name__ == "__main__":
    raise SystemExit(main())
