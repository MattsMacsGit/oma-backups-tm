#!/usr/bin/env python3
"""Load defaults, /etc/omarchy-backups/config.toml, then SUDO_USER overlay."""

from __future__ import annotations

import json
import os
import pwd
import sys
from pathlib import Path

try:
    import tomllib
except ImportError:
    print("python3 tomllib is required (3.11+)", file=sys.stderr)
    sys.exit(1)

ETC = Path("/etc/omarchy-backups")


def _root() -> Path:
    env = os.environ.get("OMARCHY_TM_ROOT") or os.environ.get("OMARCHY_BACKUPS_ROOT")
    if env:
        return Path(env)
    return Path(__file__).resolve().parent.parent


def _expand(value, home: Path):
    if isinstance(value, str) and value.startswith("~/"):
        return str(home / value[2:])
    if isinstance(value, dict):
        return {k: _expand(v, home) for k, v in value.items()}
    if isinstance(value, list):
        return [_expand(v, home) for v in value]
    return value


def _deep_merge(base: dict, overlay: dict) -> dict:
    out = dict(base)
    for key, val in overlay.items():
        if key in out and isinstance(out[key], dict) and isinstance(val, dict):
            out[key] = _deep_merge(out[key], val)
        else:
            out[key] = val
    return out


def _user_home() -> Path:
    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user and os.geteuid() == 0:
        try:
            return Path(pwd.getpwnam(sudo_user).pw_dir)
        except KeyError:
            pass
    return Path(os.environ.get("HOME", str(Path.home())))


def _read_toml(path: Path) -> dict:
    if not path.is_file():
        return {}
    with path.open("rb") as fh:
        return tomllib.load(fh)


def load() -> dict:
    root = _root()
    defaults_path = root / "share" / "defaults.toml"
    with defaults_path.open("rb") as fh:
        data = tomllib.load(fh)
    etc_cfg = ETC / "config.toml"
    data = _deep_merge(data, _read_toml(etc_cfg))
    home = _user_home()
    user_path = home / ".config" / "omarchy-backups" / "config.toml"
    # legacy path
    legacy = home / ".config" / "omarchy-tm" / "config.toml"
    data = _deep_merge(data, _read_toml(user_path))
    if not user_path.is_file() and legacy.is_file():
        data = _deep_merge(data, _read_toml(legacy))
        data["_legacy_user_config"] = str(legacy)
    data = _expand(data, home)
    data["_root"] = str(root)
    data["_user_home"] = str(home)
    data["_etc_dir"] = str(ETC)
    data["_etc_config"] = str(etc_cfg)
    data["_user_config_path"] = str(user_path)
    user_ex_home = home / ".config" / "omarchy-backups" / "excludes-home.txt"
    user_ex_os = home / ".config" / "omarchy-backups" / "excludes-os.txt"
    # Prefer the just-compiled user copy; /etc is the root-readable mirror.
    if user_ex_home.is_file():
        data["_excludes_home"] = str(user_ex_home)
    elif (ETC / "excludes-home.txt").is_file():
        data["_excludes_home"] = str(ETC / "excludes-home.txt")
    else:
        data["_excludes_home"] = str(root / "share" / "excludes-home.txt")
    if user_ex_os.is_file():
        data["_excludes_os"] = str(user_ex_os)
    elif (ETC / "excludes-os.txt").is_file():
        data["_excludes_os"] = str(ETC / "excludes-os.txt")
    else:
        data["_excludes_os"] = str(root / "share" / "excludes-os.txt")
    data["_config_ok_as_root"] = bool(
        os.geteuid() != 0
        or os.environ.get("SUDO_USER")
        or etc_cfg.is_file()
        or (ETC / "excludes-home.txt").is_file()
    )
    return data


def main() -> int:
    json.dump(load(), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
