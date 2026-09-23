#!/usr/bin/env python3
"""Seed the recommended quick-skips into skip-paths.txt, once, then print it.

Recommended skips used to be hardcoded in share/excludes-home.txt, where the
user could never turn them off. They now live in the skip list like any other
entry, so the plugin's switches really control them. A marker file makes this
a one-time seed: after that, a switch the user turned off stays off.
"""

from __future__ import annotations

import os
import pwd
import sys
from pathlib import Path

HEADER = "# OmaBackups skip list — one entry per line"

# rsync patterns (not absolute paths): each matches at any depth under /home.
RECOMMENDED = [
    "**/.local/share/Trash",
    ".Trash",
    ".cache",
    ".thumbnails",
    "lost+found",
]


def _owner() -> tuple[int, int] | None:
    sudo = os.environ.get("SUDO_USER")
    if os.geteuid() != 0 or not sudo:
        return None
    try:
        pw = pwd.getpwnam(sudo)
    except KeyError:
        return None
    return pw.pw_uid, pw.pw_gid


def flatpak_caches(home: Path) -> str:
    """The panel's Caches switch also covers each Flatpak app's cache, and only
    reads as on when every one of its paths is in the list: same spelling."""
    return str(home) + "/.var/app/*/cache"


def top_up_caches(home: Path, skip: Path, cfg: Path) -> None:
    """Once, for lists seeded before Flatpak caches joined the Caches switch.

    Someone with both .cache and .thumbnails still listed had Caches on (the
    switch adds and removes all of them together), so the switch went on
    reading off only because this path was missing.
    """
    marker = cfg / ".caches-topped-up"
    if marker.exists() or not skip.is_file():
        return
    lines = skip.read_text(encoding="utf-8").splitlines()
    present = {ln.strip() for ln in lines}
    extra = flatpak_caches(home)
    if {".cache", ".thumbnails"} <= present and extra not in present:
        skip.write_text("\n".join(lines + [extra]) + "\n", encoding="utf-8")
    marker.touch()
    owner = _owner()
    if owner:
        for p in (skip, marker):
            os.chown(p, *owner)


def seed(home: Path) -> Path:
    cfg = home / ".config" / "omarchy-backups"
    skip = cfg / "skip-paths.txt"
    marker = cfg / ".defaults-seeded"
    if marker.exists():
        top_up_caches(home, skip, cfg)
        return skip
    cfg.mkdir(parents=True, exist_ok=True)
    lines = skip.read_text(encoding="utf-8").splitlines() if skip.is_file() else [HEADER]
    # The first quick-skip switches wrote these absolute paths; the patterns
    # below cover them (and nested copies), so drop them to avoid duplicates.
    old = {str(home / ".cache"), str(home / ".local" / "share" / "Trash")}
    lines = [ln for ln in lines if ln.strip() not in old]
    present = {ln.strip() for ln in lines}
    lines += [p for p in RECOMMENDED + [flatpak_caches(home)] if p not in present]
    skip.write_text("\n".join(lines) + "\n", encoding="utf-8")
    marker.touch()
    (cfg / ".caches-topped-up").touch()
    owner = _owner()
    if owner:
        for p in (cfg, skip, marker, cfg / ".caches-topped-up"):
            os.chown(p, *owner)
    return skip


def main() -> int:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from compile_excludes import user_home

    skip = seed(user_home())
    sys.stdout.write(skip.read_text(encoding="utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
