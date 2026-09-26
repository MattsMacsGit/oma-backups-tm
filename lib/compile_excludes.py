#!/usr/bin/env python3
"""Turn absolute skip paths + shipped defaults into rsync exclude files.

Source of truth for *user* skips: ~/.config/omarchy-backups/skip-paths.txt
(via SUDO_USER when running as root). Defaults from share/excludes-*.txt
are always merged in. Writes ~/.config and, as root, /etc.
Never writes /tmp (sticky bit + fs.protected_regular).
"""

from __future__ import annotations

import os
import pwd
import re
import sys
from pathlib import Path

# The fixed set of standard XDG user-dir keys (freedesktop.org spec) —
# NOT every "XDG_*_DIR" key that might appear in user-dirs.dirs. Tools
# like xdg-user-dirs-update let people add their own custom entries
# alongside the real ones; only these count as "a default folder every
# fresh install has", never a custom addition. Includes XDG_PROJECTS_DIR:
# added as an official 9th standard directory in xdg-user-dirs 0.20
# (freedesktop.org, April 2026) — not a custom addition on current
# systems even though it looks like one against older references.
XDG_DIR_KEYS = {
    "XDG_DESKTOP_DIR": "Desktop",
    "XDG_DOWNLOAD_DIR": "Downloads",
    "XDG_TEMPLATES_DIR": "Templates",
    "XDG_PUBLICSHARE_DIR": "Public",
    "XDG_DOCUMENTS_DIR": "Documents",
    "XDG_MUSIC_DIR": "Music",
    "XDG_PICTURES_DIR": "Pictures",
    "XDG_VIDEOS_DIR": "Videos",
    "XDG_PROJECTS_DIR": "Projects",
}


def default_xdg_names(home: Path) -> set[str]:
    """Names of the standard XDG folders (Videos, Pictures, ...) that
    should exist empty on a restore even if skipped. Always includes the
    standard English defaults (what a fresh Omarchy/most Linux installs
    have) as a floor, plus any renamed/localized equivalent found in
    ~/.config/user-dirs.dirs (non-English systems). A user currently
    pointing one at "$HOME/" itself (merged/disabled) doesn't remove it
    from this set — that's about GLib bookmarks, not about whether the
    folder is still one of the standard categories. Never trusts a
    custom XDG_*_DIR key that isn't one of the fixed set above — people
    can and do add their own beyond even the real standard ones."""
    names = set(XDG_DIR_KEYS.values())
    conf = home / ".config" / "user-dirs.dirs"
    if not conf.is_file():
        return names
    try:
        text = conf.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return names
    for key, default_name in XDG_DIR_KEYS.items():
        m = re.search(rf'^{key}="([^"]*)"', text, re.MULTILINE)
        if not m:
            continue
        val = m.group(1).replace("$HOME", str(home))
        try:
            rel = Path(val).resolve().relative_to(home.resolve())
        except (OSError, ValueError):
            continue
        if len(rel.parts) == 1 and rel.parts[0] != default_name:
            names.add(rel.parts[0])
    return names


def repo_root() -> Path:
    env = os.environ.get("OMARCHY_TM_ROOT") or os.environ.get("OMARCHY_BACKUPS_ROOT")
    if env:
        return Path(env)
    return Path(__file__).resolve().parent.parent


def user_home() -> Path:
    sudo = os.environ.get("SUDO_USER")
    if sudo and os.geteuid() == 0:
        try:
            return Path(pwd.getpwnam(sudo).pw_dir)
        except KeyError:
            pass
    return Path(os.environ.get("HOME", str(Path.home())))


def load_paths(src: Path) -> list[str]:
    if not src.is_file():
        return []
    try:
        text = src.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        out.append(line)
    return out


def uniq(xs: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for x in xs:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


def split_paths(
    paths: list[str], home_root: Path, xdg_names: set[str] | None = None
) -> tuple[list[str], list[str]]:
    if xdg_names is None:
        xdg_names = default_xdg_names(user_home())
    home_ex: list[str] = []
    os_ex: list[str] = []
    home_root = home_root.resolve()
    for raw in paths:
        # Not a path at all but an rsync pattern (the recommended quick-skips
        # like ".cache") — pass through; resolving it would anchor it to cwd.
        if not raw.startswith(("/", "~")):
            home_ex.append(raw)
            continue
        p = Path(raw).expanduser()
        try:
            resolved = p.resolve()
        except OSError:
            resolved = p
        s = str(resolved)
        try:
            rel_home = resolved.relative_to(home_root)
            rel = str(rel_home).strip("/")
            if rel and rel != ".":
                parts = rel.split("/")
                # "<user>/<DefaultDirName>" exactly — a top-level default
                # XDG folder (Videos, Pictures, ...), not a nested path
                # inside one and not some other user-created top-level
                # folder that happens to share a home. Only those get an
                # empty placeholder restored; anything else the user
                # skipped is skipped entirely, as expected.
                if len(parts) == 2 and parts[1] in xdg_names:
                    # Exclude contents only, not the directory entry
                    # itself — rsync's manpage: a trailing "***" means
                    # "the directory and everything inside," so it (and
                    # a bare/trailing-slash entry) would exclude the
                    # entry itself too. Keeps the folder present but
                    # empty, the way a fresh Linux home has it.
                    home_ex.append(rel + "/**")
                else:
                    home_ex.append(rel)
                    home_ex.append(rel + "/")
                    home_ex.append(rel + "/***")
            continue
        except ValueError:
            pass
        if s.startswith("/"):
            # Anchored, like share/excludes-os.txt: "/opt/big" means that
            # one folder, not every ".../opt/big" under it.
            os_ex.append("/" + s.lstrip("/"))
        else:
            home_ex.append(s)
    return uniq(home_ex), uniq(os_ex)


def write_exclude_file(path: Path, lines: list[str], header: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    body = header + "\n".join(lines) + ("\n" if lines else "# (nothing skipped)\n")
    try:
        path.unlink(missing_ok=True)
    except OSError:
        pass
    path.write_text(body, encoding="utf-8")
    try:
        os.chmod(path, 0o644)
    except OSError:
        pass


def compile_from(skip_file: Path | None = None, dest: str | None = None) -> tuple[list[str], list[str], Path]:
    home = user_home()
    if skip_file is None:
        from skip_defaults import for_disk

        skip_file = for_disk(home, dest)
    root = repo_root()
    defaults_home = load_paths(root / "share" / "excludes-home.txt")
    defaults_os = load_paths(root / "share" / "excludes-os.txt")
    paths = load_paths(skip_file)
    user_home_ex, user_os_ex = split_paths(paths, Path("/home"), default_xdg_names(home))
    home_ex = uniq(defaults_home + user_home_ex)
    os_ex = uniq(defaults_os + user_os_ex)

    # "skip list:" names the list these came from: lib/doctor.py reads it.
    header_h = f"# compiled from share/excludes-home.txt + skip-paths (relative to /home)\n# skip list: {skip_file}\n"
    header_o = f"# compiled from share/excludes-os.txt + skip-paths (relative to /)\n# skip list: {skip_file}\n"
    user_dir = home / ".config" / "omarchy-backups"
    write_exclude_file(user_dir / "excludes-home.txt", home_ex, header_h)
    write_exclude_file(user_dir / "excludes-os.txt", os_ex, header_o)
    if os.geteuid() == 0:
        etc = Path("/etc/omarchy-backups")
        etc.mkdir(parents=True, exist_ok=True)
        write_exclude_file(etc / "excludes-home.txt", home_ex, header_h)
        write_exclude_file(etc / "excludes-os.txt", os_ex, header_o)
        try:
            os.chmod(etc, 0o755)
        except OSError:
            pass
    return home_ex, os_ex, skip_file


def main() -> int:
    args = sys.argv[1:]
    dest = None
    if args[:1] == ["--dest"]:
        dest, args = (args[1] if len(args) > 1 else ""), args[2:]
    skip = Path(args[0]) if args else None
    if os.geteuid() == 0 and not os.environ.get("SUDO_USER") and skip is None:
        print(
            "compile-excludes: running as root with no SUDO_USER — "
            "will still merge share defaults and /root skip list if any",
            file=sys.stderr,
        )
    home_ex, os_ex, skip_file = compile_from(skip, dest)
    print(f"skip-paths: {skip_file}")
    print(f"home: {len(home_ex)}  os: {len(os_ex)}")
    for x in home_ex:
        print(f"  home/{x}")
    for x in os_ex:
        print(f"  os/{x}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
