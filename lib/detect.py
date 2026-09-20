#!/usr/bin/env python3
"""Detect whether this machine is an Omarchy-like LUKS+btrfs+Limine install.

Exit 0 if supported, 2 if unsupported, 1 on tool/usage errors.
Unprivileged: uses mountinfo, fstab, os-release, lsblk. Never needs sudo
for a yes/no. Subvolume *list* is included when readable.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

PROTECTED_LABELS = {
    "VENTOY",
    "VTOYEFI",
    "CLONEZILLA",
    "CLONEZILLA-LIVE",
}

INSTALLER_LABELS = PROTECTED_LABELS

# Our own disk labels, compared uppercased (see labels_on_disk). New disks get
# the 1.1 names; the older ones stay recognised so disks built before the
# rename keep working. Mirrored in lib/common.sh and lib/restore_tui.py.
EFI_LABELS = {"OMABOOT", "OMARCHY-EFI", "OMARCHY-ISO"}
LIVE_LABELS = {"OMARESCUE", "OMARCHY-LIVE"}
BACKUP_LABELS = {"OMABACKUPS", "OMARCHY-TM", "OMARCHY-BACKUPS"}
# A network rescue stick (see rescue-stick.sh). Nothing here knew these
# existed, so a rescue stick came back looking like a blank USB and was
# offered in every "pick a disk to erase" list with nothing to say what it
# was. It is still offered — it is the owner's USB — but now it says so.
NET_LABELS = {
    "OMANETBOOT", "OMANETRESCUE", "OMANETKEYS",
    "OMANET-EFI", "OMANET-LIVE", "OMANET-KEYS",
}
USB_TRANS = {"usb", "mmc", "sdio"}


def _run(argv: list[str], check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(argv, check=check, text=True, capture_output=True)


def _read(path: str) -> str | None:
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


def parse_os_release() -> dict:
    raw = _read("/etc/os-release") or ""
    out: dict[str, str] = {}
    for line in raw.splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k] = v.strip().strip('"')
    return out


def parse_mountinfo() -> list[dict]:
    raw = _read("/proc/self/mountinfo") or ""
    mounts = []
    for line in raw.splitlines():
        # 36 24 0:32 /@ / rw,... - btrfs /dev/mapper/root rw,...,subvol=/@
        if " - " not in line:
            continue
        left, right = line.split(" - ", 1)
        lparts = left.split()
        rparts = right.split()
        if len(lparts) < 6 or len(rparts) < 2:
            continue
        super_opts = rparts[-1] if rparts else ""
        subvol = None
        subvolid = None
        for opt in super_opts.split(","):
            if opt.startswith("subvol="):
                subvol = opt.split("=", 1)[1].lstrip("/")
            elif opt.startswith("subvolid="):
                try:
                    subvolid = int(opt.split("=", 1)[1])
                except ValueError:
                    pass
        mounts.append(
            {
                "mountpoint": lparts[4],
                "root": lparts[3],
                "fstype": rparts[0],
                "source": rparts[1],
                "subvol": subvol,
                "subvolid": subvolid,
            }
        )
    return mounts


def mount_for(mounts: list[dict], path: str) -> dict | None:
    for m in mounts:
        if m["mountpoint"] == path:
            return m
    return None


def parse_fstab() -> list[dict]:
    raw = _read("/etc/fstab") or ""
    rows = []
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 4:
            continue
        spec, mp, fstype, opts = parts[0], parts[1], parts[2], parts[3]
        subvol = None
        for opt in opts.split(","):
            if opt.startswith("subvol="):
                subvol = opt.split("=", 1)[1].lstrip("/")
        rows.append(
            {
                "spec": spec,
                "mountpoint": mp,
                "fstype": fstype,
                "subvol": subvol,
            }
        )
    return rows


def lsblk_tree() -> list[dict]:
    proc = _run(
        [
            "lsblk",
            "-J",
            "-b",
            "-o",
            "NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS,PKNAME,PARTUUID,MODEL,TRAN,RM",
        ]
    )
    if proc.returncode != 0:
        return []
    try:
        return json.loads(proc.stdout).get("blockdevices", [])
    except json.JSONDecodeError:
        return []


def iter_blockdevs(nodes: list[dict], parent: dict | None = None):
    for n in nodes:
        yield n, parent
        children = n.get("children") or []
        yield from iter_blockdevs(children, n)


def find_node(nodes: list[dict], pred) -> dict | None:
    for n, _p in iter_blockdevs(nodes):
        if pred(n):
            return n
    return None


def disk_ancestor(nodes: list[dict], name: str) -> dict | None:
    """Walk PKNAME/parent until TYPE=disk."""
    by_name = {n.get("name"): n for n, _ in iter_blockdevs(nodes)}
    cur = by_name.get(name)
    seen = set()
    while cur is not None and cur.get("name") not in seen:
        seen.add(cur.get("name"))
        if cur.get("type") == "disk":
            return cur
        pk = cur.get("pkname")
        cur = by_name.get(pk) if pk else None
    return None


def labels_on_disk(disk: dict) -> list[str]:
    out = []
    if disk.get("label"):
        out.append(str(disk["label"]))
    for ch in disk.get("children") or []:
        out.extend(labels_on_disk(ch))
    return out


def mountpoints_on_disk(disk: dict) -> list[str]:
    out = []
    mps = disk.get("mountpoints") or []
    out.extend([m for m in mps if m])
    for ch in disk.get("children") or []:
        out.extend(mountpoints_on_disk(ch))
    return out


def device_path(node: dict) -> str:
    p = node.get("path")
    if p:
        return p
    name = node.get("name") or ""
    return f"/dev/{name}"


def is_usb_disk(disk: dict) -> bool:
    tran = (disk.get("tran") or "").lower()
    if tran in USB_TRANS:
        return True
    if disk.get("rm") in (True, 1, "1"):
        return True
    return False


def installer_reason(disk: dict) -> str | None:
    labels = {str(x).upper() for x in labels_on_disk(disk)}
    hit = labels & INSTALLER_LABELS
    if hit:
        return "installer disk (" + ", ".join(sorted(hit)) + ")"
    return None


def protected_reason(disk: dict, live_root_disk: str | None) -> str | None:
    """Live root and installer sticks are never format/restore targets."""
    path = device_path(disk)
    if live_root_disk and os.path.realpath(path) == os.path.realpath(live_root_disk):
        return "live root disk"
    mps = set(mountpoints_on_disk(disk))
    for critical in ("/", "/boot", "/home"):
        if critical in mps:
            return f"mounted as {critical}"
    inst = installer_reason(disk)
    if inst:
        return inst
    return None


def partition_fstypes(disk: dict) -> set[str]:
    out = set()
    for ch in disk.get("children") or []:
        if ch.get("fstype"):
            out.add(str(ch["fstype"]))
        out |= partition_fstypes(ch)
    return out


def content_note(disk: dict, cap: dict | None) -> str | None:
    """What is already on this disk, in words, for a "pick a disk" list.

    Never hides anything and never refuses anything — whose disk it is, is the
    owner's business. It just means nobody erases their own rescue stick, or a
    spare drive they restored a working system onto, thinking it was blank.
    """
    labels = {str(x).upper() for x in labels_on_disk(disk)}
    if labels & NET_LABELS:
        return "network rescue stick"
    if cap:
        return "backup disk"
    fstypes = partition_fstypes(disk)
    if "crypto_LUKS" in fstypes and fstypes & {"vfat", "msdos"}:
        return "has an encrypted system on it"
    return None


def capsule_layout(disk: dict) -> dict | None:
    """Return capsule info for 2-part (legacy ISO+LUKS) or 3-part (EFI+live+LUKS)."""
    children = disk.get("children") or []
    efi = None
    live = None
    tm = None
    for ch in children:
        label = (ch.get("label") or "").upper()
        fstype = ch.get("fstype") or ""
        # Exact labels only. A restored Omarchy ESP is named "OMARCHY" + LUKS
        # root — that is the computer, not a backup USB.
        if label in EFI_LABELS:
            efi = ch
        if label in LIVE_LABELS:
            live = ch
        if fstype == "crypto_LUKS":
            tm = ch
        elif label in BACKUP_LABELS:
            tm = ch
    if tm and (efi or live):
        return {
            "iso_partition": device_path(efi) if efi else None,
            "live_partition": device_path(live) if live else None,
            "tm_partition": device_path(tm),
            "luks_uuid": tm.get("uuid"),
            "iso_label": (efi or {}).get("label"),
            "tm_fstype": tm.get("fstype"),
        }
    return None


def findmnt_uuid(path: str) -> str | None:
    proc = _run(["findmnt", "-n", "-o", "UUID", path])
    if proc.returncode != 0:
        return None
    return proc.stdout.strip() or None


def kernel_release() -> str:
    return os.uname().release


def limine_info() -> dict:
    default = _read("/etc/default/limine") or ""
    uki = False
    uki_conf = _read("/etc/limine-entry-tool.d/omarchy-uki.conf") or ""
    if "ENABLE_UKI=yes" in uki_conf:
        uki = True
    cmdline = _read("/proc/cmdline") or ""
    return {
        "esp_path": "/boot",
        "conf": "/boot/limine.conf",
        "defaults_conf": "/etc/default/limine",
        "uki": uki,
        "has_limine_mkinitcpio": bool(_which("limine-mkinitcpio")),
        "kernel_cmdline": cmdline.strip(),
        "cryptdevice_partuuid": _cmdline_partuuid(cmdline) or _cmdline_partuuid(default),
    }


def _cmdline_partuuid(text: str) -> str | None:
    m = re.search(r"cryptdevice=PARTUUID=([0-9a-fA-F-]+):", text)
    return m.group(1) if m else None


def _which(name: str) -> str | None:
    for d in os.environ.get("PATH", "").split(":"):
        p = Path(d) / name
        if p.is_file() and os.access(p, os.X_OK):
            return str(p)
    return None


def snapper_info() -> dict:
    confs = []
    confd = Path("/etc/snapper/configs")
    if confd.is_dir():
        confs = sorted(p.name for p in confd.iterdir() if p.is_file())
    return {
        "configs": confs,
        "root_configured": "root" in confs,
        "home_configured": "home" in confs,
    }


def try_subvolume_list() -> dict:
    proc = _run(["btrfs", "subvolume", "list", "/"])
    if proc.returncode != 0:
        return {
            "readable": False,
            "error": (proc.stderr or proc.stdout or "unreadable").strip().splitlines()[-1:],
        }
    names = []
    for line in proc.stdout.splitlines():
        # ID 256 gen 9 top level 5 path @
        m = re.search(r"path (.+)$", line)
        if m:
            names.append(m.group(1).strip())
    return {"readable": True, "paths": names, "error": []}


def tools() -> dict:
    names = [
        "btrfs",
        "snapper",
        "cryptsetup",
        "mkfs.fat",
        "mkfs.btrfs",
        "rsync",
        "jq",
        "limine",
        "limine-install",
        "limine-mkinitcpio",
        "sfdisk",
        "parted",
        "wipefs",
        "pv",
        "sgdisk",
        "arch-chroot",
        "curl",
        "unsquashfs",
        "mksquashfs",
    ]
    return {n: bool(_which(n)) for n in names}


def current_capsule_uuid() -> str | None:
    """The backup disk set up most recently (see set_current_capsule)."""
    try:
        data = json.loads(Path("/etc/omarchy-backups/capsule.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    uuid = data.get("luks_uuid") if isinstance(data, dict) else None
    return uuid if isinstance(uuid, str) and uuid else None


def cached_capsule_disk(path: Path) -> dict | None:
    """Total/free bytes of a remote backup disk, as of its last backup."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        total, free = int(data["total"]), int(data["free"])
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if not 0 <= free <= total:
        return None
    return {"total": total, "used": total - free, "free": free}


def detect(diagnostics: bool = True) -> dict:
    """diagnostics=False leaves out the fields only `oma-backups detect`'s own
    printout uses: the tool inventory and `btrfs subvolume list`. The plugin
    polls the --json form and has never read either of them, so collecting
    them there meant scanning for 19 tools three times over and forking btrfs,
    every time, for nothing."""
    osrel = parse_os_release()
    mounts = parse_mountinfo()
    fstab = parse_fstab()
    block = lsblk_tree()
    root_mnt = mount_for(mounts, "/")
    home_mnt = mount_for(mounts, "/home")
    boot_mnt = mount_for(mounts, "/boot")
    log_mnt = mount_for(mounts, "/var/log")
    pkg_mnt = mount_for(mounts, "/var/cache/pacman/pkg")

    reasons: list[str] = []
    warnings: list[str] = []

    fstype = (root_mnt or {}).get("fstype")
    root_sub = (root_mnt or {}).get("subvol")
    home_sub = (home_mnt or {}).get("subvol")
    boot_fs = (boot_mnt or {}).get("fstype")

    if fstype != "btrfs":
        reasons.append(f"root fstype is {fstype or 'unknown'}, need btrfs")
    if root_sub not in {"@", "@root"}:
        reasons.append(f"root subvol is {root_sub!r}, need @")
    if not home_mnt or home_mnt.get("source") != (root_mnt or {}).get("source"):
        reasons.append(" /home is not a btrfs subvolume on the same device as /")
    if home_sub != "@home":
        reasons.append(f"home subvol is {home_sub!r}, need @home")
    if not boot_mnt or boot_fs not in {"vfat", "fat32", "msdos"}:
        reasons.append("need a separate vfat /boot ESP")
    if boot_mnt and root_mnt and boot_mnt.get("source") == root_mnt.get("source"):
        reasons.append("/boot is not a separate partition")

    os_id = osrel.get("ID", "")
    if os_id != "omarchy" and "omarchy" not in osrel.get("ID_LIKE", ""):
        warnings.append(f"OS ID={os_id!r} is not omarchy (layout still checked)")

    root_source = (root_mnt or {}).get("source")  # /dev/mapper/root
    mapper_name = None
    if root_source:
        mapper_name = Path(root_source).name

    luks_part = None
    if mapper_name:
        luks_part = find_node(block, lambda n: n.get("name") == mapper_name)

    backing = None
    if luks_part and luks_part.get("pkname"):
        backing = find_node(block, lambda n: n.get("name") == luks_part.get("pkname"))
    luks_used = bool(backing and backing.get("fstype") == "crypto_LUKS")
    if not luks_used and "/dev/mapper/" in (root_source or ""):
        luks_used = True

    live_disk = None
    if mapper_name:
        live_disk = disk_ancestor(block, mapper_name)
    if live_disk is None and boot_mnt:
        boot_name = Path(boot_mnt["source"]).name
        live_disk = disk_ancestor(block, boot_name)

    live_root_disk = device_path(live_disk) if live_disk else None

    disks = []
    for n, parent in iter_blockdevs(block):
        if n.get("type") != "disk":
            continue
        if n.get("name", "").startswith("zram"):
            continue
        reason = protected_reason(n, live_root_disk)
        cap = capsule_layout(n)
        usb = is_usb_disk(n)
        installer = installer_reason(n)
        kind = "internal"
        if live_root_disk and os.path.realpath(device_path(n)) == os.path.realpath(live_root_disk):
            kind = "live-root"
            cap = None
        elif installer:
            kind = "installer"
            cap = None
        elif cap:
            kind = "capsule"
        elif usb:
            kind = "usb"
        disks.append(
            {
                "path": device_path(n),
                "name": n.get("name"),
                "size_bytes": n.get("size"),
                "size": _human(n.get("size")),
                "model": n.get("model"),
                "tran": n.get("tran"),
                "rm": n.get("rm"),
                "usb": usb,
                "internal": not usb,
                "kind": kind,
                "installer": installer,
                "hidden_by_default": (not usb) or bool(installer) or reason is not None,
                "protected": reason is not None,
                "protected_reason": reason,
                "capsule": cap,
                "labels": labels_on_disk(n),
                "mountpoints": mountpoints_on_disk(n),
                # Shown next to the disk wherever one gets picked. Advisory
                # only: it changes no decision this script makes.
                "content": content_note(n, cap),
                "candidate": reason is None and not installer,
            }
        )

    fstab_subs = {
        r["mountpoint"]: r.get("subvol")
        for r in fstab
        if r.get("fstype") == "btrfs" and r.get("subvol")
    }

    subvols = {
        "@": {
            "name": "@",
            "subvolid": (root_mnt or {}).get("subvolid"),
            "mountpoint": "/",
        },
        "@home": {
            "name": "@home",
            "subvolid": (home_mnt or {}).get("subvolid"),
            "mountpoint": "/home",
        },
    }
    if log_mnt and log_mnt.get("subvol"):
        subvols["@log"] = {
            "name": log_mnt.get("subvol"),
            "subvolid": log_mnt.get("subvolid"),
            "mountpoint": "/var/log",
        }
    if pkg_mnt and pkg_mnt.get("subvol"):
        subvols["@pkg"] = {
            "name": pkg_mnt.get("subvol"),
            "subvolid": pkg_mnt.get("subvolid"),
            "mountpoint": "/var/cache/pacman/pkg",
        }

    machine_id = (_read("/etc/machine-id") or "").strip()
    hostname = (_read("/etc/hostname") or os.uname().nodename).strip()

    # sgdisk/curl/unsquashfs/mksquashfs are hard requirements of format-disk.sh's
    # default (non---skip-live) path — see lib/install-rescue.sh need_cmd calls
    # and format-disk.sh's own `command -v sgdisk` check. Not installed by a
    # base Omarchy system, so this must be required, not merely recommended.
    tool_status = tools() if diagnostics else {}
    missing_tools = [
        k
        for k, v in tool_status.items()
        if not v
        and k in {"btrfs", "cryptsetup", "mkfs.btrfs", "mkfs.fat", "rsync", "sfdisk", "sgdisk", "curl", "unsquashfs", "mksquashfs"}
    ]
    # pv is cosmetic (progress bar); arch-chroot is only used by restore-to-disk.sh.
    optional_missing = [k for k, v in tool_status.items() if not v and k in {"pv", "arch-chroot"}]

    snapshots = []
    backup_mounted = False
    capsule_disk = None
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from list_snapshots import cache_path, find_mount, scan, write_cache

        mnt = find_mount()
        backup_mounted = mnt is not None
        if mnt is not None:
            snapshots = scan(mnt)
            write_cache(snapshots)
            # Whole-filesystem stat, not a tree walk — cheap enough for
            # every detect() poll. Per-snapshot sizes are a different
            # matter (see backup.sh) and are never recomputed here.
            try:
                du = shutil.disk_usage(mnt)
                capsule_disk = {"total": du.total, "used": du.used, "free": du.free}
            except OSError:
                capsule_disk = None
        elif Path("/etc/omarchy-backups/remote.json").is_file():
            # With a paired Pi the disk is never mounted here; its restore
            # points and free space come from what the last remote backup
            # cached.
            capsule_disk = cached_capsule_disk(cache_path().parent / "capsule-disk.json")
        else:
            write_cache([])
    except Exception:
        snapshots = []
        backup_mounted = False

    supported = len(reasons) == 0
    result = {
        "supported": supported,
        "exit_hint": 0 if supported else 2,
        "os": {
            "id": osrel.get("ID"),
            "id_like": osrel.get("ID_LIKE"),
            "name": osrel.get("PRETTY_NAME") or osrel.get("NAME"),
            "version": osrel.get("VERSION_ID") or osrel.get("BUILD_ID"),
        },
        "hostname": hostname,
        "machine_id": machine_id,
        "kernel": kernel_release(),
        "luks_used": luks_used,
        "root": {
            "device": root_source,
            "fstype": fstype,
            "uuid": findmnt_uuid("/"),
            "subvol": root_sub,
            "subvolid": (root_mnt or {}).get("subvolid"),
        },
        "home": {
            "device": (home_mnt or {}).get("source"),
            "subvol": home_sub,
            "subvolid": (home_mnt or {}).get("subvolid"),
        },
        "boot": {
            "device": (boot_mnt or {}).get("source"),
            "fstype": boot_fs,
            "uuid": findmnt_uuid("/boot"),
        },
        "subvolumes": subvols,
        "fstab_subvolumes": fstab_subs,
        "luks": {
            "mapper": root_source,
            "partition": device_path(backing) if backing else None,
            "uuid": backing.get("uuid") if backing else None,
            "partuuid": backing.get("partuuid") if backing else None,
        },
        "live_root_disk": live_root_disk,
        "disks": disks,
        "snapshots": snapshots,
        "backup_mounted": backup_mounted,
        "capsule_disk": capsule_disk,
        "current_capsule_uuid": current_capsule_uuid(),
        "limine": limine_info(),
        "snapper": snapper_info(),
        "unsupported_reasons": reasons,
        "warnings": warnings,
    }
    if diagnostics:
        result["subvolume_list"] = try_subvolume_list()
        result["tools"] = tool_status
        result["missing_required_tools"] = missing_tools
        result["missing_optional_tools"] = optional_missing
    return result


def _human(num) -> str | None:
    if num is None:
        return None
    try:
        n = int(num)
    except (TypeError, ValueError):
        return str(num)
    units = ["B", "K", "M", "G", "T", "P"]
    f = float(n)
    for u in units:
        if f < 1024.0 or u == units[-1]:
            if u == "B":
                return f"{int(f)}{u}"
            return f"{f:.1f}{u}"
        f /= 1024.0
    return str(num)


def print_human(d: dict) -> None:
    ok = "SUPPORTED" if d["supported"] else "UNSUPPORTED"
    print(f"== OmaBackups: detect ({ok}) ==")
    osinfo = d["os"]
    print(f"OS:          {osinfo.get('name')}  ID={osinfo.get('id')} version={osinfo.get('version')}")
    print(f"Hostname:    {d.get('hostname')}")
    print(f"machine-id:  {d.get('machine_id')}")
    print(f"Kernel:      {d.get('kernel')}")
    print()
    r = d["root"]
    print(f"Root:        {r.get('fstype')} {r.get('device')}  UUID={r.get('uuid')}")
    print(f"             subvol=/{r.get('subvol')}  subvolid={r.get('subvolid')}")
    h = d["home"]
    print(f"Home:        subvol=/{h.get('subvol')}  subvolid={h.get('subvolid')}")
    for key in ("@log", "@pkg"):
        sv = d["subvolumes"].get(key)
        if sv:
            print(f"{key[1:].capitalize():12} subvol=/{sv.get('name')}  subvolid={sv.get('subvolid')}  {sv.get('mountpoint')}")
    b = d["boot"]
    print(f"ESP /boot:   {b.get('fstype')} {b.get('device')}  UUID={b.get('uuid')}")
    luks = d["luks"]
    print(
        f"LUKS:        {'yes' if d.get('luks_used') else 'no'}  "
        f"part={luks.get('partition')} UUID={luks.get('uuid')} PARTUUID={luks.get('partuuid')}"
    )
    lim = d["limine"]
    print(f"Limine:      ESP={lim.get('esp_path')} UKI={lim.get('uki')} mkinitcpio={lim.get('has_limine_mkinitcpio')}")
    snap = d["snapper"]
    print(f"Snapper:     configs={snap.get('configs') or ['(none)']}  (local rollback — we export, we do not replace)")
    svl = d.get("subvolume_list") or {}
    if svl.get("readable"):
        print(f"Subvolumes:  {', '.join(svl.get('paths') or [])}")
    else:
        err = svl.get("error") or ["need sudo for btrfs subvolume list"]
        print(f"Subvolumes:  (unprivileged) {err[0] if err else ''}")
    print()
    print(f"Live root disk: {d.get('live_root_disk')}  [always refused for format/restore]")
    print("Disks:")
    for disk in d["disks"]:
        flags = []
        flags.append(disk.get("kind") or "?")
        if disk["protected"]:
            flags.append(f"REFUSE: {disk['protected_reason']}")
        elif disk.get("installer"):
            flags.append(f"hidden: {disk['installer']}")
        elif disk.get("content"):
            flags.append(disk["content"])
        elif disk.get("hidden_by_default"):
            flags.append("internal — hidden unless --all")
        elif disk["candidate"]:
            flags.append("candidate")
        label = ",".join(disk.get("labels") or []) or "-"
        print(
            f"  {disk['path']:14} {disk.get('size') or '?':>8}  "
            f"{disk.get('model') or ''}  {disk.get('tran') or '-'}  "
            f"labels={label}  {' | '.join(flags)}"
        )
    print()
    if d.get("missing_required_tools"):
        pkg_of = {
            "sgdisk": "gptfdisk",
            "unsquashfs": "squashfs-tools",
            "mksquashfs": "squashfs-tools",
        }
        pkgs = sorted({pkg_of.get(t, t) for t in d["missing_required_tools"]})
        print("Missing required tools:", ", ".join(d["missing_required_tools"]))
        print("  install with: sudo pacman -S", " ".join(pkgs))
    if d.get("missing_optional_tools"):
        print(
            "Missing optional tools:",
            ", ".join(d["missing_optional_tools"]),
            "  (pv/arch-chroot recommended)",
        )
    if d["warnings"]:
        print("Warnings:")
        for w in d["warnings"]:
            print(f"  - {w}")
    if d["unsupported_reasons"]:
        print("Unsupported because:")
        for w in d["unsupported_reasons"]:
            print(f"  - {w}")
        print("Exit 2: this is not an Omarchy-like btrfs @ + @home + separate /boot system.")
    else:
        print("Status: SUPPORTED — detect will not format or snapshot anything.")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Detect Omarchy-like btrfs layout")
    p.add_argument("--json", action="store_true")
    args = p.parse_args(argv)
    data = detect(diagnostics=not args.json)
    if args.json:
        json.dump(data, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        print_human(data)
    return 0 if data["supported"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
