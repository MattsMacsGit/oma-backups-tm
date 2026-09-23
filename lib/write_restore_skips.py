#!/usr/bin/env python3
"""Read or write the list of things to leave out of "Restore my files".

Separate from the backup skip list on purpose. That one answers "is this
worth keeping a copy of"; this one answers "will this fit on the disk I am
restoring onto, today". It lives in the state folder next to
partial-restore.json because it belongs to one restore and goes with it.

  write_restore_skips.py --list          print the file (one entry per line)
  write_restore_skips.py PATH [PATH...]  replace it with these entries
  write_restore_skips.py                 empty it

Entries are rsync filter patterns relative to the home folder inside the
restore point: "/Videos" for one picked folder, ".cache" for a pattern that
matches at any depth.
"""
from pathlib import Path
import os
import sys

HEADER = "# OmaBackups: left out of Restore my files — one entry per line\n"


def state_file() -> Path:
    home = Path(os.environ.get("HOME") or Path.home())
    return home / ".local" / "state" / "omarchy-backups" / "restore-skips.txt"


def main() -> int:
    p = state_file()
    if sys.argv[1:2] == ["--list"]:
        sys.stdout.write(p.read_text(encoding="utf-8") if p.is_file() else HEADER)
        return 0
    p.parent.mkdir(parents=True, exist_ok=True)
    entries = [a for a in sys.argv[1:] if a]
    p.write_text(HEADER + ("\n".join(entries) + "\n" if entries else ""), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
