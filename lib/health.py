#!/usr/bin/env python3
"""Is the backup disk still holding what was written to it?

btrfs keeps a checksum of every block it writes. A scrub reads everything
back and checks it: a block that no longer matches is a damaged file, found
before the day it's needed. A full read of a big disk takes hours (a Pi,
with no AES instructions, decrypts it in software), so it is done a slice a
night: each night's check carries on from where the last stopped, and a
full pass is every block checked once.

  health.py start MOUNT STATE MINUTES   carry the pass on (or begin a new
                                        one), running in the background
  health.py run MOUNT STATE MINUTES     the same, then wait: until it finishes,
                                        the time is up, or it is told to stop
                                        (SIGTERM) -- and settle
  health.py settle MOUNT STATE [--stop] fold what the scrub found into STATE
                                        (--stop: pause a running one first)
  health.py show STATE                  STATE as JSON, with its verdict

STATE is the JSON record of the disk's checks. The Pi's gatekeeper imports
this; on a USB disk backup.sh runs it. Everything here needs root.

The verdict:
  healthy   nothing wrong found
  warning   the disk has reported read or write errors (a flaky cable or a
            tired disk), but no file has been found damaged
  damaged   files on it no longer match what was written: don't trust it
  unknown   never checked
"""

from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

# btrfs scrub -c 3: the idle I/O class, so a backup or a film always comes first.
IDLE = ["-c", "3"]
ERRORS = ("csum_errors", "read_errors", "verify_errors", "super_errors",
          "uncorrectable_errors", "corrected_errors")
DEVICE = ("write_io_errs", "read_io_errs", "flush_io_errs", "corruption_errs", "generation_errs")
MAX_FILES = 200
# "... checksum error at logical 123 on dev /dev/dm-0, physical 456, root 263,
# inode 1000, offset 0, length 4096, links 1 (path: matt/Videos/a.mkv)"
PATH_RE = re.compile(r"\broot (?P<root>\d+),.*\(path: (?P<path>.*)\)\s*$")


def btrfs(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["btrfs", *args], capture_output=True, text=True)


def scrub_status(mount: str) -> dict:
    """`btrfs scrub status -R`: its state and raw counters, summed over the
    pass so far (btrfs-progs carries them across a resume)."""
    r = btrfs("scrub", "status", "-R", mount)
    out: dict = {"status": "none"}
    for line in r.stdout.splitlines():
        key, _, value = line.strip().partition(":")
        value = value.strip()
        if key == "Status":
            out["status"] = value.split()[0] if value else "none"
        elif key in ERRORS or key in ("data_bytes_scrubbed", "tree_bytes_scrubbed", "last_physical"):
            try:
                out[key] = int(value)
            except ValueError:
                pass
    if "no stats available" in r.stdout:
        out["status"] = "none"
    return out


def device_stats(mount: str) -> dict:
    """The disk's own error counters, kept by btrfs since it was made."""
    out = {k: 0 for k in DEVICE}
    for line in btrfs("device", "stats", mount).stdout.splitlines():
        name, _, value = line.rpartition(" ")
        key = name.strip().rsplit(".", 1)[-1]
        if key in out:
            try:
                out[key] += int(value)
            except ValueError:
                pass
    return out


def damaged_files(mount: str, since: float) -> list[str]:
    """The files the kernel said failed their checksums since SINCE, as paths
    on the backup disk (home/20260923T073121Z/matt/...)."""
    try:
        r = subprocess.run(["journalctl", "-k", "-o", "cat", "--no-pager", "--since", f"@{int(since)}"],
                           capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return []
    roots: dict[str, str] = {}
    found: list[str] = []
    for line in r.stdout.splitlines():
        if "BTRFS" not in line or "(path: " not in line:
            continue
        m = PATH_RE.search(line)
        if not m:
            continue
        root = m.group("root")
        if root not in roots:
            sub = btrfs("inspect-internal", "subvolid-resolve", root, mount).stdout.strip()
            roots[root] = sub if root != "5" else ""
        path = "/".join(p for p in (roots[root], m.group("path").lstrip("/")) if p)
        if path not in found:
            found.append(path)
            if len(found) >= MAX_FILES:
                break
    return found


def load(state: Path) -> dict:
    try:
        data = json.loads(state.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save(state: Path, record: dict) -> None:
    state.parent.mkdir(parents=True, exist_ok=True)
    tmp = state.with_name(state.name + ".tmp")
    tmp.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o644)
    tmp.replace(state)


def found_damage(part: dict) -> bool:
    errors = part.get("errors") or {}
    bad = sum(int(errors.get(k) or 0) for k in ("csum_errors", "uncorrectable_errors", "verify_errors", "super_errors"))
    return bool(bad or part.get("files"))


def verdict(record: dict) -> str:
    """Damage found by the pass under way, or by the last full one, stands
    until a full pass has read the whole disk again: starting a new pass must
    not wipe the warning before it has even reached the bad file."""
    if not record.get("checked_at") and not record.get("running"):
        return "unknown"
    device = record.get("device") or {}
    errors = record.get("errors") or {}
    if (found_damage(record) or found_damage(record.get("previous") or {})
            or int(device.get("corruption_errs") or 0)):
        return "damaged"
    if any(int(device.get(k) or 0) for k in ("read_io_errs", "write_io_errs", "flush_io_errs", "generation_errs")):
        return "warning"
    if int(errors.get("read_errors") or 0):
        return "warning"
    return "healthy"


def used_bytes(mount: str) -> int:
    try:
        du = shutil.disk_usage(mount)
    except OSError:
        return 0
    return du.total - du.free


def start(mount: str, state: Path, minutes: int) -> dict:
    """Carry tonight's slice of the pass on: resume a paused scrub, or start
    a new pass once the last one finished (or none ever ran)."""
    record = load(state)
    now = time.time()
    status = scrub_status(mount)
    if status["status"] == "running":
        return record
    new_pass = status["status"] in ("none", "finished") or not record.get("pass_started")
    if new_pass:
        if record.get("full_pass_at"):
            record["previous"] = {k: record.get(k) for k in ("errors", "files", "full_pass_at")}
        record.update(pass_started=int(now), files=[], errors={}, done_bytes=0)
    record.update(running=True, night_started=int(now), deadline=int(now + minutes * 60),
                  total_bytes=used_bytes(mount))
    save(state, record)
    r = btrfs("scrub", "start" if new_pass else "resume", *IDLE, mount)
    if r.returncode != 0 and not new_pass:
        # Nothing to resume after all (a status file lost to a reinstall):
        # a fresh pass it is.
        record.update(pass_started=int(now), files=[], errors={}, done_bytes=0)
        save(state, record)
        r = btrfs("scrub", "start", *IDLE, mount)
    if r.returncode != 0:
        record["running"] = False
        record["problem"] = (r.stderr or r.stdout).strip()[:300]
        save(state, record)
    return record


def settle(mount: str, state: Path, stop: bool = False) -> dict:
    """Fold what the scrub has found into the record. With STOP, pause a
    running scrub first (tonight's time is up, or the disk is being locked):
    the next night resumes it."""
    record = load(state)
    status = scrub_status(mount)
    if stop and status["status"] == "running":
        btrfs("scrub", "cancel", mount)
        for _ in range(30):
            status = scrub_status(mount)
            if status["status"] != "running":
                break
            time.sleep(1)
    now = int(time.time())
    running = status["status"] == "running"
    done = int(status.get("data_bytes_scrubbed", 0)) + int(status.get("tree_bytes_scrubbed", 0))
    record["errors"] = {k: int(status.get(k, 0)) for k in ERRORS}
    record["device"] = device_stats(mount)
    record["done_bytes"] = done
    record["total_bytes"] = used_bytes(mount) or record.get("total_bytes", 0)
    record["running"] = running
    since = record.get("night_started") or record.get("pass_started") or now
    files = list(record.get("files") or [])
    for f in damaged_files(mount, since):
        if f not in files:
            files.append(f)
    record["files"] = files[:MAX_FILES]
    if not running:
        record["checked_at"] = now
        record.pop("deadline", None)
        if status["status"] == "finished":
            record["full_pass_at"] = now
            record["done_bytes"] = record["total_bytes"]
            # This pass read everything: it alone says how the disk is now.
            record.pop("previous", None)
    record["state"] = verdict(record)
    record.pop("problem", None)
    save(state, record)
    return record


def run(mount: str, state: Path, minutes: int) -> dict:
    """Tonight's slice, start to finish, for a disk plugged into this computer."""
    def stop(*_: object) -> None:
        raise SystemExit(143)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        record = start(mount, state, minutes)
        deadline = record.get("deadline") or time.time()
        while record.get("running") and time.time() < deadline:
            time.sleep(10)
            if scrub_status(mount)["status"] != "running":
                break
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        record = settle(mount, state, stop=True)
    return record


def show(state: Path) -> dict:
    record = load(state)
    record["state"] = verdict(record)
    return record


def main() -> int:
    a = sys.argv[1:]
    try:
        if a[:1] == ["start"] and len(a) == 4:
            start(a[1], Path(a[2]), int(a[3]))
        elif a[:1] == ["run"] and len(a) == 4:
            print(json.dumps(run(a[1], Path(a[2]), int(a[3]))))
        elif a[:1] == ["settle"] and len(a) in (3, 4):
            print(json.dumps(settle(a[1], Path(a[2]), stop=a[3:] == ["--stop"])))
        elif a[:1] == ["show"] and len(a) == 2:
            print(json.dumps(show(Path(a[1]))))
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except ValueError:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
