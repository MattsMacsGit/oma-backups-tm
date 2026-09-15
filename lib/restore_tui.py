#!/usr/bin/env python3
"""OmaBackups restore wizard. Runs on the rescue USB (tty1 autologin).

Stdlib only. Step-through prompts, not a full desktop.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(os.environ.get("OMARCHY_TM_ROOT") or Path(__file__).resolve().parent.parent)
CLI = ROOT / "omarchy-backups"
MNT = Path("/run/omarchy-backups")

LIVE_LABELS = {"OMARCHY-EFI", "OMARCHY-LIVE"}
CAPSULE_LABELS = {"OMARCHY-TM", "OMARCHY-BACKUPS", "OMARCHY-EFI", "OMARCHY-LIVE"}
INSTALLER_LABELS = {"VENTOY", "VTOYEFI", "CLONEZILLA", "CLONEZILLA-LIVE"}


def out(msg: str = "") -> None:
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()


def quiet_console() -> None:
    """Keep printk from drowning the wizard; Arch ISO still has a real console."""
    subprocess.run(["dmesg", "-n", "4"], check=False, capture_output=True)


def banner() -> None:
    os.system("clear") if sys.stdout.isatty() else None
    out()
    out("  ════════════════════════════════════════")
    out("   OmaBackups — restore")
    out("  ════════════════════════════════════════")
    out()
    out("  This USB can put your Omarchy machine")
    out("  back onto a blank disk: same user, same")
    out("  packages, same home as a backup date.")
    out()


def pause(msg: str = "Press Enter to continue, or q to shell.") -> bool:
    try:
        s = input(msg + " ").strip().lower()
    except EOFError:
        return False
    return s not in {"q", "quit", "exit"}


def ask(prompt: str, default: str = "") -> str:
    suffix = f" [{default}]" if default else ""
    try:
        s = input(f"{prompt}{suffix}: ").strip()
    except EOFError:
        return default
    return s or default


def run(argv: list[str], check: bool = False, capture: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(argv, check=check, text=True, capture_output=capture)


def lsblk_json() -> list[dict]:
    proc = run(
        [
            "lsblk",
            "-J",
            "-b",
            "-o",
            "NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,MODEL,TRAN,RM,MOUNTPOINTS,PKNAME",
        ]
    )
    if proc.returncode != 0:
        return []
    try:
        return json.loads(proc.stdout).get("blockdevices", [])
    except json.JSONDecodeError:
        return []


def iter_nodes(nodes: list[dict], parent: dict | None = None):
    for n in nodes:
        yield n, parent
        yield from iter_nodes(n.get("children") or [], n)


def human(n) -> str:
    try:
        v = float(int(n))
    except (TypeError, ValueError):
        return "?"
    for unit in ("B", "K", "M", "G", "T"):
        if v < 1024 or unit == "T":
            return f"{v:.1f}{unit}" if unit != "B" else f"{int(v)}B"
        v /= 1024
    return "?"


def labels_of(disk: dict) -> set[str]:
    out_l: set[str] = set()
    if disk.get("label"):
        out_l.add(str(disk["label"]).upper())
    for ch in disk.get("children") or []:
        out_l |= labels_of(ch)
    return out_l


def settle_block_devices() -> None:
    """USB card readers often appear a few seconds after the live OS is up."""
    run(["udevadm", "trigger", "--action=add", "--subsystem-match=block"])
    run(["udevadm", "settle", "-t", "15"])
    time.sleep(2)


def sysfs_block_names() -> list[str]:
    names: list[str] = []
    base = Path("/sys/block")
    if not base.is_dir():
        return names
    try:
        entries = list(base.iterdir())
    except OSError:
        return names
    skip = ("loop", "zram", "ram", "dm-", "sr", "fd")
    for p in sorted(entries):
        name = p.name
        if name.startswith(skip):
            continue
        names.append(name)
    return names


def live_root_disk() -> str | None:
    src = run(["findmnt", "-n", "-o", "SOURCE", "/"]).stdout.strip()
    if not src:
        return None
    src = src.split("[", 1)[0]
    # Walk holders → partition → disk. PKNAME is empty on some dm devices.
    proc = run(["lsblk", "-nr", "-s", "-o", "NAME,TYPE", src])
    disk = None
    for line in proc.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "disk":
            disk = parts[0]
    if disk:
        return f"/dev/{disk}"
    pk = run(["lsblk", "-n", "-o", "PKNAME", src]).stdout.strip().splitlines()
    name = pk[0] if pk else ""
    if not name:
        return src if src.startswith("/dev/") else None
    parent = run(["lsblk", "-n", "-o", "PKNAME", f"/dev/{name}"]).stdout.strip().splitlines()
    if parent and parent[0]:
        return f"/dev/{parent[0]}"
    return f"/dev/{name}"


def classify_disk(path: str, n: dict, live: str | None) -> dict:
    labs = labels_of(n)
    kind = "disk"
    try:
        same_live = bool(live and os.path.realpath(path) == os.path.realpath(live))
    except OSError:
        same_live = False
    if labs & LIVE_LABELS or labs & {"OMARCHY-TM", "OMARCHY-BACKUPS"}:
        kind = "backup-usb"
    elif same_live:
        kind = "live-usb"
    elif labs & INSTALLER_LABELS:
        kind = "installer"
    elif (n.get("tran") or "").lower() in {"usb", "mmc", "sdio"}:
        kind = "usb"
    else:
        kind = "internal"
    return {
        "path": path,
        "size": human(n.get("size")),
        "model": (n.get("model") or "").strip(),
        "tran": n.get("tran") or "",
        "kind": kind,
        "labels": sorted(labs),
    }


def lsblk_disk_node(name: str) -> dict | None:
    proc = run(
        [
            "lsblk",
            "-J",
            "-b",
            "-o",
            "NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,MODEL,TRAN,RM,MOUNTPOINTS,PKNAME",
            f"/dev/{name}",
        ]
    )
    if proc.returncode != 0:
        return None
    try:
        nodes = json.loads(proc.stdout).get("blockdevices") or []
    except json.JSONDecodeError:
        return None
    return nodes[0] if nodes else None


def list_disks() -> list[dict]:
    tree = lsblk_json()
    live = live_root_disk()
    disks: list[dict] = []
    seen: set[str] = set()
    for n, _p in iter_nodes(tree):
        if n.get("type") != "disk":
            continue
        if str(n.get("name") or "").startswith("zram"):
            continue
        path = n.get("path") or f"/dev/{n.get('name')}"
        try:
            path = os.path.realpath(path)
        except OSError:
            pass
        if path in seen:
            continue
        seen.add(path)
        disks.append(classify_disk(path, n, live))
    # Card readers sometimes miss the JSON tree on first query.
    for name in sysfs_block_names():
        path = f"/dev/{name}"
        try:
            path = os.path.realpath(path)
        except OSError:
            pass
        if path in seen:
            continue
        node = lsblk_disk_node(name)
        if not node or node.get("type") != "disk":
            continue
        seen.add(path)
        disks.append(classify_disk(path, node, live))
    disks.sort(key=lambda d: d["path"])
    return disks


def unlock_backup() -> bool:
    if (MNT / "meta" / "machine.json").is_file():
        out(f"Backup disk already mounted at {MNT}")
        return True
    out("Unlocking the backup disk (LUKS password from when you set it up).")
    env = os.environ.copy()
    env["OMARCHY_TM_ROOT"] = str(ROOT)
    env["OMARCHY_TM_YES"] = "1"
    proc = subprocess.run([str(CLI), "mount"], env=env)
    if proc.returncode != 0:
        out("Could not unlock the backup disk.")
        out("On this rescue USB the backups are the LUKS partition next to OMARCHY-LIVE.")
        out("Try: oma-backups mount")
        return False
    return True


def load_snapshots() -> list[dict]:
    proc = run([str(CLI), "snapshots", "--json"])
    if proc.returncode != 0:
        return []
    try:
        snaps = json.loads(proc.stdout or "[]")
    except json.JSONDecodeError:
        return []
    return [s for s in snaps if s.get("valid") and not s.get("home_only")]


def pick_snapshot(snaps: list[dict]) -> dict | None:
    if not snaps:
        out("No full restore points on this disk (need os+home+esp).")
        return None
    out("Restore points:")
    for i, s in enumerate(snaps, 1):
        label = s.get("label") or s.get("timestamp") or "?"
        ver = s.get("omarchy_version") or ""
        extra = f"  Omarchy {ver}" if ver else ""
        out(f"  {i}. {label}{extra}")
    raw = ask("Choose a restore point", "1")
    if raw.lower() in {"q", "quit"}:
        return None
    try:
        idx = int(raw)
    except ValueError:
        return None
    if 1 <= idx <= len(snaps):
        return snaps[idx - 1]
    return None


def kind_tag(d: dict) -> str:
    return {
        "live-usb": "this rescue USB (booted)",
        "backup-usb": "backup source USB",
        "installer": "Ventoy/installer",
        "internal": "INTERNAL",
        "usb": "USB",
    }.get(d["kind"], d["kind"])


def pick_target(disks: list[dict] | None = None) -> dict | None:
    # Only this backup/rescue stick is omitted. Other USB disks (installer
    # sticks, extra cards) stay on the list even if they look "live".
    hidden_kinds = {"backup-usb"}
    while True:
        settle_block_devices()
        disks = list_disks()
        skipped = [d for d in disks if d["kind"] in hidden_kinds]
        candidates = [d for d in disks if d["kind"] not in hidden_kinds]
        out()
        out("Disks the kernel can see:")
        if not disks:
            out("  (none yet)")
        for d in disks:
            mark = "  [not a target]" if d["kind"] in hidden_kinds else ""
            out(
                f"    {d['path']:14}  {d['size']:>8}  {d['model'] or '-':16}  "
                f"{d['tran'] or '-':4}  {kind_tag(d)}{mark}"
            )
        out()
        if skipped:
            out("This backup/rescue USB is not offered as a restore target.")
            out()
        if not candidates:
            out("No other disks yet (USB card readers are often slow).")
            raw = ask("r to scan again, q to shell", "r")
            if raw.lower() in {"q", "quit", "exit"}:
                return None
            continue
        out("Choose a disk to ERASE. Type the name and YES on the next screen.")
        for i, d in enumerate(candidates, 1):
            labs = ",".join(d.get("labels") or []) or "-"
            out(
                f"  {i}. {d['path']:14}  {d['size']:>8}  {d['model'] or '-':16}  "
                f"{d['tran'] or '-':4}  {kind_tag(d)}  {labs}"
            )
        raw = ask("Number, or r to rescan, q to quit", "")
        if raw.lower() in {"q", "quit", "exit", ""}:
            return None
        if raw.lower() in {"r", "rescan", "retry"}:
            continue
        try:
            idx = int(raw)
        except ValueError:
            out("Not a number.")
            continue
        if 1 <= idx <= len(candidates):
            return candidates[idx - 1]
        out("That number is not in the list.")


def confirm_wipe(target: dict, snap: dict) -> bool:
    out()
    out("  THIS ERASES THE WHOLE DISK PERMANENTLY:")
    out(f"    {target['path']}  {target['size']}  {target['model']}  ({kind_tag(target)})")
    out(f"  Restore point: {snap.get('timestamp')}")
    if target["kind"] in {"live-usb", "backup-usb"}:
        out()
        out("  That is this backup/rescue USB. Restoring onto it destroys")
        out("  the copy you are restoring from.")
    out()
    name = Path(target["path"]).name
    typed = ask(f"Type the disk name to confirm ({name})")
    if typed != name:
        out("Name did not match. Aborting.")
        return False
    yes = ask("Type YES to erase and restore")
    return yes == "YES"


def run_restore(target: dict, snap: dict) -> int:
    ts = snap.get("timestamp")
    argv = [
        str(CLI),
        "restore-to-disk",
        target["path"],
        "--snapshot",
        str(ts),
        "--yes",
        "--allow-internal",
    ]
    env = os.environ.copy()
    env["OMARCHY_TM_ROOT"] = str(ROOT)
    env["OMARCHY_TM_YES"] = "1"
    env["OMARCHY_TM_ALLOW_INTERNAL"] = "1"
    out()
    out("Starting restore. This takes a while.")
    out()
    return subprocess.call(argv, env=env)


def drop_to_shell() -> None:
    out()
    out("Shell. Useful commands:")
    out("  oma-backups mount")
    out("  oma-backups snapshots")
    out("  oma-backups restore-to-disk /dev/TARGET --snapshot TS --dry-run")
    out("  oma-backups restore-to-disk /dev/TARGET --snapshot TS --allow-internal")
    out()


def main() -> int:
    if os.geteuid() != 0:
        out("This restore wizard needs to run as root (rescue USB autologin).")
        return 1
    quiet_console()
    banner()
    if not pause():
        drop_to_shell()
        return 0
    if not unlock_backup():
        drop_to_shell()
        return 1
    snaps = load_snapshots()
    snap = pick_snapshot(snaps)
    if not snap:
        drop_to_shell()
        return 1
    target = pick_target()
    if not target:
        drop_to_shell()
        return 1
    out()
    out("Plan (dry-run):")
    env = os.environ.copy()
    env["OMARCHY_TM_ROOT"] = str(ROOT)
    env["OMARCHY_TM_ALLOW_INTERNAL"] = "1"
    subprocess.call(
        [
            str(CLI),
            "--dry-run",
            "restore-to-disk",
            target["path"],
            "--snapshot",
            str(snap.get("timestamp")),
            "--allow-internal",
        ],
        env=env,
    )
    if not confirm_wipe(target, snap):
        drop_to_shell()
        return 1
    rc = run_restore(target, snap)
    if rc == 0:
        out()
        out("Restore finished. Remove this USB and boot the restored disk.")
        pause("Press Enter for a shell.")
    else:
        out(f"Restore failed (exit {rc}).")
        drop_to_shell()
    return rc


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        out("\nAborted.")
        raise SystemExit(130)
