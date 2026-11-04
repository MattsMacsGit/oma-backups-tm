#!/usr/bin/env python3
"""oma-migrate scanner: what the user added on top of Omarchy, and what
each thing would bring back after a fresh install.

Read-only. It asks pacman, flatpak and a few tool managers what is
installed, takes away everything Omarchy installs by itself, and looks for
the settings and data that belong to what is left. Every item gets a
suggestion (keep / leave / you) with a reason, and a score that orders the
list from the decisions that matter most down to the small ones.

  migrate_scan.py            readable list
  migrate_scan.py --json     the same as JSON (what the picker reads)
  migrate_scan.py --no-sizes skip measuring folders (fast)

Run as the user. Run with sudo to also measure system folders such as
/var/lib/tailscale; the home folder is still the invoking user's.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import platform
import pwd
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KNOWN_FILE = ROOT / "share" / "migrate-known.json"
COMMON_SH = ROOT / "lib" / "common.sh"

OMARCHY_INSTALL_DIRS = [
    Path("/usr/share/omarchy/install"),
    # Older Omarchy releases kept the install scripts in the user's home.
    Path("~/.local/share/omarchy/install"),
]
OMARCHY_APPS_DIRS = [Path("/usr/share/omarchy/applications"), Path("~/.local/share/omarchy/applications")]

# The installer puts these on every system; they are never a choice.
INSTALLER_RE = re.compile(
    r"^(base|base-devel|sudo|mkinitcpio|grub|efibootmgr|systemd-boot|"
    r".+-ucode|linux(-lts|-zen|-hardened|-omarchy|-t2)?(-headers)?|linux-firmware.*)$"
)
# Building blocks rather than apps: whatever needs them pulls them in.
LIBRARY_RE = re.compile(r"^(lib.+|python-.+|perl-.+|ruby-.+|lua-.+|nodejs-.+|.+-headers|.+-docs?|ttf-.+|otf-.+|noto-.+)$")
SUFFIX_RE = re.compile(r"-(bin|git|appimage|desktop|beta|nightly|stable|electron|wayland|vulkan|cuda|rocm)$")

GB = 1024 ** 3
MB = 1024 ** 2


# ---------------------------------------------------------------- helpers

def run(cmd: list[str], timeout: int = 60) -> str:
    """Output of a command, or "" if it is missing or fails."""
    if not shutil.which(cmd[0]):
        return ""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return r.stdout if r.returncode == 0 else ""


def user_home() -> tuple[str, Path]:
    """The real user's name and home, also under sudo."""
    name = os.environ.get("SUDO_USER") if os.geteuid() == 0 else None
    if not name:
        name = pwd.getpwuid(os.getuid()).pw_name
    return name, Path(pwd.getpwnam(name).pw_dir)


USER, HOME = user_home()


def run_as_user(cmd: list[str], timeout: int = 60) -> str:
    """Per-user tool managers (uv, npm, pipx) must answer for the user, not root."""
    if os.geteuid() == 0 and USER != "root" and shutil.which("runuser"):
        return run(["runuser", "-u", USER, "--", *cmd], timeout) if shutil.which(cmd[0]) else ""
    return run(cmd, timeout)


def expand(p: str | Path) -> Path:
    s = str(p)
    if s == "~" or s.startswith("~/"):
        return HOME / s[2:]
    return Path(s)


def tilde(p: Path) -> str:
    try:
        return "~/" + str(p.relative_to(HOME))
    except ValueError:
        return str(p)


def human(n: int | None) -> str:
    if n is None:
        return "?"
    if n >= GB:
        return f"{n / GB:.1f} GB"
    if n >= MB:
        return f"{n / MB:.0f} MB"
    if n >= 1024:
        return f"{n / 1024:.0f} KB"
    return f"{n} B"


def exists(p: Path) -> bool:
    try:
        return p.exists() or p.is_symlink()
    except PermissionError:
        return False


def readable(p: Path) -> bool:
    return os.access(p, os.R_OK | (os.X_OK if p.is_dir() else 0))


class Sizer:
    """du for a batch of paths. Unreadable paths come back as None."""

    def __init__(self, enabled: bool):
        self.enabled = enabled
        self.cache: dict[str, int | None] = {}

    def size(self, paths: list[Path], skip_under: list[Path] | None = None) -> int | None:
        if not self.enabled:
            return None
        total, unknown = 0, False
        for p in paths:
            key = str(p)
            if key not in self.cache:
                if not readable(p):
                    self.cache[key] = None
                else:
                    out = run(["du", "-sb", "--", key], timeout=600)
                    # du exits non-zero when it meets one unreadable file but
                    # still prints a total, so read it from stderr-free output.
                    if not out:
                        try:
                            r = subprocess.run(["du", "-sb", "--", key], capture_output=True, text=True, timeout=600)
                            out = r.stdout
                        except (OSError, subprocess.TimeoutExpired):
                            out = ""
                    try:
                        self.cache[key] = int(out.split()[0])
                    except (IndexError, ValueError):
                        self.cache[key] = None
            n = self.cache[key]
            if n is None:
                unknown = True
            else:
                total += n
        for s in skip_under or []:
            if any(s == p or p in s.parents for p in paths):
                n = self.size([s])
                if n:
                    total -= n
        return None if unknown and total == 0 else total


# ------------------------------------------------- what Omarchy installs

def install_id() -> str:
    """Changes with every fresh install (machine-id is made fresh by the
    installer), so a saved list can tell this system from an earlier one.
    Only a hash is kept."""
    import hashlib
    try:
        mid = Path("/etc/machine-id").read_text().strip()
    except OSError:
        return ""
    return hashlib.sha256(("oma-migrate:" + mid).encode()).hexdigest()[:16]


def omarchy_version() -> str:
    out = run(["pacman", "-Q", "omarchy"]).split()
    if len(out) > 1:
        return re.sub(r"-\d+$", "", out[1])
    for f in (Path("/usr/share/omarchy/version"), expand("~/.local/share/omarchy/version")):
        try:
            return f.read_text().strip()
        except OSError:
            continue
    return "unknown"


def omarchy_defaults() -> set[str]:
    arch = platform.machine()
    names: set[str] = set()
    for d in OMARCHY_INSTALL_DIRS:
        d = expand(d)
        if not d.is_dir():
            continue
        for f in d.glob("*.packages"):
            n = f.name
            # Other machines' lists would hide things this user installed.
            if "aarch64" in n and arch != "aarch64":
                continue
            if "x86_64" in n and arch != "x86_64":
                continue
            for line in f.read_text(errors="replace").splitlines():
                line = line.split("#", 1)[0]
                names.update(line.split())
    # Everything the omarchy package itself pulls in.
    tree = run(["pactree", "-lu", "omarchy"])
    if tree:
        names.update(tree.split())
    else:
        info = run(["pacman", "-Qi", "omarchy"])
        m = re.search(r"^Depends On\s*:\s*(.+?)^\S", info, re.M | re.S)
        if m:
            names.update(re.sub(r"[<>=].*", "", w) for w in m.group(1).split())
    names.add("omarchy")
    return names


def omabackups_packages() -> set[str]:
    """Packages OmaBackups installs for itself when it needs them."""
    try:
        text = COMMON_SH.read_text()
    except OSError:
        return set()
    mapping = dict(re.findall(r"\[([\w.+-]+)\]=([\w.+-]+)", text))
    pkgs = set(mapping.values())
    for f in list(ROOT.glob("*.sh")) + list((ROOT / "lib").glob("*.sh")):
        for line in re.findall(r"ensure_deps ([\w .+-]+)", f.read_text(errors="replace")):
            pkgs.update(mapping.get(c, c) for c in line.split())
    return pkgs


# ---------------------------------------------------------- package info

def pacman_info(pkgs: list[str]) -> dict[str, dict]:
    info: dict[str, dict] = {}
    if not pkgs:
        return info
    out = run(["pacman", "-Qi", *pkgs], timeout=120)
    for block in out.split("\n\n"):
        fields: dict[str, str] = {}
        key = None
        for line in block.splitlines():
            m = re.match(r"^([A-Za-z ]+?)\s*:\s?(.*)$", line)
            if m and not line.startswith(" "):
                key = m.group(1).strip()
                fields[key] = m.group(2).strip()
            elif key:
                fields[key] += " " + line.strip()
        name = fields.get("Name")
        if not name:
            continue

        def words(k: str) -> list[str]:
            v = fields.get(k, "None")
            return [] if v == "None" else [re.sub(r"[<>=:].*", "", w) for w in v.split()]

        info[name] = {
            "desc": fields.get("Description", ""),
            "required_by": words("Required By"),
            "depends": words("Depends On"),
        }
    return info


def pacman_files(pkgs: list[str]) -> dict[str, list[str]]:
    files: dict[str, list[str]] = {p: [] for p in pkgs}
    if not pkgs:
        return files
    for line in run(["pacman", "-Ql", *pkgs], timeout=120).splitlines():
        pkg, _, path = line.partition(" ")
        if pkg in files and (path.startswith("/usr/share/applications/") or path.startswith("/usr/bin/")):
            files[pkg].append(path)
    return files


def desktop_name(path: str) -> str | None:
    try:
        for line in Path(path).read_text(errors="replace").splitlines():
            if line.startswith("Name="):
                return line[5:].strip()
            if line.startswith("[") and line != "[Desktop Entry]":
                break
    except OSError:
        pass
    return None


# ----------------------------------------------- finding settings folders

class Finder:
    """Matches app names against the folders where apps keep settings."""

    PLACES = ["~/.config", "~/.local/share", "~/.local/state", "~", "~/.var/app", "/var/lib"]

    def __init__(self, shared: set[str]):
        self.shared = {s.lower() for s in shared}
        self.index: dict[str, list[Path]] = {}
        for place in self.PLACES:
            d = expand(place)
            try:
                entries = list(d.iterdir())
            except OSError:
                continue
            for e in entries:
                n = e.name
                if place == "~":
                    if not n.startswith("."):
                        continue  # visible home folders are the user's files
                    n = n[1:]
                key = n.lower()
                if key in self.shared or len(key) < 3:
                    continue
                self.index.setdefault(key, []).append(e)
        self.claimed: set[Path] = set()

    def find(self, names: set[str]) -> list[Path]:
        hits: list[Path] = []
        for n in names:
            n = n.lower()
            if len(n) < 3 or n in self.shared:
                continue
            for variant in {n, n.replace(" ", ""), n.replace(" ", "-"), n.replace("-", ""), n.replace("_", "-")}:
                for p in self.index.get(variant, []):
                    if p not in hits and p not in self.claimed:
                        hits.append(p)
        return hits

    def claim(self, paths: list[Path]) -> None:
        self.claimed.update(paths)


def name_variants(pkg: str, files: list[str], pretty: str | None) -> set[str]:
    names = {pkg, SUFFIX_RE.sub("", pkg)}
    for f in files:
        base = Path(f).name
        if f.startswith("/usr/share/applications/") and base.endswith(".desktop"):
            stem = base[:-8]
            names.add(stem)
            names.add(stem.split(".")[-1])  # com.example.App -> App
        elif f.startswith("/usr/bin/"):
            names.add(base)
    if pretty:
        names.add(pretty)
    return {n for n in names if n}


# ---------------------------------------------------------------- scoring

def size_bonus(n: int | None) -> float:
    if not n:
        return 0.0
    return min(25.0, 6.0 * math.log10(1 + n / MB))


def item(**kw) -> dict:
    kw.setdefault("packages", [])
    kw.setdefault("paths", [])
    kw.setdefault("bytes", None)
    kw.setdefault("needs_admin", False)
    kw.setdefault("why", "")
    kw.setdefault("what", "")
    kw.setdefault("flags", [])
    return kw


def path_entries(paths: list[Path]) -> tuple[list[dict], bool]:
    out, admin = [], False
    for p in paths:
        r = readable(p)
        admin |= not r
        out.append({"path": tilde(p), "readable": r})
    return out, admin


# ---------------------------------------------------------------- scanning

def scan_packages(known: dict, finder: Finder, sizer: Sizer, defaults: set[str], oma: set[str]) -> tuple[list[dict], dict]:
    explicit = run(["pacman", "-Qqe"]).split()
    foreign = set(run(["pacman", "-Qqm"]).split())
    notes = {"installer": [], "with_omabackups": [], "folded": {}}

    cands = []
    for p in explicit:
        if p in defaults:
            continue
        if INSTALLER_RE.match(p):
            notes["installer"].append(p)
        elif p in oma:
            notes["with_omabackups"].append(p)
        else:
            cands.append(p)

    info = pacman_info(cands)
    files = pacman_files(cands)
    cset = set(cands)

    # Something this user installed that another of their picks needs goes
    # with that pick (libfprint with fprintd). Something an Omarchy package
    # needs comes back with Omarchy anyway.
    parent: dict[str, str] = {}
    for p in cands:
        req = info.get(p, {}).get("required_by", [])
        owners = [r for r in req if r in cset and r != p]
        if owners:
            parent[p] = sorted(owners)[0]
        elif any(r in defaults for r in req):
            parent[p] = ""
    def top(p: str) -> str:
        seen = set()
        while p in parent and parent[p] and p not in seen:
            seen.add(p)
            p = parent[p]
        return p
    groups: dict[str, list[str]] = {}
    for p in cands:
        if parent.get(p) == "":
            notes.setdefault("needed_by_omarchy", []).append(p)
            continue
        groups.setdefault(top(p), []).append(p)

    items = []
    apps = known.get("apps", {})
    # Most important first, so the main app claims a shared folder
    # (Arduino IDE gets ~/.arduino15, not the Arduino command-line tool).
    def weight(head: str) -> float:
        return max((float(apps[m].get("weight", 0)) for m in groups[head] if m in apps), default=0.0)
    for head in sorted(groups, key=weight, reverse=True):
        members = groups[head]
        members = [head] + sorted(m for m in members if m != head)  # noqa: PLW2901
        if len(members) > 1:
            notes["folded"][head] = members[1:]
        k = next((apps[m] for m in members if m in apps), None)
        gui = [f for m in members for f in files.get(m, []) if f.endswith(".desktop")]
        pretty = (k or {}).get("name") or (desktop_name(gui[0]) if gui else None)

        paths: list[Path] = []
        if k:
            paths += [expand(x) for x in k.get("paths", []) if exists(expand(x)) and expand(x) not in finder.claimed]
        for m in members:
            paths += [p for p in finder.find(name_variants(m, files.get(m, []), pretty if m == head else None)) if p not in paths]
        finder.claim(paths)
        size = sizer.size(paths)
        entries, admin = path_entries(paths)

        is_lib = all(LIBRARY_RE.match(m) for m in members) and not gui
        if k:
            suggest, why, base = k["suggest"], k.get("why", ""), float(k.get("weight", 30))
            if not why and suggest == "you":
                why = "its settings come back with it if you keep it" if paths else "quick to install again"
        elif is_lib:
            suggest, why, base = "leave", "a building block; anything that needs it installs it again", 5.0
        elif paths and gui:
            suggest, why, base = "keep", "your settings come back with it", 35.0
        elif gui:
            suggest, why, base = "you", "nothing to bring back; quick to install again", 20.0
        elif paths:
            suggest, why, base = "you", "its settings come back with it if you keep it", 18.0
        else:
            suggest, why, base = "you", "a command-line tool; quick to install again", 10.0

        flags = []
        if size and size >= 5 * GB:
            flags.append("big")
            if suggest == "keep":
                why = (why + "; " if why else "") + f"copying {human(size)} back takes a while"
        items.append(item(
            id="pkg:" + head, group="apps", kind="package",
            name=pretty or head,
            what=info.get(head, {}).get("desc", ""),
            packages=members, source="aur" if any(m in foreign for m in members) else "repo",
            paths=entries, bytes=size, needs_admin=admin,
            suggest=suggest, why=why, flags=flags,
            score=round(base + size_bonus(size), 1),
        ))
    return items, notes


def scan_flatpaks(known: dict, finder: Finder, sizer: Sizer) -> list[dict]:
    items = []
    for line in run_as_user(["flatpak", "list", "--app", "--columns=application,name,origin"]).splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        app_id, name = parts[0], parts[1]
        k = known.get("apps", {}).get(app_id)
        paths = [p for p in [expand(f"~/.var/app/{app_id}")] if exists(p)]
        finder.claim(paths)
        size = sizer.size(paths, [expand(f"~/.var/app/{app_id}/cache")])
        entries, admin = path_entries(paths)
        items.append(item(
            id="flatpak:" + app_id, group="apps", kind="flatpak", name=(k or {}).get("name", name),
            what="Flatpak app", packages=[app_id], source="flatpak",
            paths=entries, bytes=size, needs_admin=admin,
            suggest=(k or {}).get("suggest", "keep" if paths else "you"),
            why=(k or {}).get("why", "your settings come back with it" if paths else "quick to install again"),
            score=round(float((k or {}).get("weight", 30)) + size_bonus(size), 1),
        ))
    return items


def scan_settings(known: dict, finder: Finder, sizer: Sizer) -> list[dict]:
    items = []
    for s in known.get("settings", []):
        paths = [expand(p) for p in s["paths"] if exists(expand(p))]
        if not paths:
            continue
        finder.claim(paths)
        skip = [expand(p) for p in s.get("skip_under", [])]
        size = sizer.size(paths, skip)
        entries, admin = path_entries(paths)
        items.append(item(
            id="setting:" + s["id"], group="settings", kind="setting", name=s["name"], what=s.get("what", ""),
            paths=entries, bytes=size, needs_admin=admin, suggest=s["suggest"], why=s.get("why", ""),
            flags=["merge"] if s.get("merge") else [],
            skip_under=[tilde(p) for p in skip],
            score=round(float(s.get("weight", 50)) + size_bonus(size) / 5, 1),
        ))
    return items


def scan_webapps(sizer: Sizer) -> list[dict]:
    d = expand("~/.local/share/applications")
    defaults = set()
    for ad in OMARCHY_APPS_DIRS:
        ad = expand(ad)
        if ad.is_dir():
            defaults.update(f.name for f in ad.glob("*.desktop"))
    by_app: dict[str, dict] = {}
    for f in sorted(d.glob("*.desktop")) if d.is_dir() else []:
        if f.name in defaults:
            continue
        try:
            text = f.read_text(errors="replace")
        except OSError:
            continue
        execl = next((l[5:] for l in text.splitlines() if l.startswith("Exec=")), "")
        name = next((l[5:] for l in text.splitlines() if l.startswith("Name=")), f.stem)
        icon = next((l[5:] for l in text.splitlines() if l.startswith("Icon=")), "")
        m = re.search(r"--app-id=(\w+)", execl) if re.search(r"chromium|chrome|brave", execl) else None
        if m:
            key, shortcut = "pwa:" + m.group(1), "--app-launch-url-for-shortcuts-menu-item" in execl
        elif "omarchy-launch-webapp" in execl or "--app=" in execl:
            key, shortcut = "web:" + f.stem, False
        else:
            continue
        e = by_app.setdefault(key, {"names": [], "files": [], "icons": []})
        if not shortcut:
            e["names"].insert(0, name)
        e["files"].append(f)
        if icon:
            ip = Path(icon) if icon.startswith("/") else next(iter(expand("~/.local/share/icons").rglob(icon + ".*")), None) if expand("~/.local/share/icons").is_dir() else None
            if ip and exists(ip) and ip not in e["icons"]:
                e["icons"].append(ip)
    items = []
    for key, e in by_app.items():
        name = (e["names"] or [e["files"][0].stem])[0]
        paths = e["files"] + e["icons"]
        entries, _ = path_entries(paths)
        items.append(item(
            id="webapp:" + key.split(":", 1)[1], group="extras", kind="webapp", name=name,
            what="Web app you added" + (" (installed from Chromium)" if key.startswith("pwa:") else ""),
            paths=entries, bytes=sizer.size(paths), suggest="keep",
            why="Omarchy's standard web apps come back by themselves; this one doesn't",
            score=30.0,
        ))
    return items


def scan_plugins(sizer: Sizer) -> list[dict]:
    d = expand("~/.config/omarchy/plugins")
    items = []
    for p in sorted(d.iterdir()) if d.is_dir() else []:
        if not p.is_dir() or p.name == "oma.backups":
            continue
        try:
            man = json.loads((p / "manifest.json").read_text())
        except (OSError, ValueError):
            man = {}
        entries, _ = path_entries([p])
        items.append(item(
            id="plugin:" + p.name, group="extras", kind="plugin", name=man.get("name") or p.name,
            what=man.get("description", "Omarchy plugin"), packages=[p.name],
            paths=entries, bytes=sizer.size([p]), suggest="keep",
            why="plugins aren't part of Omarchy, so they only come back if you keep them",
            score=28.0,
        ))
    return items


def scan_tools(sizer: Sizer) -> list[dict]:
    """Command-line tools from installers other than pacman."""
    items = []
    tools: list[tuple[str, str, str]] = []  # (manager, name, reinstall hint)
    for line in run_as_user(["uv", "tool", "list"]).splitlines():
        if line and not line.startswith(("-", " ")):
            tools.append(("uv", line.split()[0], "uv tool install"))
    npm = run_as_user(["npm", "ls", "-g", "--depth=0", "--json"])
    try:
        for n in json.loads(npm or "{}").get("dependencies", {}):
            if n not in ("npm", "corepack"):
                tools.append(("npm", n, "npm install -g"))
    except ValueError:
        pass
    for n in run_as_user(["pipx", "list", "--short"]).splitlines():
        if n.strip():
            tools.append(("pipx", n.split()[0], "pipx install"))
    cargo = expand("~/.cargo/bin")
    if cargo.is_dir():
        for f in sorted(cargo.iterdir()):
            if f.name not in ("cargo", "rustc", "rustup", "rustdoc", "rust-gdb", "rust-lldb", "rustfmt", "cargo-fmt", "clippy-driver", "cargo-clippy", "rust-analyzer"):
                tools.append(("cargo", f.name, "cargo install"))
    mise_cfg = expand("~/.config/mise/config.toml")
    if mise_cfg.is_file():
        in_tools = False
        for line in mise_cfg.read_text(errors="replace").splitlines():
            s = line.strip()
            if s.startswith("["):
                in_tools = s == "[tools]"
                continue
            if in_tools and "=" in s and not s.startswith("#"):
                tools.append(("mise", s.split("=", 1)[0].strip().strip('"'), "mise use -g"))
    for mgr, name, hint in tools:
        items.append(item(
            id=f"tool:{mgr}:{name}", group="extras", kind="tool", name=name,
            what=f"Command-line tool installed with {mgr}", packages=[name], source=mgr,
            suggest="you", why="quick to install again", score=8.0, reinstall=f"{hint} {name}",
        ))

    # The user's own scripts and links in ~/.local/bin.
    lb = expand("~/.local/bin")
    own = []
    if lb.is_dir():
        for f in sorted(lb.iterdir()):
            if f.name in ("oma-backups", "omarchy-backups", "omarchy-tm", "oma-migrate"):
                continue
            target = os.path.realpath(f)
            if target.startswith(("/usr/", str(expand("~/.local/share/omarchy")))):
                continue
            own.append(f)
    if own:
        items.append(item(
            id="setting:local-bin", group="extras", kind="scripts", name="Your scripts",
            what="Commands in ~/.local/bin: " + ", ".join(f.name for f in own[:12]) + (" …" if len(own) > 12 else ""),
            paths=path_entries(own)[0], bytes=sizer.size(own), suggest="keep",
            why="small, and some of them may be things you wrote", score=32.0,
        ))
    return items


def scan_home(known: dict, finder: Finder, sizer: Sizer, quiet: bool) -> list[dict]:
    items = []
    for p in sorted(HOME.iterdir()):
        if p.name.startswith(".") or not p.is_dir() or p.is_symlink() or p in finder.claimed:
            continue
        if not quiet and sizer.enabled:
            print(f"  measuring ~/{p.name} …", file=sys.stderr)
        size = sizer.size([p])
        if size is not None and size < 512:
            continue  # nothing in it (maybe empty folders); Omarchy makes the standard ones again
        down = p.name.lower() == "downloads"
        items.append(item(
            id="folder:" + p.name, group="files", kind="folder", name=p.name, what="",
            paths=path_entries([p])[0], bytes=size,
            suggest="you" if down else "keep",
            why="often a junk drawer; you can pull files out of the backup later instead" if down else "",
            flags=["big"] if size and size >= 50 * GB else [],
            score=round(40.0 + size_bonus(size) - (15 if down else 0), 1),
        ))

    # Hidden folders nothing above claimed, if they are big enough to matter.
    for p in sorted(HOME.iterdir()):
        if not p.name.startswith(".") or not p.is_dir() or p.is_symlink():
            continue
        if p.name in (".cache", ".local", ".config", ".var", ".thumbnails", ".Trash", ".pki", ".npm", ".cargo", ".rustup") or p in finder.claimed:
            continue
        if any(c in p.parents or c == p for c in finder.claimed):
            continue
        hk = known.get("hidden", {}).get(p.name, {})
        if hk.get("skip"):
            continue
        size = sizer.size([p])
        if size is None or size < 50 * MB:
            continue
        items.append(item(
            id="hidden:" + p.name, group="extras", kind="hidden", name=hk.get("name", p.name),
            what=f"Hidden folder ~/{p.name}" + ("" if hk else ", not matched to an app on this list"),
            paths=path_entries([p])[0], bytes=size, suggest=hk.get("suggest", "you"),
            why=hk.get("why") or ("" if hk else "probably left by an app or tool; leave it unless you know what it is"),
            score=round(6.0 + size_bonus(size) / 2, 1),
        ))
    return items


GROUP_ORDER = ["settings", "apps", "files", "extras"]
GROUP_TITLES = {
    "settings": "Settings & logins",
    "apps": "Apps you installed",
    "files": "Your files",
    "extras": "Plugins, web apps & tools",
}


def scan(sizes: bool, quiet: bool) -> dict:
    t0 = time.time()
    known = json.loads(KNOWN_FILE.read_text())
    finder = Finder(set(known.get("shared_dirs", [])))
    sizer = Sizer(sizes)
    defaults = omarchy_defaults()
    oma = omabackups_packages()
    if not quiet:
        print("Looking at installed packages …", file=sys.stderr)
    # Settings first so a browser profile is the setting, not an app's folder.
    items = scan_settings(known, finder, sizer)
    pkg_items, notes = scan_packages(known, finder, sizer, defaults, oma)
    items += pkg_items
    items += scan_flatpaks(known, finder, sizer)
    items += scan_webapps(sizer)
    items += scan_plugins(sizer)
    items += scan_tools(sizer)
    if not quiet and sizes:
        print("Measuring your folders (the big ones take a moment) …", file=sys.stderr)
    items += scan_home(known, finder, sizer, quiet)
    # A web app named like an app on the list (Omarchy's Tailscale admin page
    # next to Tailscale itself) says which one it is.
    names = {i["name"].lower() for i in items if i["kind"] != "webapp"}
    for i in items:
        if i["kind"] == "webapp" and i["name"].lower() in names:
            i["name"] += " (web app)"
    items.sort(key=lambda i: (GROUP_ORDER.index(i["group"]), -i["score"], i["name"].lower()))
    return {
        "format": 1,
        "tool": "oma-migrate",
        "scanned_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "omarchy_version": omarchy_version(),
        "user": USER,
        "install_id": install_id(),
        "sizes_measured": sizes,
        "ran_as_admin": os.geteuid() == 0,
        "groups": [{"id": g, "title": GROUP_TITLES[g]} for g in GROUP_ORDER],
        "items": items,
        "notes": {
            "omarchy_default_packages": len(defaults),
            "installer_packages": sorted(notes["installer"]),
            "come_back_with_omabackups": sorted(notes["with_omabackups"]),
            "needed_by_omarchy": sorted(notes.get("needed_by_omarchy", [])),
            "grouped_with": notes["folded"],
            "seconds": round(time.time() - t0, 1),
        },
    }


def print_readable(r: dict) -> None:
    mark = {"keep": "Keep ", "leave": "Leave", "you": "  ?  "}
    print(f"oma-migrate scan · Omarchy {r['omarchy_version']} · {len(r['items'])} things to decide\n")
    for g in r["groups"]:
        rows = [i for i in r["items"] if i["group"] == g["id"]]
        if not rows:
            continue
        print(f"== {g['title']} ({len(rows)})")
        for i in rows:
            size = human(i["bytes"]) if i["paths"] else ""
            if i["needs_admin"] and i["bytes"] is None:
                size = "needs sudo"
            pk = ""
            if i["kind"] == "package" and (i["packages"][0] != i["name"] or len(i["packages"]) > 1):
                pk = "  [" + " ".join(i["packages"]) + "]"
            print(f"  {mark[i['suggest']]}  {i['name'][:34]:<34} {size:>10}  {i['why'][:70]}{pk}")
        print()
    n = r["notes"]
    print(f"Not listed: {n['omarchy_default_packages']} packages Omarchy installs itself; "
          f"handled by the installer: {', '.join(n['installer_packages']) or 'none'}; "
          f"come back with OmaBackups: {', '.join(n['come_back_with_omabackups']) or 'none'}.")
    if n["needed_by_omarchy"]:
        print(f"Needed by Omarchy anyway: {', '.join(n['needed_by_omarchy'])}.")
    print(f"Scanned in {n['seconds']} s.")


def main() -> int:
    ap = argparse.ArgumentParser(description="What you added on top of Omarchy, and what it would bring back.")
    ap.add_argument("--json", action="store_true", help="print JSON (for the picker)")
    ap.add_argument("--no-sizes", action="store_true", help="don't measure folders (fast)")
    a = ap.parse_args()
    if not shutil.which("pacman"):
        print("oma-migrate: this needs an Arch-based system with pacman (Omarchy).", file=sys.stderr)
        return 1
    r = scan(sizes=not a.no_sizes, quiet=a.json)
    if a.json:
        json.dump(r, sys.stdout, indent=1)
        print()
    else:
        print_readable(r)
    return 0


if __name__ == "__main__":
    sys.exit(main())
