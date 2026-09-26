#!/usr/bin/env python3
"""Write a skip list from argv (absolute paths or patterns).

  write_skip_paths.py [--dest DEST_ID] PATH ...

With --dest, the list is that backup disk's own (see skip_defaults.py);
without, it is skip-paths.txt, the list every disk starts from.
"""
from pathlib import Path
import os
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from skip_defaults import HEADER, disk_file, _owner  # noqa: E402

home = Path(os.environ.get("HOME") or Path.home())
args = sys.argv[1:]
dest = None
if args[:1] == ["--dest"]:
    dest, args = (args[1] if len(args) > 1 else ""), args[2:]
p = disk_file(home, dest) or home / ".config" / "omarchy-backups" / "skip-paths.txt"
p.parent.mkdir(parents=True, exist_ok=True)
paths = [a for a in args if a]
p.write_text(HEADER + "\n" + ("\n".join(paths) + "\n" if paths else ""), encoding="utf-8")
owner = _owner()
if owner:
    os.chown(p.parent, *owner)
    os.chown(p, *owner)
