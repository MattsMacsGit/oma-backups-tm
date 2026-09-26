#!/usr/bin/env python3
"""Automatic-backup settings in ~/.config/omarchy-backups/schedule.json.

  schedule.py get [KEY]      print all settings as JSON, or one value
  schedule.py set KEY VALUE  enabled=true|false, every=hourly|daily|weekly,
                             retention=smart|keep, health=true|false,
                             health_at=0..23 (the hour the nightly disk check
                             starts), health_minutes=30|60|120|240|480

The file is user-owned (the plugin writes it) but read by the root timer, so
anything unexpected in it falls back to the defaults.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compile_excludes import user_home  # noqa: E402

DEFAULTS = {"enabled": False, "every": "daily", "retention": "smart", "enabled_at": 0,
            "health": True, "health_at": 0, "health_minutes": 120}
CHOICES = {"every": ("hourly", "daily", "weekly"), "retention": ("smart", "keep")}
INTERVAL = {"hourly": 3600, "daily": 86400, "weekly": 7 * 86400}
NUMBERS = {"health_at": tuple(range(24)), "health_minutes": (30, 60, 120, 240, 480)}


def path() -> Path:
    return user_home() / ".config" / "omarchy-backups" / "schedule.json"


def load() -> dict:
    out = dict(DEFAULTS)
    try:
        data = json.loads(path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    for key in ("enabled", "health"):
        if isinstance(data.get(key), bool):
            out[key] = data[key]
    for key, allowed in NUMBERS.items():
        if data.get(key) in allowed and not isinstance(data.get(key), bool):
            out[key] = data[key]
    for key, allowed in CHOICES.items():
        if data.get(key) in allowed:
            out[key] = data[key]
    if isinstance(data.get("enabled_at"), int) and data["enabled_at"] >= 0:
        out["enabled_at"] = data["enabled_at"]
    out["interval"] = INTERVAL[out["every"]]
    return out


def save(settings: dict) -> None:
    p = path()
    p.parent.mkdir(parents=True, exist_ok=True)
    body = {k: settings[k] for k in DEFAULTS}
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(body, indent=2) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o644)
    if os.geteuid() == 0:
        st = p.parent.stat()
        os.chown(tmp, st.st_uid, st.st_gid)
    tmp.replace(p)


def main() -> int:
    args = sys.argv[1:]
    if args[:1] == ["get"] and len(args) <= 2:
        s = load()
        if len(args) == 2:
            v = s.get(args[1])
            print(str(v).lower() if isinstance(v, bool) else v)
        else:
            print(json.dumps(s))
        return 0
    if args[:1] == ["set"] and len(args) == 3:
        key, value = args[1], args[2]
        s = load()
        if key == "enabled" and value in ("true", "false"):
            s["enabled"] = value == "true"
            if s["enabled"]:
                s["enabled_at"] = int(time.time())
        elif key == "health" and value in ("true", "false"):
            s["health"] = value == "true"
        elif key in NUMBERS and value.isdigit() and int(value) in NUMBERS[key]:
            s[key] = int(value)
        elif key in CHOICES and value in CHOICES[key]:
            s[key] = value
        else:
            print(f"schedule: can't set {key}={value}", file=sys.stderr)
            return 2
        save(s)
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
