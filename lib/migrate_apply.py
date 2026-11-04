#!/usr/bin/env python3
"""Migrate my picks: turn the user's list into a plan, and report on it.

The list (saved by the picker, read back out of a restore point) says what
the user ticked. This works out what that means on this computer:

  - apps to install again (pacman, the AUR through yay, Flatpak, and tools
    from uv/npm/pipx/cargo/mise), and whether each one can still be found
  - settings to copy back, each as one job: which side of the restore point
    it lives on (os/ for the system, home/ for the user's folder), where it
    goes, and which service has to stop while it goes in
  - things that need comparing rather than copying (the user's desktop
    tweaks: old defaults must not land on a new Omarchy release)
  - the folders Restore my files brings back afterwards, and what was left
    behind

  migrate_apply.py plan LIST USER HOME        plan as JSON
  migrate_apply.py report PLAN RESULTS LABEL  readable dry-run report

The engine (backup.sh --migrate-plan) opens the backup, fetches the list,
runs "plan", asks rsync about each job without copying, and hands the
answers to "report". Nothing here changes the system.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from migrate_scan import human  # noqa: E402

# A system folder an app is using while it runs: stop the service, copy,
# start it again. Longest match wins.
SERVICES = {
    "/var/lib/tailscale": "tailscaled",
    "/var/lib/bluetooth": "bluetooth",
    "/var/lib/iwd": "iwd",
    "/etc/NetworkManager": "NetworkManager",
    "/var/lib/fprint": "fprintd",
    "/var/lib/ollama": "ollama",
    "/var/lib/nordvpn": "nordvpnd",
    "/etc/cups": "cups",
    "/var/lib/docker": "docker",
}
# Apps that must be closed while their settings go back (they rewrite them on exit).
CLOSE_FIRST = {
    "~/.config/chromium": "chromium",
    "~/.config/google-chrome": "chrome",
    "~/.config/BraveSoftware": "brave",
    "~/.mozilla/firefox": "firefox",
    "~/.thunderbird": "thunderbird",
    "~/.config/Code": "code",
    "~/.config/Signal": "signal-desktop",
}
PICKS_REL = ".config/omarchy-backups/migrate.json"


def run(cmd: list[str], timeout: int = 60) -> tuple[int, str]:
    if not shutil.which(cmd[0]):
        return 127, ""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


def job_for(path: str, user: str, home: str) -> dict:
    """Where one saved path lives in a restore point, and where it goes."""
    if path == "~" or path.startswith("~/"):
        rel = path[2:]
        return {"tree": "home", "rel": f"{user}/{rel}", "dest": f"{home}/{rel}", "owner": "user", "path": path}
    if path.startswith("/") and ".." not in path.split("/"):
        return {"tree": "os", "rel": path.lstrip("/"), "dest": path, "owner": "root", "path": path}
    raise ValueError(f"not a path this can bring back: {path!r}")


def service_for(dest: str) -> str | None:
    best = ""
    for prefix in SERVICES:
        if (dest == prefix or dest.startswith(prefix + "/")) and len(prefix) > len(best):
            best = prefix
    return SERVICES.get(best)


def check_package(pkg: str, source: str, user: str) -> str:
    """installed / repo / aur / missing, as far as this computer can tell."""
    if run(["pacman", "-Q", pkg])[0] == 0:
        return "installed"
    if run(["pacman", "-Si", pkg])[0] == 0:
        return "repo"
    # Not in the repos: try the AUR whatever the list says, since packages
    # move between the two. yay must never run as root, so ask as the user.
    cmd = ["yay", "-Si", "--aur", pkg]
    if shutil.which("runuser") and user and user != "root" and __import__("os").geteuid() == 0:
        cmd = ["runuser", "-u", user, "--", *cmd]
    rc, out = run(cmd, timeout=30)
    if rc == 0 and re.search(r"^Name\s*:", out, re.M):
        return "aur"
    return "missing"


def check_flatpak(app_id: str) -> str:
    if run(["flatpak", "info", app_id])[0] == 0:
        return "installed"
    if not shutil.which("flatpak"):
        return "no-flatpak"
    rc, _ = run(["flatpak", "remote-info", "flathub", app_id], timeout=30)
    return "flathub" if rc == 0 else "missing"


def plan(lst: dict, user: str, home: str, check: bool = True, done: set[str] | None = None) -> dict:
    done = done or set()
    out = {
        "list_saved_at": lst.get("saved_at"),
        "list_omarchy": lst.get("omarchy_version"),
        "list_user": lst.get("user"),
        "user": user,
        "installs": [],
        "jobs": [],
        "merges": [],
        "files": [],
        "left_behind": [],
        "services": [],
        "close_first": [],
        "warnings": [],
        "already_back": [],
    }
    if lst.get("format") != 1:
        out["warnings"].append("This list was saved by a newer or older oma-migrate; some things may be skipped.")
    if lst.get("user") and lst["user"] != user:
        out["warnings"].append(f"The list was made for {lst['user']}; bringing it back into {user}'s home.")

    services: set[str] = set()
    for i in lst.get("items", []):
        if not i.get("keep"):
            out["left_behind"].append({"name": i["name"], "group": i["group"], "bytes": i.get("bytes")})
            continue
        if i["id"] in done:
            out["already_back"].append(i["name"])
            continue
        if i["group"] == "files":
            out["files"].append({"name": i["name"], "paths": [p["path"] for p in i["paths"]], "bytes": i.get("bytes")})
            continue
        if "merge" in i.get("flags", []):
            out["merges"].append({"name": i["name"], "paths": [p["path"] for p in i["paths"]]})
            continue

        kind = i["kind"]
        if kind == "package":
            state = {p: (check_package(p, i.get("source", "repo"), user) if check else "unchecked") for p in i["packages"]}
            out["installs"].append({"id": i["id"], "name": i["name"], "how": "pacman", "packages": i["packages"], "state": state})
        elif kind == "flatpak":
            app = i["packages"][0]
            out["installs"].append({"id": i["id"], "name": i["name"], "how": "flatpak", "packages": [app],
                                    "state": {app: check_flatpak(app) if check else "unchecked"}})
        elif kind == "tool":
            out["installs"].append({"id": i["id"], "name": i["name"], "how": i.get("source", "tool"), "packages": i["packages"],
                                    "state": {i["packages"][0]: "tool"}, "command": i.get("reinstall", "")})

        for p in i.get("paths", []):
            try:
                j = job_for(p["path"], user, home)
            except ValueError as e:
                out["warnings"].append(str(e))
                continue
            j["id"] = f"{i['id']}#{len(out['jobs'])}"
            j["item"] = i["name"]
            j["saved_bytes"] = None
            svc = service_for(j["dest"]) if j["tree"] == "os" else None
            if svc:
                j["service"] = svc
                services.add(svc)
            app = CLOSE_FIRST.get(p["path"])
            if app:
                j["close_first"] = app
                if app not in out["close_first"]:
                    out["close_first"].append(app)
            out["jobs"].append(j)
    out["services"] = sorted(services)
    return out


# ----------------------------------------------------------------- report

def nice_time(stamp: str | None) -> str:
    import calendar
    import time
    try:
        t = calendar.timegm(time.strptime(stamp or "", "%Y-%m-%dT%H:%M:%SZ"))
        return time.strftime("%A %-d %b %H:%M", time.localtime(t))
    except ValueError:
        return stamp or "?"


def report(pl: dict, results: dict[str, dict], label: str) -> str:
    L: list[str] = []
    w = L.append
    w("Migrate my picks: dry run. Nothing was changed.")
    w("")
    w(f"Restore point:  {label}")
    w(f"Your list:      saved {nice_time(pl.get('list_saved_at'))} on Omarchy {pl.get('list_omarchy') or '?'}")
    for warn in pl["warnings"]:
        w(f"Note:           {warn}")
    w("")

    states = {"installed": "already installed here", "repo": "will install", "aur": "will build from the AUR",
              "flathub": "will install from Flathub", "missing": "NOT FOUND (skipped)", "tool": "",
              "no-flatpak": "needs Flatpak first", "unchecked": ""}
    w(f"== Apps to install ({len(pl['installs'])})")
    missing_apps = 0
    for a in pl["installs"]:
        st = a["state"]
        if a["how"] in ("pacman", "flatpak"):
            worst = "missing" if "missing" in st.values() else ("aur" if "aur" in st.values() else
                    ("repo" if "repo" in st.values() else next(iter(st.values()))))
            missing_apps += worst == "missing"
            pk = " ".join(f"{p}{'?' if s == 'missing' else ''}" for p, s in st.items())
            w(f"  {a['name']:<30} {states.get(worst, worst):<26} [{pk}]")
        else:
            w(f"  {a['name']:<30} {('runs: ' + a['command']) if a.get('command') else a['how']}")
    w("")

    total, missing_jobs = 0, 0
    w(f"== Settings to bring back ({len(pl['jobs'])})")
    by_item: dict[str, list[dict]] = {}
    for j in pl["jobs"]:
        by_item.setdefault(j["item"], []).append(j)
    for name, jobs in by_item.items():
        parts = []
        for j in jobs:
            r = results.get(j["id"], {})
            if r.get("missing"):
                parts.append(f"{j['path']} (not in the restore point)")
                missing_jobs += 1
            elif r.get("error"):
                parts.append(f"{j['path']} (couldn't check: rsync {r.get('rc')})")
            else:
                b = r.get("bytes")
                total += b or 0
                parts.append(f"{j['path']} ({human(b) if b is not None else '?'})")
        extra = ""
        svc = sorted({j["service"] for j in jobs if j.get("service")})
        if svc:
            extra = f"   stops {', '.join(svc)} while copying"
        w(f"  {name}{extra}")
        for p in parts:
            w(f"      {p}")
    w(f"  Total: about {human(total)}")
    if pl["close_first"]:
        w(f"  Close first: {', '.join(pl['close_first'])}")
    w("")

    if pl["merges"]:
        w(f"== To compare, not copy ({len(pl['merges'])})")
        for m in pl["merges"]:
            w(f"  {m['name']}: {', '.join(m['paths'])}")
        w("  On a new Omarchy release only your own changes should come across. Not done automatically yet.")
        w("")

    fb = sum(f["bytes"] or 0 for f in pl["files"])
    w(f"== Restore my files brings back afterwards ({len(pl['files'])} folders, about {human(fb)})")
    w("  " + ", ".join(f["name"] for f in pl["files"]))
    w("")
    if pl.get("already_back"):
        w(f"== Already back from an earlier Migrate my picks ({len(pl['already_back'])}), not copied again")
        w("  " + ", ".join(pl["already_back"]))
        w("")
    lb = pl["left_behind"]
    w(f"== Left behind ({len(lb)}), still in the backup if you change your mind")
    w("  " + ", ".join(x["name"] for x in lb))
    w("")
    unchecked = sum(1 for j in pl["jobs"] if results.get(j["id"], {}).get("error") or j["id"] not in results)
    if missing_apps or missing_jobs or unchecked:
        bits = []
        if missing_apps:
            bits.append(f"{missing_apps} app(s) couldn't be found")
        if missing_jobs:
            bits.append(f"{missing_jobs} setting(s) aren't in the restore point")
        if unchecked:
            bits.append(f"{unchecked} setting(s) couldn't be checked")
        w("Not ready yet: " + "; ".join(bits) + ". Everything else is ready to migrate.")
    else:
        w("Everything on your list was found. Ready to migrate.")
    return "\n".join(L)


def done_items(pl: dict, applied: Path, user: str) -> list[str]:
    """Items that are fully back: their app is installed now (if they are an
    app) and every one of their settings went in."""
    results: dict[str, bool] = {}
    try:
        for line in applied.read_text().splitlines():
            if line.strip():
                r = json.loads(line)
                results[r["job"]] = bool(r.get("ok"))
    except OSError:
        pass
    jobs_of: dict[str, list[str]] = {}
    for j in pl["jobs"]:
        jobs_of.setdefault(j["id"].split("#")[0], []).append(j["id"])
    installed: dict[str, bool] = {}
    for a in pl["installs"]:
        if a["how"] == "pacman":
            installed[a["id"]] = all(run(["pacman", "-Q", p])[0] == 0 for p in a["packages"])
        elif a["how"] == "flatpak":
            installed[a["id"]] = run(["flatpak", "info", a["packages"][0]])[0] == 0
        else:
            installed[a["id"]] = True  # a tool: its installer said so, or a problem was listed
    out = []
    for item in set(jobs_of) | set(installed):
        if not installed.get(item, True):
            continue
        if all(results.get(j, False) for j in jobs_of.get(item, [])):
            out.append(item)
    return sorted(out)


def main() -> int:
    if len(sys.argv) >= 5 and sys.argv[1] == "plan":
        lst = json.loads(Path(sys.argv[2]).read_text())
        check = "--no-check" not in sys.argv
        done: set[str] = set()
        for a in sys.argv[5:]:
            if a.startswith("--done="):
                try:
                    done = set(json.loads(Path(a[7:]).read_text()).get("done", []))
                except (OSError, ValueError):
                    pass
        print(json.dumps(plan(lst, sys.argv[3], sys.argv[4], check=check, done=done), indent=1))
        return 0
    if len(sys.argv) == 5 and sys.argv[1] == "report":
        pl = json.loads(Path(sys.argv[2]).read_text())
        results = {}
        for line in Path(sys.argv[3]).read_text().splitlines():
            if line.strip():
                r = json.loads(line)
                results[r["id"]] = r
        print(report(pl, results, sys.argv[4]))
        return 0
    if len(sys.argv) == 5 and sys.argv[1] == "done":
        print("\n".join(done_items(json.loads(Path(sys.argv[2]).read_text()), Path(sys.argv[3]), sys.argv[4])))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
