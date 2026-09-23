#!/usr/bin/env python3
"""Rewrite cryptdevice=PARTUUID in a restored Omarchy ESP.

Boot uses the UKI .cmdline and limine.conf, not /etc/default/limine.
limine-mkinitcpio in the restore chroot often exits 0 without rewriting
omarchy_linux.efi, so restore-to-disk must patch and verify before success.

objcopy is taken from the restored OS (Arch ISO rescue has no binutils).
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

PARTUUID_RE = re.compile(r"cryptdevice=PARTUUID=[0-9a-fA-F-]+")


def patch_text(text: str, partuuid: str, luks_uuid: str = "") -> str:
    text = PARTUUID_RE.sub(f"cryptdevice=PARTUUID={partuuid}", text)
    if luks_uuid:
        text = re.sub(r"rd\.luks\.uuid=[0-9a-fA-F-]+", f"rd.luks.uuid={luks_uuid}", text)
        # The mapper name stays: rd.luks.name=<uuid>=root
        text = re.sub(r"rd\.luks\.name=[0-9a-fA-F-]+", f"rd.luks.name={luks_uuid}", text)
    text = re.sub(r"\s*resume_offset=\S+", "", text)
    text = re.sub(r"\s*resume=\S*", "", text)
    # Limine hash on the path rejects an objcopy-edited UKI. Match any UKI
    # under EFI/Linux, not just the exact default name — Omarchy suffixes
    # this with the hostname (e.g. omarchy_linux-omarchy.efi) or a kernel
    # preset, and a hardcoded literal filename here misses those, leaving
    # a stale hash pin that fails Limine's integrity check at boot (seen
    # live: "WARNING: Blake2b hash for URI '.../omarchy_linux-omarchy.efi'
    # does not match!").
    text = re.sub(
        r"(path:\s*boot\(\):/EFI/Linux/[^\s#]+\.efi)#[0-9a-fA-F]+",
        r"\1",
        text,
    )
    return text


def crypt_ids(text: str) -> set[str]:
    return set(re.findall(r"cryptdevice=PARTUUID=([0-9a-fA-F-]+)", text))


def run_objcopy(args: list[str], chroot: Path | None) -> None:
    if chroot is not None:
        subprocess.check_call(["arch-chroot", str(chroot), "objcopy", *args])
    else:
        subprocess.check_call(["objcopy", *args])


def patch_uki(
    uki: Path,
    partuuid: str,
    chroot: Path | None,
    uki_in_chroot: str,
    tmp: Path,
    dump_target: str,
    luks_uuid: str = "",
) -> None:
    run_objcopy([f"--dump-section=.cmdline={dump_target}", uki_in_chroot], chroot)
    data = tmp.read_bytes()
    if not data:
        raise SystemExit(f"empty .cmdline in {uki}")
    text = data.split(b"\x00", 1)[0].decode("utf-8", "replace")
    new = patch_text(text, partuuid, luks_uuid).strip() + "\n"
    blob = new.encode()
    if len(blob) > len(data):
        raise SystemExit(
            f"new UKI cmdline is {len(blob)} bytes, section is {len(data)}"
        )
    tmp.write_bytes(blob.ljust(len(data), b"\x00"))
    run_objcopy([f"--update-section=.cmdline={dump_target}", uki_in_chroot], chroot)
    tmp.unlink(missing_ok=True)


def patch_conf(conf: Path, partuuid: str, luks_uuid: str = "") -> None:
    text = conf.read_text(encoding="utf-8", errors="replace")
    conf.write_text(patch_text(text, partuuid, luks_uuid), encoding="utf-8")


def drop_history(esp: Path) -> None:
    for p in esp.glob("*/limine_history"):
        shutil.rmtree(p, ignore_errors=True)
    hist = esp / "limine_history"
    if hist.is_dir():
        shutil.rmtree(hist, ignore_errors=True)


def ukis(esp: Path) -> list[Path]:
    linux = esp / "EFI" / "Linux"
    if not linux.is_dir():
        return []
    return [
        p
        for p in linux.iterdir()
        if p.suffix.lower() == ".efi" and ".bak" not in p.name.lower()
    ]


def find_conf(esp: Path) -> Path | None:
    for p in (esp / "limine.conf", esp / "EFI" / "limine" / "limine.conf"):
        if p.is_file():
            return p
    return None


def _luks_ok(blob: bytes | str, luks_uuid: str) -> bool:
    if not luks_uuid:
        return True
    if isinstance(blob, bytes):
        found = re.findall(br"rd\.luks\.(?:uuid|name)=([0-9a-fA-F-]+)", blob)
        bad = [o for o in found if o.decode().lower() != luks_uuid.lower()]
    else:
        found = re.findall(r"rd\.luks\.(?:uuid|name)=([0-9a-fA-F-]+)", blob)
        bad = [o for o in found if o.lower() != luks_uuid.lower()]
    return not bad


def verify(esp: Path, partuuid: str, luks_uuid: str = "") -> bool:
    conf = find_conf(esp)
    if conf is None:
        return False
    text = conf.read_text(encoding="utf-8", errors="replace")
    ids = crypt_ids(text)
    if ids != {partuuid}:
        return False
    if not _luks_ok(text, luks_uuid):
        return False
    found_uki = False
    for uki in ukis(esp):
        raw = uki.read_bytes()
        needle = f"cryptdevice=PARTUUID={partuuid}:".encode()
        if needle not in raw:
            return False
        # Any other cryptdevice in this UKI?
        others = re.findall(br"cryptdevice=PARTUUID=([0-9a-fA-F-]+)", raw)
        if any(o.decode() != partuuid for o in others):
            return False
        if not _luks_ok(raw, luks_uuid):
            return False
        found_uki = True
    return found_uki


def apply(esp: Path, partuuid: str, chroot: Path | None, luks_uuid: str = "") -> None:
    conf = find_conf(esp)
    if conf is not None:
        patch_conf(conf, partuuid, luks_uuid)
    tmp = esp / "uki-cmdline.bin"
    dump_target = "/boot/uki-cmdline.bin" if chroot is not None else str(tmp)
    for uki in ukis(esp):
        rel = "/boot/" + str(uki.relative_to(esp)).replace("\\", "/")
        try:
            patch_uki(
                uki,
                partuuid,
                chroot,
                rel if chroot is not None else str(uki),
                tmp,
                dump_target,
                luks_uuid,
            )
        except (subprocess.CalledProcessError, SystemExit) as exc:
            print(f"warning: could not patch UKI {uki}: {exc}", file=sys.stderr)
            tmp.unlink(missing_ok=True)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--esp", required=True, help="Mounted ESP (host path)")
    p.add_argument("--partuuid", required=True)
    p.add_argument("--luks-uuid", default="", help="New LUKS UUID for rd.luks.uuid= if present")
    p.add_argument("--chroot", default="", help="Restored root with /boot bound (has objcopy)")
    p.add_argument("--verify-only", action="store_true")
    args = p.parse_args()
    esp = Path(args.esp)
    chroot = Path(args.chroot) if args.chroot else None
    luks = args.luks_uuid
    if args.verify_only:
        return 0 if verify(esp, args.partuuid, luks) else 1
    # Always, not only when the main entry needs repairing: these are the
    # source machine's own snapshot entries, and every one of them points at
    # an encrypted partition that does not exist on this disk, so they can
    # only ever fail to boot. They used to survive whenever the main entry
    # happened to already be right.
    drop_history(esp)
    if not verify(esp, args.partuuid, luks):
        apply(esp, args.partuuid, chroot, luks)
    return 0 if verify(esp, args.partuuid, luks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
