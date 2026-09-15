#!/usr/bin/env python3
"""Run rsync on a PTY so progress2 always emits; update plugin status JSON."""

from __future__ import annotations

import os
import pty
import re
import sys

_LIB = os.path.dirname(os.path.abspath(__file__))
if _LIB not in sys.path:
    sys.path.insert(0, _LIB)
from progress import write as write_status  # noqa: E402

# rsync progress2:  1,234,567  45%  12.34MB/s    0:01:23 (xfr#1, to-chk=1/2)
LINE_RE = re.compile(
    rb"(?P<pct>\d+)\s*%\s+(?P<speed>\S+/s)\s+(?P<eta>\d+:\d+(?::\d+)?)"
)


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: rsync_progress.py PHASE -- rsync ...", file=sys.stderr)
        return 2
    # PHASE -- rsync args
    try:
        sep = sys.argv.index("--")
    except ValueError:
        print("missing --", file=sys.stderr)
        return 2
    phase = sys.argv[1]
    cmd = sys.argv[sep + 1 :]
    write_status(
        {"running": True, "phase": phase, "percent": 0, "speed": "", "eta": "", "line": ""}
    )

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(cmd[0], cmd)
        os._exit(127)

    leftover = b""
    while True:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        # Show in the terminal (CR progress looks normal there).
        try:
            os.write(sys.stdout.fileno(), chunk)
        except OSError:
            pass
        leftover += chunk.replace(b"\r", b"\n")
        while b"\n" in leftover:
            raw, leftover = leftover.split(b"\n", 1)
            m = LINE_RE.search(raw.replace(b",", b""))
            if not m:
                continue
            write_status(
                {
                    "running": True,
                    "phase": phase,
                    "percent": int(m.group("pct")),
                    "speed": m.group("speed").decode("ascii", "replace"),
                    "eta": m.group("eta").decode("ascii", "replace"),
                    "line": raw.decode("utf-8", "replace").strip(),
                }
            )

    _, status = os.waitpid(pid, 0)
    rc = os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else (status >> 8)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
