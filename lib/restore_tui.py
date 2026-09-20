#!/usr/bin/env python3
"""OmaBackups restore wizard. Runs on the rescue USB (tty1 autologin).

Stdlib plus `gum` for all interactive UI (choose/confirm/input) and
styled text, matching format-disk.sh/backup.sh's house style — gum ships
in the real Omarchy ISO's package set, confirmed present in its squashfs
before relying on it here. Step-through prompts, not a full desktop.
"""

from __future__ import annotations

import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(os.environ.get("OMARCHY_TM_ROOT") or Path(__file__).resolve().parent.parent)
CLI = ROOT / "omarchy-backups"
MNT = Path("/run/omarchy-backups")

# OMANET-*: a network rescue stick (see rescue-stick.sh).
# Compared uppercased (see labels_of). The 1.1 names sit alongside the older
# ones so a disk built before the rename still identifies itself.
LIVE_LABELS = {"OMABOOT", "OMARESCUE", "OMANETBOOT", "OMANETRESCUE",
               "OMARCHY-EFI", "OMARCHY-LIVE", "OMANET-EFI", "OMANET-LIVE"}
BACKUP_LABELS = {"OMABACKUPS", "OMARCHY-TM", "OMARCHY-BACKUPS"}
INSTALLER_LABELS = {"VENTOY", "VTOYEFI", "CLONEZILLA", "CLONEZILLA-LIVE"}

# A network rescue stick restores from the paired Pi (rescue-stick.sh made it).
NET = (ROOT / "network-rescue.json").is_file()
# The stick's keys partition carries the name twice: as a LUKS2 label and as
# the GPT partition name. Boot with only one of them visible and the whole
# stick is useless, so look for both.
# Looked up as a path under /dev/disk/by-label, so case matters here.
NET_KEYS_LABELS = ("OmaNetKeys", "OMANET-KEYS")
NET_KEYS_MAPPER = "oma-netkeys"
REMOTE_DIR = Path("/etc/omarchy-backups/remote")
REMOTE_CONF = Path("/etc/omarchy-backups/remote.json")
TS_DIR = Path("/run/oma-tailscale")


def out(msg: str = "") -> None:
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()


# gum house style, matching format-disk.sh/backup.sh: foreground 1=error,
# 2=success, 3=warning, 8=dim. gum's interactive widgets (choose/confirm/
# input) render their UI to stderr and print only the chosen/typed value
# to stdout — so these only capture stdout, never stderr, or the picker
# itself would never be visible (confirmed against Omarchy's own
# omarchy-drive-select, which uses the same convention).


def gum_style(*args: str) -> None:
    subprocess.run(["gum", "style", *args], check=False)


def gum_choose(options: list[str], header: str = "Choose:") -> str | None:
    if not options:
        return None
    proc = subprocess.run(
        ["gum", "choose", "--header", header, *options],
        stdout=subprocess.PIPE,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        return None
    choice = proc.stdout.rstrip("\n")
    return choice or None


def gum_confirm(prompt: str) -> bool:
    return subprocess.run(["gum", "confirm", prompt], check=False).returncode == 0


def gum_input(
    header: str = "",
    placeholder: str = "",
    password: bool = False,
) -> str | None:
    argv = ["gum", "input"]
    if header:
        argv += ["--header", header]
    if placeholder:
        argv += ["--placeholder", placeholder]
    if password:
        argv.append("--password")
    proc = subprocess.run(argv, stdout=subprocess.PIPE, text=True, check=False)
    if proc.returncode != 0:
        return None
    return proc.stdout.rstrip("\n")


def quiet_console() -> None:
    """Keep printk from drowning the wizard; the live ISO still has a real console."""
    subprocess.run(["dmesg", "-n", "4"], check=False, capture_output=True)


def banner() -> None:
    os.system("clear") if sys.stdout.isatty() else None
    out()
    gum_style("--bold", "OmaBackups — network restore" if NET else "OmaBackups — restore")
    gum_style(
        "--foreground",
        "8",
        "This USB can put your Omarchy machine back onto a blank disk:",
    )
    gum_style("--foreground", "8", "same user, same packages, same home as a backup date.")
    if NET:
        gum_style("--foreground", "8", "It restores from the backup disk on your Pi, over the network.")
    out()


def pause(msg: str = "Press Enter to continue, or q for a shell.") -> bool:
    s = gum_input(header=msg, placeholder="")
    if s is None:
        return False
    return s.strip().lower() not in {"q", "quit", "exit"}


def ask(prompt: str, default: str = "") -> str:
    s = gum_input(header=prompt, placeholder=default)
    if s is None:
        return default
    return s.strip() or default


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
    if labs & LIVE_LABELS or labs & BACKUP_LABELS:
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
        gum_style("--foreground", "8", f"Backup disk already mounted at {MNT}")
        return True
    gum_style("--foreground", "8", "Unlocking the backup disk. Type the backup disk's password — the one you")
    gum_style("--foreground", "8", "chose when you set the disk up, not your login password.")
    env = os.environ.copy()
    env["OMARCHY_TM_ROOT"] = str(ROOT)
    env["OMARCHY_TM_YES"] = "1"
    # cryptsetup's own interactive prompt handles the passphrase — the
    # right tool for that job, not something to route through gum.
    proc = subprocess.run([str(CLI), "mount"], env=env)
    if proc.returncode != 0:
        gum_style("--foreground", "1", "Could not unlock the backup disk.")
        gum_style("--foreground", "8", "Check the password and try again. If this USB has just been plugged in,")
        gum_style("--foreground", "8", "give it a few seconds and choose Retry.")
        out("To try again from the shell: oma-backups mount")
        return False
    return True


# —— Network rescue: the stick's keys, getting online, finding the Pi ——

NET_CONF: dict = {}
PI_HOST = ""


def pi_ssh(host: str, *args: str, timeout: int = 10) -> list[str]:
    """Same connection as lib/remote.sh, with the Pi's key pinned by the stick."""
    return [
        "ssh", "-i", str(REMOTE_DIR / "id_ed25519"), "-p", str(NET_CONF.get("port", 22)),
        "-l", "omabackups", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
        "-o", f"ConnectTimeout={timeout}", "-o", "LogLevel=ERROR",
        "-o", "StrictHostKeyChecking=yes", "-o", f"HostKeyAlias={NET_CONF.get('host_key_alias', 'oma-pi')}",
        "-o", f"UserKnownHostsFile={REMOTE_DIR / 'known_hosts'}",
        host, *args,
    ]


def pi(*args: str, stdin: bytes | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(pi_ssh(PI_HOST, *args), input=stdin, capture_output=True, check=False)


def net_keys_dev() -> Path | None:
    """The stick's keys partition, by LUKS label or by GPT partition name."""
    for _ in range(2):
        for base in ("by-label", "by-partlabel"):
            for label in NET_KEYS_LABELS:
                dev = Path("/dev/disk", base, label)
                if dev.exists():
                    return dev
        settle_block_devices()
    return None


def open_stick_keys(password: bytes) -> bool:
    """Unlock the stick's keys partition and copy what's in it to /etc (RAM)."""
    dev = net_keys_dev()
    if dev is None:
        gum_style("--foreground", "1", "Can't find this stick's keys. Is it the rescue stick you made?")
        return False
    proc = subprocess.run(
        ["cryptsetup", "open", "--key-file=-", str(dev), NET_KEYS_MAPPER],
        input=password, capture_output=True, check=False,
    )
    if proc.returncode != 0 and not Path("/dev/mapper", NET_KEYS_MAPPER).exists():
        return False
    mnt = Path("/run/oma-netkeys")
    mnt.mkdir(parents=True, exist_ok=True)
    try:
        if run(["mount", "-o", "ro", f"/dev/mapper/{NET_KEYS_MAPPER}", str(mnt)]).returncode != 0:
            return False
        old = os.umask(0o077)
        try:
            REMOTE_DIR.mkdir(parents=True, exist_ok=True)
            for name in ("id_ed25519", "known_hosts", "rescue.json"):
                shutil.copyfile(mnt / name, REMOTE_DIR / name)
        finally:
            os.umask(old)
        NET_CONF.update(json.loads((REMOTE_DIR / "rescue.json").read_text(encoding="utf-8")))
        return True
    except (OSError, json.JSONDecodeError):
        return False
    finally:
        run(["umount", str(mnt)])
        run(["cryptsetup", "close", NET_KEYS_MAPPER])


def is_tailscale(addr: str) -> bool:
    try:
        return ipaddress.ip_address(addr) in ipaddress.ip_network("100.64.0.0/10")
    except ValueError:
        return False


def candidates(tailscale_up: bool) -> list[str]:
    addrs = [a for a in NET_CONF.get("addresses") or [] if isinstance(a, str)]
    host = str(NET_CONF.get("host") or "")
    lan = [a for a in addrs if not is_tailscale(a)]
    ts = [a for a in addrs if is_tailscale(a)]
    order = lan + [host] + (ts if tailscale_up else [])
    return [a for i, a in enumerate(order) if a and a not in order[:i]]


def find_pi(tailscale_up: bool) -> str | None:
    for host in candidates(tailscale_up):
        gum_style("--foreground", "8", f"  Trying {host}...")
        proc = subprocess.run(pi_ssh(host, "version", timeout=5), capture_output=True, text=True, check=False)
        if proc.returncode == 0 and proc.stdout.strip().isdigit():
            return host
    return None


def online() -> bool:
    return bool(run(["ip", "route", "show", "default"]).stdout.strip())


ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def wifi_devices() -> list[str]:
    try:
        return sorted(p.parent.name for p in Path("/sys/class/net").glob("*/wireless"))
    except OSError:
        return []


# iwd keeps one file per saved network here (the rescue ISO ships iwd, no
# NetworkManager — checked against its package list).
IWD_DIR = Path("/var/lib/iwd")


def wifi_power_on(dev: str) -> None:
    '''A soft-blocked radio looks exactly like "there are no networks here".'''
    if shutil.which("rfkill"):
        run(["rfkill", "unblock", "wlan"])
    run(["iwctl", "device", dev, "set-property", "Powered", "on"])


def iwd_network_files(ssid: str) -> list[Path]:
    """Where iwd would keep this network, best spelling first.

    iwd names a saved network after its SSID. A plain one is used as the file
    name as it stands; anything that can't go in a file name is stored
    hex-encoded behind an '='. Both spellings come back so the one we don't
    write can be deleted — two files for one network is how iwd ends up
    reconnecting with the old, wrong password.
    """
    hexed = IWD_DIR / ("=" + ssid.encode().hex() + ".psk")
    if ssid and not ssid.startswith("=") and re.fullmatch(r"[A-Za-z0-9 ._-]+", ssid):
        return [IWD_DIR / (ssid + ".psk"), hexed]
    return [hexed]


def wifi_save_password(ssid: str, pw: str) -> bool:
    """Give the password to iwd directly instead of typing it at iwctl.

    iwctl only accepts a passphrase through an interactive agent that wants a
    real terminal, so feeding it one down a pipe does not reliably work — and
    --passphrase would put the password in the process list for anything on
    the machine to read. Neither is needed: iwd picks a saved network up from
    this directory by itself and connects with it.
    """
    files = iwd_network_files(ssid)
    try:
        IWD_DIR.mkdir(parents=True, exist_ok=True)
        for stale in files[1:]:
            stale.unlink(missing_ok=True)
        files[0].write_text("[Security]\nPassphrase=" + pw + "\n")
        files[0].chmod(0o600)
    except OSError as exc:
        gum_style("--foreground", "1", f"  Couldn't save the Wi-Fi password: {exc}")
        return False
    time.sleep(1)  # iwd watches the directory; give it a moment to notice
    return True


def wifi_state(dev: str) -> str:
    text = ANSI.sub("", run(["iwctl", "station", dev, "show"]).stdout)
    found = re.search(r"^\s*State\s+(\S+)", text, re.M)
    return found.group(1) if found else ""


def wifi_connect(dev: str, ssid: str) -> tuple[bool, str]:
    """Connect and get an address. Returns (online, what to tell them).

    Three different failures used to come out as one guess — "check the
    password" — whether the password was wrong, the radio was off, or the
    router simply never handed out an address. Each says its own piece now,
    and if iwctl itself refuses, it gets to say why in its own words.
    """
    # stdin stays attached to the terminal on purpose: if iwd somehow hasn't
    # picked up the saved password, iwctl asks for it here and they can just
    # type it, rather than the wizard failing for a reason nobody can see.
    # The timeout is only so that can never become a wait with no end to it.
    try:
        proc = subprocess.run(
            ["iwctl", "station", dev, "connect", ssid],
            capture_output=True, text=True, check=False, timeout=120,
        )
    except subprocess.TimeoutExpired:
        return False, f"Gave up waiting for {ssid} to answer."
    if proc.returncode != 0:
        detail = ANSI.sub("", (proc.stdout or "") + " " + (proc.stderr or ""))
        detail = " ".join(detail.split())[:200]
        return False, detail or f"Couldn't connect to {ssid}."
    for _ in range(20):
        if wifi_state(dev).lower() == "connected":
            break
        time.sleep(1)
    else:
        return False, f"{ssid} wouldn't accept that password."
    if wait_online(30):
        return True, ""
    return False, f"Joined {ssid}, but it didn't give this computer an address."


def wifi_networks(dev: str) -> list[tuple[str, str]]:
    run(["iwctl", "station", dev, "scan"])
    time.sleep(4)
    text = ANSI.sub("", run(["iwctl", "station", dev, "get-networks"]).stdout)
    nets: list[tuple[str, str]] = []
    rows = text.splitlines()
    dashes = [i for i, line in enumerate(rows) if set(line.strip()) == {"-"}]
    for line in rows[dashes[-1] + 1:] if dashes else []:
        cols = re.split(r"\s{2,}", line.strip().lstrip(">").strip())
        if len(cols) >= 2 and cols[0]:
            nets.append((cols[0], cols[1]))
    return nets


def wait_online(seconds: int = 30) -> bool:
    for _ in range(seconds):
        if online():
            return True
        time.sleep(1)
    return False


def wifi_setup() -> bool:
    devs = wifi_devices()
    if not devs:
        gum_style("--foreground", "3", "No network. Plug in a network cable, then press Enter.")
        pause("Press Enter to try again, or q for a shell.")
        return wait_online(15)
    dev = devs[0]
    wifi_power_on(dev)
    while True:
        gum_style("--foreground", "8", "Looking for Wi-Fi networks...")
        nets = wifi_networks(dev)
        options = [name for name, _sec in nets] + ["Scan again", "I'll plug in a cable", "Cancel"]
        choice = gum_choose(options, header="Connect to Wi-Fi")
        if choice is None or choice == "Cancel":
            return False
        if choice == "Scan again":
            continue
        if choice == "I'll plug in a cable":
            pause("Plug in the cable, then press Enter.")
            return wait_online(15)
        if dict(nets).get(choice, "psk") != "open":
            pw = gum_input(header=f"Wi-Fi password for {choice}", password=True)
            if pw is None:
                continue
            if not wifi_save_password(choice, pw):
                continue
        gum_style("--foreground", "8", f"Connecting to {choice}...")
        ok, why = wifi_connect(dev, choice)
        if ok:
            return True
        gum_style("--foreground", "3", f"  {why}")


def tailscale_up() -> bool:
    if not (shutil.which("tailscale") and shutil.which("tailscaled")):
        return False
    sock = TS_DIR / "tailscaled.sock"
    if not sock.exists():
        TS_DIR.mkdir(parents=True, exist_ok=True)
        log = open(TS_DIR / "tailscaled.log", "ab")
        # State in memory only: this computer drops off your Tailscale
        # network by itself once it's switched off.
        subprocess.Popen(
            ["tailscaled", "--state=mem:", f"--statedir={TS_DIR}", f"--socket={sock}"],
            stdout=log, stderr=log, start_new_session=True,
        )
        for _ in range(20):
            if sock.exists():
                break
            time.sleep(0.5)
    out()
    gum_style("--bold", "Log in to Tailscale")
    gum_style("--foreground", "8", "Scan the code with your phone, or open the link on any device, and log in")
    gum_style("--foreground", "8", "with the same account as your Pi. This computer joins until it's switched off.")
    out()
    rc = subprocess.call(["tailscale", f"--socket={sock}", "up", "--qr", "--hostname=oma-rescue", "--timeout=10m"])
    return rc == 0


def connect_pi() -> bool:
    """Open the stick, get online, find the Pi, and unlock its backup disk."""
    global PI_HOST
    if net_keys_dev() is None:
        gum_style("--foreground", "1", "Can't find this stick's keys.")
        gum_style("--foreground", "8", "Is this the rescue stick you made? Try a different USB socket.")
        return False
    gum_style("--foreground", "8", "Type the backup disk's password. It opens this stick and the backup disk on your Pi.")
    for _ in range(3):
        typed = gum_input(header="Backup disk password", password=True)
        if typed is None:
            return False
        if typed and open_stick_keys(typed.encode()):
            password = typed.encode()
            break
        gum_style("--foreground", "1", "That password doesn't open this stick.")
    else:
        return False

    gum_style("--foreground", "8", "Looking for your Pi...")
    # A network cable usually connects by itself within a few seconds.
    if not wait_online(8):
        gum_style("--foreground", "8", "This computer isn't online yet.")
        wifi_setup()
    host = find_pi(tailscale_up=False)
    if host is None and online() and tailscale_up():
        host = find_pi(tailscale_up=True)
    if host is None:
        gum_style("--foreground", "1", "Couldn't reach your Pi.")
        gum_style("--foreground", "8", "Check it's switched on, that this computer is online, and (away from")
        gum_style("--foreground", "8", "home) that you logged in to Tailscale with the same account as the Pi.")
        return False
    PI_HOST = host
    gum_style("--foreground", "2", f"  Found your Pi at {host}.")

    # restore-to-disk --from-pi reads this, through lib/remote.sh.
    REMOTE_CONF.write_text(json.dumps({
        "host": host,
        "port": NET_CONF.get("port", 22),
        "host_key_alias": NET_CONF.get("host_key_alias", "oma-pi"),
    }) + "\n", encoding="utf-8")

    gum_style("--foreground", "8", "Unlocking the backup disk on the Pi...")
    st = pi("status")
    try:
        if not json.loads(st.stdout or b"{}").get("present"):
            gum_style("--foreground", "1", "The backup disk isn't plugged into the Pi (or its USB hub has no power).")
            return False
    except json.JSONDecodeError:
        pass
    proc = pi("unlock", stdin=password)
    password = b""
    if proc.returncode != 0:
        gum_style("--foreground", "1", "The Pi couldn't unlock the backup disk.")
        msg = proc.stderr.decode(errors="replace").strip()
        if msg:
            gum_style("--foreground", "8", msg)
        return False
    return True


def lock_pi() -> None:
    if NET and PI_HOST:
        pi("lock")


def load_snapshots() -> list[dict]:
    if NET:
        proc = pi("list")
        try:
            snaps = json.loads(proc.stdout or b"[]") if proc.returncode == 0 else []
        except json.JSONDecodeError:
            snaps = []
        return [s for s in snaps if s.get("valid") and not s.get("home_only")]
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
        gum_style("--foreground", "3", "No full restore points on this disk (need os+home+esp).")
        return None
    by_label: dict[str, dict] = {}
    options: list[str] = []
    for s in snaps:
        label = s.get("label") or s.get("timestamp") or "?"
        ver = s.get("omarchy_version") or ""
        display = f"{label}  Omarchy {ver}" if ver else label
        # Two snapshots could share a display string in principle (rare —
        # same label, same/missing version) — keep the first, the rest
        # are still reachable by their raw timestamp being distinct.
        if display not in by_label:
            by_label[display] = s
            options.append(display)
    options.append("Cancel")
    choice = gum_choose(options, header="Choose a restore point")
    if choice is None or choice == "Cancel":
        return None
    return by_label.get(choice)


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
        gum_style("--foreground", "8", "Disks the kernel can see:")
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
            gum_style("--foreground", "8", "This backup/rescue USB is not offered as a restore target.")
            out()
        if not candidates:
            gum_style("--foreground", "3", "No other disks yet (USB card readers are often slow).")
            if not gum_confirm("Scan again?"):
                return None
            continue
        by_label: dict[str, dict] = {}
        options: list[str] = []
        for d in candidates:
            labs = ",".join(d.get("labels") or []) or "-"
            display = (
                f"{d['path']:14}  {d['size']:>8}  {d['model'] or '-':16}  "
                f"{d['tran'] or '-':4}  {kind_tag(d)}  {labs}"
            )
            by_label[display] = d
            options.append(display)
        options.append("Rescan")
        options.append("Cancel")
        choice = gum_choose(options, header="Choose a disk to ERASE (confirmed on the next screen)")
        if choice is None or choice == "Cancel":
            return None
        if choice == "Rescan":
            continue
        target = by_label.get(choice)
        if target:
            return target


def confirm_wipe(target: dict, snap: dict) -> bool:
    out()
    gum_style("--bold", "--foreground", "1", "THIS ERASES THE WHOLE DISK PERMANENTLY:")
    gum_style(
        "--foreground",
        "8",
        f"  {target['path']}  {target['size']}  {target['model']}  ({kind_tag(target)})",
    )
    gum_style("--foreground", "8", f"  Restore point: {snap.get('timestamp')}")
    if target["kind"] in {"live-usb", "backup-usb"}:
        out()
        gum_style(
            "--foreground",
            "3",
            "That is this backup/rescue USB — restoring onto it destroys the copy",
        )
        gum_style("--foreground", "3", "you are restoring from.")
    out()
    name = Path(target["path"]).name
    typed = ask(f"Type the disk name to confirm ({name})")
    if typed != name:
        gum_style("--foreground", "1", "Name did not match. Aborting.")
        return False
    yes = ask("Type YES to erase and restore")
    return yes == "YES"


LEVELS = {
    "Everything: the system and all your files": "full",
    "System + settings: faster; your files come back later from Settings → Restore my files": "settings",
}


def pick_level() -> str | None:
    choice = gum_choose(list(LEVELS), header="How much do you want to restore?")
    return LEVELS.get(choice) if choice else None


def run_restore(target: dict, snap: dict, level: str) -> int:
    ts = snap.get("timestamp")
    argv = [
        str(CLI),
        "restore-to-disk",
        target["path"],
        "--snapshot",
        str(ts),
        "--level",
        level,
        "--yes",
        "--allow-internal",
    ] + (["--from-pi"] if NET else [])
    env = os.environ.copy()
    env["OMARCHY_TM_ROOT"] = str(ROOT)
    env["OMARCHY_TM_YES"] = "1"
    env["OMARCHY_TM_ALLOW_INTERNAL"] = "1"
    out()
    gum_style("--bold", "Starting restore. This takes a while.")
    out()
    return subprocess.call(argv, env=env)


def drop_to_shell() -> None:
    out()
    gum_style("--foreground", "8", "Shell. Useful commands:")
    if NET:
        out("  oma-backups restore-tui      (start the network restore again)")
        out("  iwctl                        (Wi-Fi)")
        out()
        return
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
    if not (connect_pi() if NET else unlock_backup()):
        # The unlock may have landed on the Pi even though we gave up on it
        # (a dropped connection answers no). Locking twice is harmless.
        lock_pi()
        drop_to_shell()
        return 1
    try:
        return restore_flow()
    finally:
        lock_pi()


def restore_flow() -> int:
    snaps = load_snapshots()
    snap = pick_snapshot(snaps)
    if not snap:
        drop_to_shell()
        return 1
    level = pick_level()
    if not level:
        drop_to_shell()
        return 1
    target = pick_target()
    if not target:
        drop_to_shell()
        return 1
    out()
    gum_style("--foreground", "8", "Plan (dry-run):")
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
            "--level",
            level,
            "--allow-internal",
        ] + (["--from-pi"] if NET else []),
        env=env,
    )
    if not confirm_wipe(target, snap):
        drop_to_shell()
        return 1
    rc = run_restore(target, snap, level)
    if rc == 0:
        out()
        gum_style("--bold", "--foreground", "2", "● Restore finished.")
        gum_style("--foreground", "8", "  Remove this USB and boot the restored disk.")
        if level == "settings":
            gum_style("--foreground", "8", "  Your documents, photos and other files are still on the backup: once")
            gum_style("--foreground", "8", "  you're in, open OmaBackups → Settings → Restore my files.")
        pause("Press Enter for a shell.")
    else:
        gum_style("--bold", "--foreground", "1", f"Restore failed (exit {rc}).")
        drop_to_shell()
    return rc


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        out("\nAborted.")
        raise SystemExit(130)
