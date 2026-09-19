#!/usr/bin/env python3
"""Write ~/.config/omarchy-backups/skip-paths.txt from argv (absolute paths)."""
from pathlib import Path
import os
import sys

home = Path(os.environ.get("HOME") or Path.home())
p = home / ".config" / "omarchy-backups" / "skip-paths.txt"
p.parent.mkdir(parents=True, exist_ok=True)
paths = [a for a in sys.argv[1:] if a]
p.write_text("# OmaBackups skip list — one entry per line\n" + ("\n".join(paths) + "\n" if paths else ""), encoding="utf-8")
