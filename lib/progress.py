#!/usr/bin/env python3
"""Write /run/omarchy-backups.status JSON for the plugin.

One bar per step, never a guessed overall figure:
  progress.py phase STEP          a step with nothing to measure ("busy")
  progress.py set STEP PCT        a step that reports its own percentage
  progress.py stream STEP [FILE]  rsync --info=progress2 on stdin; FILE gets
                                  rsync's "Total file size" when it finishes
  progress.py done | idle | fail MESSAGE

For rsync the bar is the larger of files-checked and bytes-copied, held so it
never moves backwards within a step: on an incremental backup bytes-copied
barely moves (almost nothing changed) while files-checked does, and switching
between the two made the bar jump around. Never calls du.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path

STATUS = Path(os.environ.get("OMARCHY_TM_STATUS_FILE", "/run/omarchy-backups.status"))

RSYNC_RE = re.compile(
    r"^\s*(?P<bytes>\d+)\s+(?P<pct>\d+)%(?:\s+(?P<speed>\S+/s))?(?:\s+(?P<eta>\d+:\d+(?::\d+)?))?"
)
TOCHK_RE = re.compile(r"to-chk=(?P<left>\d+)/(?P<total>\d+)")
TOTAL_RE = re.compile(r"^Total file size:\s*(?P<n>\d+)")

LABEL = {
    "unlock": "Unlocking the backup disk",
    "prepare": "Getting ready",
    "resume": "Carrying on where it stopped",
    "stopping": "Stopping and locking the backup disk",
    "snapshot": "Taking a snapshot of this computer",
    "os": "Copying system files",
    "home": "Copying your files",
    "esp": "Copying boot files",
    "rescue": "Updating the rescue USB",
    "finalize": "Saving the restore point",
    "tidy": "Tidying up old restore points",
    "setup": "Setting up the backup disk",
    "waiting-input": "Waiting for you — enter the new disk password",
}
# Steps with a real percentage; every other step is shown as "working".
BAR_STEPS = {"os", "home", "esp", "setup"}
WRITE_EVERY = 0.5


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
    # "at" lets the plugin tell this attempt's error from a leftover one.
    data = dict(data, at=int(time.time()))
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


def label(step: str) -> str:
    return LABEL.get(step, step or "Backing up")


def status(step: str, pct: int | None = None, detail: str = "", speed: str = "", eta: str = "") -> dict:
    busy = pct is None
    shown = 0 if busy else max(0, min(100, pct))
    return {
        "running": True,
        "phase": step,
        "label": label(step),
        "busy": busy,
        "percent": shown,
        "detail": detail,
        "speed": speed,
        "eta": eta,
        "line": label(step) if busy else f"{label(step)}  {shown}%",
    }


def human(n: int) -> str:
    size = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:.0f} {unit}" if unit in ("B", "KB") else f"{size:.1f} {unit}"
        size /= 1024
    return f"{n} B"


class RsyncProgress:
    """Turns rsync --info=progress2 lines into a bar that only moves forward."""

    def __init__(self, step: str) -> None:
        self.step = step
        self.best = 0
        self.last_write = 0.0
        self.total_size: int | None = None

    def feed(self, line: str) -> dict | None:
        compact = line.replace(",", "")
        t = TOTAL_RE.search(compact.strip())
        if t:
            self.total_size = int(t.group("n"))
            return None
        m = RSYNC_RE.search(compact)
        c = TOCHK_RE.search(compact)
        if not m and not c:
            return None
        byte_pct = int(m.group("pct")) if m else 0
        file_pct = 0
        if c and int(c.group("total")) > 0:
            left, total = int(c.group("left")), int(c.group("total"))
            file_pct = int(100 * (total - left) / total)
        pct = max(byte_pct, file_pct)
        # rsync reports 100% on its very last line; don't show it early.
        if pct >= 100 and not (c and int(c.group("left")) == 0):
            pct = 99
        self.best = max(self.best, pct)
        parts = []
        if m:
            parts.append(f"{human(int(m.group('bytes')))} copied")
            if m.group("speed"):
                parts.append(m.group("speed"))
        # rsync's ETA assumes every byte must be copied; it only means
        # something when copying (not checking) is what's moving the bar.
        eta = m.group("eta") if m and byte_pct >= file_pct and m.group("eta") else ""
        if eta.strip("0:") == "":
            eta = ""
        if eta:
            parts.append(f"about {eta} left")
        return status(self.step, self.best, "  ·  ".join(parts),
                      (m.group("speed") or "") if m else "", eta)

    def maybe_write(self, data: dict, force: bool = False) -> None:
        now = time.monotonic()
        if force or now - self.last_write >= WRITE_EVERY:
            write(data)
            self.last_write = now


def stream(step: str, stats_file: str | None) -> int:
    prog = RsyncProgress(step)
    write(status(step, 0))
    leftover = ""
    last = None
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
                data = prog.feed(line)
                if data:
                    last = data
                    prog.maybe_write(data)
    if last:
        prog.maybe_write(last, force=True)
    if stats_file and prog.total_size is not None:
        Path(stats_file).write_text(f"{prog.total_size}\n", encoding="utf-8")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        return 1
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "idle":
        write({"running": False, "phase": "idle", "label": "", "busy": False, "percent": 0,
               "detail": "", "speed": "", "eta": "", "line": ""})
    elif cmd == "phase":
        step = args[0] if args else ""
        write(status(step, 0 if step in BAR_STEPS else None))
    elif cmd == "set":
        step = args[0] if args else ""
        pct = int(args[1]) if len(args) > 1 and args[1].isdigit() else 0
        write(status(step, pct, speed=args[2] if len(args) > 2 else "", eta=args[3] if len(args) > 3 else ""))
    elif cmd == "done":
        write({"running": False, "phase": "done", "label": "Done", "busy": False, "percent": 100,
               "detail": "", "speed": "", "eta": "0:00", "line": "Done"})
    elif cmd == "fail":
        write({"running": False, "phase": "error", "label": "", "busy": False, "percent": 0,
               "detail": "", "speed": "", "eta": "", "line": " ".join(args) or "Setup failed"})
    elif cmd == "stream":
        return stream(args[0] if args else "rsync", args[1] if len(args) > 1 else None)
    else:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
