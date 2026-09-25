#!/usr/bin/env python3
"""List restore points that actually exist on the backup disk.

Finds the disk at /run/omarchy-backups or a desktop automount
(/run/media/$USER/OmaBackups). machine.json is metadata only.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

TS_RE_LEN = len("20260913T074631Z")


def is_ts(name: str) -> bool:
    if len(name) != TS_RE_LEN or name[8] != "T" or not name.endswith("Z"):
        return False
    try:
        datetime.strptime(name, "%Y%m%dT%H%M%SZ")
        return True
    except ValueError:
        return False


def weekday_local(ts: str) -> str:
    dt = datetime.strptime(ts, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc).astimezone()
    return f"{dt.strftime('%A')} {dt.day} {dt.strftime('%b')}  {dt.strftime('%H:%M')}"


def login_name() -> str:
    return os.environ.get("SUDO_USER") or os.environ.get("USER") or ""


def find_mount() -> Path | None:
    candidates: list[Path] = []
    env = os.environ.get("OMARCHY_TM_MNT")
    if env:
        candidates.append(Path(env))
    candidates.append(Path("/run/omarchy-backups"))
    media = Path("/run/media")
    if media.is_dir():
        try:
            users = list(media.iterdir())
        except OSError:
            users = []
        for userdir in users:
            for name in ("OmaBackups", "OMARCHY-TM", "OMARCHY-BACKUPS"):
                candidates.append(userdir / name)
    seen: set[str] = set()
    for p in candidates:
        try:
            key = str(p.resolve()) if p.exists() else str(p)
        except OSError:
            key = str(p)
        if key in seen:
            continue
        seen.add(key)
        if looks_like_capsule(p):
            return p
    return None


def looks_like_capsule(p: Path) -> bool:
    try:
        if not p.is_dir():
            return False
        return (p / "home").is_dir() or (p / "os").is_dir() or (p / "meta").is_dir()
    except OSError:
        return False


def _listdir(folder: Path) -> list[Path]:
    try:
        return list(folder.iterdir())
    except OSError:
        return []


def scan(mnt: Path) -> list[dict]:
    home = mnt / "home"
    osdir = mnt / "os"
    esp = mnt / "esp"
    meta_path = mnt / "meta" / "machine.json"
    meta_by_ts: dict[str, dict] = {}
    try:
        if meta_path.is_file():
            data = json.loads(meta_path.read_text(encoding="utf-8"))
            for s in data.get("snapshots") or []:
                ts = s.get("timestamp")
                if ts:
                    meta_by_ts[ts] = s
    except (OSError, json.JSONDecodeError):
        pass

    stamps: set[str] = set()
    for folder in (home, osdir, esp):
        if not folder.is_dir():
            continue
        for child in _listdir(folder):
            if child.name == "current":
                continue
            if is_ts(child.name):
                stamps.add(child.name)

    user = login_name()
    out = []
    for ts in sorted(stamps, reverse=True):
        has_home = (home / ts).is_dir()
        has_os = (osdir / ts).is_dir()
        has_esp = (esp / ts).is_dir()
        if not has_home and not has_os:
            continue
        home_only = has_home and not has_os
        valid = has_home and has_os and has_esp
        meta = meta_by_ts.get(ts) or {}
        open_path = home / ts
        if user and (open_path / user).is_dir():
            open_path = open_path / user
        out.append(
            {
                "timestamp": ts,
                "label": weekday_local(ts),
                "valid": valid,
                "home_only": home_only,
                "has_home": has_home,
                "has_os": has_os,
                "has_esp": has_esp,
                "omarchy_version": meta.get("omarchy_version") or "",
                "kernel": meta.get("kernel") or "",
                # Computed once, at backup time, from a fresh btrfs
                # subvolume (see backup.sh) — never recomputed here, this
                # is just carrying the stored value forward on every
                # rescan so a live du/qgroup walk never sits on this
                # frequently-polled path. null for snapshots taken
                # before this field existed.
                "size_total": meta.get("size_total"),
                "size_exclusive": meta.get("size_exclusive"),
                "mount": str(mnt),
                "open_path": str(open_path),
            }
        )
    return out


def cache_path() -> Path:
    sudo = os.environ.get("SUDO_USER")
    if sudo and os.geteuid() == 0:
        try:
            import pwd

            home = Path(pwd.getpwnam(sudo).pw_dir)
        except KeyError:
            home = Path("/tmp")
    else:
        home = Path(os.environ.get("HOME") or ".")
    return home / ".local" / "state" / "omarchy-backups" / "snapshots.json"


def _write_if_changed(path: Path, text: str) -> None:
    """Atomic, readable by the user, and left alone when nothing changed —
    the panel watches these files, and detect runs every two seconds."""
    try:
        if path.read_text(encoding="utf-8") == text:
            return
    except OSError:
        pass
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, 0o644)
    if os.geteuid() == 0:
        st = path.parent.stat()
        os.chown(tmp, st.st_uid, st.st_gid)
    tmp.replace(path)


# Each backup disk, and a paired Pi, keeps its own list. There used to be one
# list, holding whichever disk was read last: unplug the USB and the panel
# went on showing its restore points under the Pi's name. A list is only ever
# shown for the disk the next backup would actually go to (see detect.py).
REMOTE_CONF = Path("/etc/omarchy-backups/remote.json")


def remote_key() -> str | None:
    """The paired Pi's list, tied to the disk it was paired with."""
    try:
        j = json.loads(REMOTE_CONF.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(j, dict) or not j.get("host"):
        return None
    return "remote-" + str(j.get("luks_uuid") or j["host"])


def disk_key(luks_uuid: str | None) -> str | None:
    return f"disk-{luks_uuid}" if luks_uuid else None


def mount_luks_uuid(mnt: Path) -> str | None:
    """The LUKS partition under a mounted backup disk: which disk this is."""
    import subprocess

    try:
        src = subprocess.run(["findmnt", "-n", "-o", "SOURCE", str(mnt)],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        if not src:
            return None
        out = subprocess.run(["lsblk", "-n", "-s", "-r", "-o", "UUID,FSTYPE", src],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.splitlines():
        bits = line.split()
        if len(bits) == 2 and bits[1] == "crypto_LUKS":
            return bits[0]
    return None


def saved_path(key: str) -> Path:
    safe = "".join(c if c.isalnum() or c in "._-" else "_" for c in key)
    return cache_path().parent / f"points-{safe}.json"


def load_saved(key: str | None) -> list[dict] | None:
    """That disk's list as last read, or None if it never has been."""
    if not key:
        return None
    try:
        rows = json.loads(saved_path(key).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return rows if isinstance(rows, list) else None


def save_list(key: str | None, rows: list[dict]) -> None:
    """Remember what is on that disk, without showing it."""
    if not key:
        return
    try:
        _write_if_changed(saved_path(key), json.dumps(rows) + "\n")
    except OSError:
        pass


def write_cache(rows: list[dict], key: str | None = None) -> None:
    """The list the panel shows, and (given the disk it came from) that
    disk's own saved copy."""
    save_list(key, rows)
    try:
        body = json.dumps(rows) + "\n"
        path = cache_path()
        lines = [f"{s.get('label') or s['timestamp']} | {s['timestamp']}" for s in rows]
        _write_if_changed(path.with_suffix(".txt"), ("\n".join(lines) + "\n") if lines else "")
        _write_if_changed(path, body)
    except OSError:
        pass


def print_human(rows: list[dict]) -> None:
    if not rows:
        print("No restore points on this disk.")
        return
    for s in rows:
        print(f"{s['label']} | {s['timestamp']}")


def open_snapshot(ts: str) -> int:
    import subprocess

    mnt = find_mount()
    if mnt is None:
        print("backup disk is not mounted — unlock it in Files first", file=sys.stderr)
        return 2
    user = login_name()
    candidates = []
    if user:
        candidates.append(mnt / "home" / ts / user)
    candidates.append(mnt / "home" / ts)
    for p in candidates:
        if p.is_dir():
            subprocess.Popen(["xdg-open", str(p)])
            print(p)
            return 0
    print(f"no home folder for {ts} on the backup disk", file=sys.stderr)
    return 1


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("mount", nargs="?", default="")
    p.add_argument("--json", action="store_true")
    p.add_argument("--open", metavar="TIMESTAMP")
    p.add_argument("--stdin", action="store_true", help="rows as JSON on stdin (remote capsule)")
    args = p.parse_args()
    if args.open:
        return open_snapshot(args.open)
    if args.stdin:
        rows = json.load(sys.stdin)
        write_cache(rows, remote_key())
        if args.json:
            json.dump(rows, sys.stdout)
            sys.stdout.write("\n")
        else:
            print_human(rows)
        return 0
    if args.mount:
        mnt = Path(args.mount)
        if not looks_like_capsule(mnt):
            write_cache([])
            if args.json:
                json.dump([], sys.stdout)
                sys.stdout.write("\n")
            else:
                print("No restore points on this disk.")
            return 0
    else:
        found = find_mount()
        if found is None:
            # Keep the last list. Unmounted ≠ wiped.
            txt = cache_path().with_suffix(".txt")
            cached = cache_path()
            if args.json:
                if cached.is_file():
                    sys.stdout.write(cached.read_text(encoding="utf-8") or "[]\n")
                else:
                    json.dump([], sys.stdout)
                    sys.stdout.write("\n")
                return 0
            if txt.is_file():
                body = txt.read_text(encoding="utf-8")
                if body.strip():
                    sys.stdout.write(body)
                    if not body.endswith("\n"):
                        sys.stdout.write("\n")
                    return 0
            print("backup disk not mounted", file=sys.stderr)
            return 0
        mnt = found
    rows = scan(mnt)
    write_cache(rows, disk_key(mount_luks_uuid(mnt)))
    if args.json:
        json.dump(rows, sys.stdout)
        sys.stdout.write("\n")
    else:
        print_human(rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
