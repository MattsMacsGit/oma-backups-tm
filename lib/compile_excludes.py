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
import sys
from pathlib import Path


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


def split_paths(paths: list[str], home_root: Path) -> tuple[list[str], list[str]]:
    home_ex: list[str] = []
    os_ex: list[str] = []
    home_root = home_root.resolve()
    for raw in paths:
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
                # Exclude contents only (not "rel"/"rel/", and not the
                # "rel/***" shorthand — rsync's manpage: that's equivalent
                # to "rel/" + "rel/**" combined, i.e. it excludes the
                # directory entry itself too). A skipped XDG folder like
                # Videos should still exist empty on the destination, the
                # way a fresh Linux home has it — file choosers and other
                # apps expect these well-known dirs to be present.
                home_ex.append(rel + "/**")
            continue
        except ValueError:
            pass
        if s.startswith("/"):
            os_ex.append(s.lstrip("/"))
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


def compile_from(skip_file: Path | None = None) -> tuple[list[str], list[str], Path]:
    home = user_home()
    if skip_file is None:
        skip_file = home / ".config" / "omarchy-backups" / "skip-paths.txt"
    root = repo_root()
    defaults_home = load_paths(root / "share" / "excludes-home.txt")
    defaults_os = load_paths(root / "share" / "excludes-os.txt")
    paths = load_paths(skip_file)
    user_home_ex, user_os_ex = split_paths(paths, Path("/home"))
    home_ex = uniq(defaults_home + user_home_ex)
    os_ex = uniq(defaults_os + user_os_ex)

    header_h = "# compiled from share/excludes-home.txt + skip-paths (relative to /home)\n"
    header_o = "# compiled from share/excludes-os.txt + skip-paths (relative to /)\n"
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
    skip = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    if os.geteuid() == 0 and not os.environ.get("SUDO_USER") and skip is None:
        print(
            "compile-excludes: running as root with no SUDO_USER — "
            "will still merge share defaults and /root skip list if any",
            file=sys.stderr,
        )
    home_ex, os_ex, skip_file = compile_from(skip)
    print(f"skip-paths: {skip_file}")
    print(f"home: {len(home_ex)}  os: {len(os_ex)}")
    for x in home_ex:
        print(f"  home/{x}")
    for x in os_ex:
        print(f"  os/{x}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
