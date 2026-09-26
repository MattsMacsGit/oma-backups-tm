#!/usr/bin/env python3
"""Check skip-paths vs compiled excludes vs files on the mounted dest."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compile_excludes import load_paths, split_paths, user_home  # noqa: E402


def dest_home() -> Path | None:
    candidates = [
        Path("/run/omarchy-backups/home/current"),
    ]
    media = Path("/run/media")
    if media.is_dir():
        for userdir in media.iterdir():
            for name in ("OmaBackups", "OMARCHY-TM", "OMARCHY-BACKUPS"):
                candidates.append(userdir / name / "home" / "current")
    for p in candidates:
        if p.is_dir():
            return p
    return None


def nonempty(p: Path) -> bool:
    if p.is_file() and p.stat().st_size:
        return True
    if p.is_dir():
        try:
            return any(p.iterdir())
        except OSError:
            return False
    return False


def explain(home: Path) -> None:
    """Plain sentences for the failures a person actually hits.

    These do not change the exit code. The skip-list check below still does.
    """
    marker = home / ".local" / "state" / "omarchy-backups" / "partial-restore.json"
    if marker.is_file() and marker.stat().st_size:
        print("Backups are paused. This system was restored without all of its files.")
        print("  Open OmaBackups and press \"Restore my files\".")
    gate = home / ".local" / "state" / "omarchy-backups" / "pi-gate.json"
    try:
        data = json.loads(gate.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        data = None
    if isinstance(data, dict) and data.get("behind") is True:
        print(
            f"The Pi's gatekeeper is v{data.get('version')}. This laptop wants v{data.get('want')}."
        )
        print("  One session can still lock the disk out from under another.")
        if data.get("update"):
            print("  Update it by running this on the Pi: " + str(data["update"]))
    logs = [
        Path("/var/log/omarchy-backups/oma-backups.log"),
        home / ".local" / "state" / "omarchy-backups" / "oma-backups.log",
    ]
    for log in logs:
        try:
            blob = log.read_bytes()[-200_000:]
        except OSError:
            continue
        for line in reversed(blob.decode("utf-8", "replace").splitlines()):
            if " ERROR " in line:
                print("Last error: " + line.strip())
                return


def main() -> int:
    home = user_home()
    explain(home)
    etc_home = Path("/etc/omarchy-backups/excludes-home.txt")
    etc_os = Path("/etc/omarchy-backups/excludes-os.txt")
    user_home_ex = home / ".config" / "omarchy-backups" / "excludes-home.txt"
    # Each backup disk has its own list: check against the one the last
    # compile used, which it names in its header.
    skip = home / ".config" / "omarchy-backups" / "skip-paths.txt"
    for f in (etc_home, user_home_ex):
        try:
            head = f.read_text(encoding="utf-8", errors="replace").splitlines()[:3]
        except OSError:
            continue
        named = [ln.split(":", 1)[1].strip() for ln in head if ln.startswith("# skip list:")]
        if named and Path(named[0]).is_file():
            skip = Path(named[0])
            break
    dest = dest_home()
    paths = load_paths(skip)
    want_home, want_os = split_paths(paths, Path("/home"))
    compiled_home = load_paths(user_home_ex) if user_home_ex.is_file() else []
    got_home = load_paths(etc_home) if etc_home.is_file() else []
    got_os = load_paths(etc_os) if etc_os.is_file() else []

    print(f"skip-paths:     {skip} ({len(paths)} user entries)")
    for p in paths:
        print(f"  {p}")
    print(f"user compiled:  {compiled_home}")
    print(f"/etc home:      {got_home}")
    print(f"/etc os:        {got_os}")
    print(f"user home skips:{want_home}")
    print(f"user os skips:  {want_os}")

    rc = 0
    missing = [p for p in want_home if p not in compiled_home and p not in got_home]
    if missing:
        print(f"FAIL: compiled excludes missing user skips {missing}")
        rc = 1
    elif want_home and not compiled_home and not got_home:
        print("FAIL: skip-paths has entries but no compiled excludes")
        rc = 1
    else:
        print("OK:   compiled excludes include user skip-paths")

    if os.geteuid() == 0 and not os.environ.get("SUDO_USER"):
        print("FAIL: running as root with no SUDO_USER (skip list would be /root)")
        rc = 1

    if dest is None:
        print("The backup disk is not mounted, so your files can't be compared with the backup.")
        return rc

    print(f"dest: {dest}")
    for rel in want_home:
        p = dest / rel
        bad = nonempty(p)
        print(f"  skip {rel}: dest {'HAS FILES (bad)' if bad else 'empty/absent (ok)'}")
        if bad:
            rc = 1

    live = Path("/home")
    login = os.environ.get("SUDO_USER") or os.environ.get("USER") or "test"
    for name in (f"{login}/Pictures", f"{login}/Videos"):
        if name in want_home:
            continue
        live_p = live / name
        dest_p = dest / name
        live_has = nonempty(live_p)
        dest_has = nonempty(dest_p)
        if live_has and not dest_has:
            print(f"  FAIL: live has {name} but dest current does not")
            rc = 1
        elif live_has and dest_has:
            print(f"  OK:   {name} present on dest (not skipped)")
        elif not live_has:
            print(f"  skip-check {name}: live empty (nothing to compare)")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
