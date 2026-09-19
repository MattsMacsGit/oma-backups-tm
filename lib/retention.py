#!/usr/bin/env python3
"""Which restore points to keep (Time Machine-style thinning).

  retention.py plan --mode smart|keep [--now TS]   timestamps on stdin, one per line

Prints JSON: {"keep": [...], "thin": [...], "space_order": [...]}.
  thin         deleted by smart thinning right away
  space_order  what may go next if the disk is still nearly full, oldest
               first; the caller deletes one at a time, re-checking real free
               space after each (btrfs frees space asynchronously, and sizes
               recorded at backup time can't predict what a delete frees)
The newest restore point is never in either list.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timedelta, timezone

STAMP = re.compile(r"^\d{8}T\d{6}Z$")
KEEP_ALL_FOR = timedelta(hours=24)
DAILY_FOR = timedelta(days=30)


def parse(ts: str) -> datetime:
    return datetime.strptime(ts, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)


def thin(stamps: list[str], now: datetime, tz=None) -> tuple[list[str], list[str]]:
    """Keep everything from the last 24 h, the newest per local day for 30
    days, then the newest per ISO week. Returns (keep, delete), newest first."""
    ordered = sorted({s for s in stamps if STAMP.match(s)}, reverse=True)
    keep: list[str] = []
    delete: list[str] = []
    seen: set[tuple] = set()
    for i, ts in enumerate(ordered):
        when = parse(ts)
        age = now - when
        local = when.astimezone(tz)
        if i == 0 or age <= KEEP_ALL_FOR:
            keep.append(ts)
            continue
        bucket = ("day", local.date()) if age <= DAILY_FOR else ("week",) + tuple(local.isocalendar()[:2])
        if bucket in seen:
            delete.append(ts)
        else:
            seen.add(bucket)
            keep.append(ts)
    return keep, delete


def plan(stamps: list[str], mode: str, now: datetime, tz=None) -> dict:
    ordered = sorted({s for s in stamps if STAMP.match(s)}, reverse=True)
    if mode == "smart":
        keep, thinned = thin(ordered, now, tz)
    else:
        keep, thinned = ordered, []
    return {
        "keep": keep,
        "thin": thinned,
        "space_order": list(reversed(keep[1:])) if mode == "smart" else [],
    }


def main() -> int:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    pl = sub.add_parser("plan")
    pl.add_argument("--mode", choices=["smart", "keep"], required=True)
    pl.add_argument("--now", help="UTC timestamp like 20260919T120000Z (tests)")
    args = p.parse_args()
    now = parse(args.now) if args.now else datetime.now(timezone.utc)
    stamps = [line.strip() for line in sys.stdin if line.strip()]
    json.dump(plan(stamps, args.mode, now), sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
