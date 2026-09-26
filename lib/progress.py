#!/usr/bin/env python3
"""Progress for the plugin panel and the terminal: one step at a time.

Every update is one event, the same shape wherever it is shown:

  {"step": 4, "of": 9, "label": "Copying your files", "percent": 27,
   "unit": "bytes", "done": 3435973837, "total": 12670153523,
   "detail": "3.2 GB of 11.8 GB"}
  {"step": 1, "of": 9, "label": "Unlocking the backup disk", "spinner": true}

"step" and "of" are left out for something that isn't one of this run's
steps (stopping, setting up a disk). The panel and the terminal draw what the
event says and work nothing out for themselves. Around the event sit the few
fields the panel's own bookkeeping reads: running, phase, at, line, dest.

  progress.py steps ID[=LABEL] ...   this run's steps, in order: the numbering
  progress.py phase ID [LABEL]       a step with nothing to measure: a spinner
  progress.py check TREE             rsync --dry-run on stdin: works out what
                                     the copy will send, and shows the checking
  progress.py total TREE BYTES       a total known another way (the manifest)
  progress.py reused TREE BYTES      the check's total, less what the reuse step
                                     found already on the backup disk
  progress.py copy TREE [STATS]      the real rsync on stdin; STATS gets the
                                     tree's {"bytes", "files"} once it's done
  progress.py set ID PCT             a step that reports its own percentage
  progress.py done | idle | fail MESSAGE

Every figure is rsync's own: nothing is estimated, and nothing calls du.
rsync only prints a progress line when it sends a file, so on its own it says
nothing at all while it compares an unchanged tree. With --info=name2 and
--out-format='%i %l %n' it prints one line per file as it goes, with the size,
which is what both bars count. A check ("TREE-check" in the step list) is a
bar of files compared. The copy's bar weighs the two things a copy spends its
time on: comparing files (as long as the check took) and sending what the
check found (its bytes at the rate they are going). An everyday backup is
nearly all comparing; a few large new files are nearly all sending. Neither
bar ever moves backwards or passes 100.

Each call is its own process, so the run's shape (the step list, and what
each check found) lives in a plan file next to the status file.
"""

from __future__ import annotations

import codecs
import json
import os
import re
import shutil
import stat
import sys
import time
from pathlib import Path

STATUS = Path(os.environ.get("OMARCHY_TM_STATUS_FILE", "/run/omarchy-backups.status"))
PLAN = Path(re.sub(r"\.(status|json)$", "", str(STATUS)) + ".plan")
# Fields a caller wants on every write, e.g. "Restore my files" keeps its own
# state and id in the same file the panel polls.
try:
    EXTRA = json.loads(os.environ.get("OMA_PROGRESS_EXTRA") or "{}")
    if not isinstance(EXTRA, dict):
        EXTRA = {}
except ValueError:
    EXTRA = {}

# "   123,456,789  12%   1.23MB/s    0:01:23 (xfr#5, to-chk=10/200)"
BYTES_RE = re.compile(r"^\s*(?P<bytes>\d+)\s+\d+%")
TOCHK_RE = re.compile(r"to-chk=(?P<left>\d+)/(?P<total>\d+)")
# --info=flist2 while rsync lists the tree, then once it has the whole list.
LISTED_RE = re.compile(r"^\s*(?P<n>\d+) files\.\.\.")
CONSIDER_RE = re.compile(r"^\s*(?P<n>\d+) files to consider")
# --out-format='%i %l %n': ">f+++++++++ 5000000 Videos/a.mkv", ".f          7 b".
# Y is < or > for a file whose contents are sent, "." for one that is already
# right, c for something created, h for a hard link, * for "deleting". The
# name is optional: older callers print '%i %l'.
ITEM_RE = re.compile(r"^(?P<y>[<>ch.])(?P<x>[fdLDS])(?P<flags>.{9}) (?P<size>\d+)(?: (?P<name>.*))?$")
# The same for rsyncs that print the name instead: "Documents/a.txt is uptodate".
UPTODATE_RE = re.compile(r" is uptodate$")
TRANSFERRED_RE = re.compile(r"^Total transferred file size:\s*(?P<n>\d+)")
TOTAL_RE = re.compile(r"^Total file size:\s*(?P<n>\d+)")
FILES_RE = re.compile(r"^Number of files:\s*(?P<n>\d+)")
SENT_FILES_RE = re.compile(r"^Number of regular files transferred:\s*(?P<n>\d+)")
# Anything rsync says went wrong goes on to the log instead of being eaten here.
PROBLEM_RE = re.compile(r"^(rsync|rsync error|IO error|file has vanished|cannot delete|ERROR)[: ]")

LABEL = {
    "unlock": "Unlocking the backup disk",
    "prepare": "Getting ready",
    "stopping": "Stopping and locking the backup disk",
    "os-check": "Checking system files",
    "os": "Copying system files",
    "home-check": "Checking your files",
    "home": "Copying your files",
    "esp-check": "Checking boot files",
    "esp": "Copying boot files",
    "rescue": "Updating the rescue USB",
    "finalize": "Saving the restore point",
    "tidy": "Tidying up old restore points",
    "setup": "Setting up the backup disk",
    "waiting-input": "Waiting for you — enter the new disk password",
}
WRITE_EVERY = 0.5
# Until a copy has sent enough to time, its sending is reckoned at this rate.
ASSUMED_RATE = 20 * 1024 * 1024
# New files at least this big are worth looking for in older restore points.
REUSE_MIN = 64 * 1024
OCTAL_RE = re.compile(rb"\\#([0-7]{3})")


def human(n: float) -> str:
    size = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:.0f} {unit}" if unit in ("B", "KB") else f"{size:.1f} {unit}"
        size /= 1024
    return f"{n:.0f} B"


class Plan:
    """This run's steps, and what each check found. Never an error to lack:
    without one, steps simply aren't numbered."""

    def __init__(self, data: dict | None = None) -> None:
        self.data = data or {}

    @classmethod
    def load(cls) -> "Plan":
        try:
            data = json.loads(PLAN.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return cls(None)
        return cls(data if isinstance(data, dict) else None)

    def save(self) -> None:
        try:
            PLAN.parent.mkdir(parents=True, exist_ok=True)
            tmp = Path(str(PLAN) + ".tmp")
            tmp.write_text(json.dumps(self.data), encoding="utf-8")
            os.chmod(tmp, 0o644)
            tmp.replace(PLAN)
        except OSError:
            pass

    @property
    def steps(self) -> list[dict]:
        steps = self.data.get("steps")
        return steps if isinstance(steps, list) else []

    def has(self, sid: str) -> bool:
        return any(s.get("id") == sid for s in self.steps)

    def label(self, sid: str) -> str:
        for s in self.steps:
            if s.get("id") == sid and s.get("label"):
                return str(s["label"])
        return LABEL.get(sid, sid or "Working")

    def number(self, sid: str) -> dict:
        for n, s in enumerate(self.steps, start=1):
            if s.get("id") == sid:
                return {"step": n, "of": len(self.steps)}
        return {}

    def totals(self, tree: str) -> dict:
        t = (self.data.get("totals") or {}).get(tree)
        return t if isinstance(t, dict) else {}

    def set_totals(self, tree: str, **values: int) -> None:
        self.data.setdefault("totals", {}).setdefault(tree, {}).update(values)


def event(plan: Plan, sid: str, label: str = "", *, percent: int | None = None, unit: str = "",
          done: int | None = None, total: int | None = None, detail: str = "") -> dict:
    e: dict = {"running": True, "phase": sid}
    e.update(plan.number(sid))
    e["label"] = label or plan.label(sid)
    if percent is None:
        e["spinner"] = True
    else:
        e["percent"] = max(0, min(100, int(percent)))
        if unit:
            e["unit"] = unit
        if done is not None:
            e["done"] = int(done)
        if total is not None:
            e["total"] = int(total)
    if detail:
        e["detail"] = detail
    return e


def write(data: dict) -> None:
    # "at" lets the plugin tell this attempt's error from a leftover one.
    data = dict(data, **EXTRA, at=int(time.time()))
    STATUS.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(str(STATUS) + ".tmp")
    tmp.write_text(json.dumps(data) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o644)
    tmp.replace(STATUS)


# ——— the terminal: the same event, drawn as one line ———


def tty_line(e: dict) -> str:
    head = e.get("label", "")
    if e.get("step"):
        head = f"Step {e['step']} of {e['of']} · {head}"
    if e.get("spinner"):
        return f"{head}…" + (f"  {e['detail']}" if e.get("detail") else "")
    pct = e.get("percent", 0)
    width = 20
    filled = width * pct // 100
    bar = "#" * filled + "." * (width - filled)
    tail = f"  {e['detail']}" if e.get("detail") else ""
    return f"{head}  [{bar}] {pct:3d}%{tail}"


class Terminal:
    """Draws events on stderr when a person is watching it; silent otherwise
    (a service's output would only fill the system log)."""

    def __init__(self) -> None:
        self.on = sys.stderr.isatty()
        self.open = False

    def show(self, e: dict, final: bool = False) -> None:
        if not self.on:
            return
        cols = shutil.get_terminal_size((100, 24)).columns
        text = "  " + tty_line(e)
        if len(text) > cols - 1:
            text = text[: cols - 2] + "…"
        # One line per step, rewritten in place. A line left open at the end
        # of a call is picked up by the next: a measuring spinner turns into
        # its copy's bar on the same line.
        try:
            sys.stderr.write("\r\033[K" + text)
            self.open = True
            if final:
                sys.stderr.write("\n")
                self.open = False
            sys.stderr.flush()
        except OSError:
            pass

    def say(self, line: str) -> None:
        """Something rsync reported, passed on without wrecking the bar."""
        try:
            if self.open:
                sys.stderr.write("\n")
                self.open = False
            sys.stderr.write(line + "\n")
            sys.stderr.flush()
        except OSError:
            pass


class Emitter:
    def __init__(self) -> None:
        self.last_write = 0.0
        self.term = Terminal()
        self.last: dict | None = None

    def due(self) -> bool:
        return time.monotonic() - self.last_write >= WRITE_EVERY

    def emit(self, e: dict, force: bool = False, final: bool = False) -> None:
        if force or final or self.due():
            self.last_write = time.monotonic()
            write(e)
            self.term.show(e, final=final)

    def problem(self, line: str) -> None:
        """An rsync error: into OmaBackups' log, and to the person watching."""
        if self.term.on:
            self.term.say(line)
        log = os.environ.get("OMARCHY_TM_LOG")
        if log:
            try:
                with open(log, "a", encoding="utf-8", errors="backslashreplace") as f:
                    f.write(time.strftime("%Y-%m-%dT%H:%M:%SZ ", time.gmtime()) + line + "\n")
                return
            except OSError:
                pass
        if not self.term.on:
            print(line, file=sys.stderr, flush=True)


def lines():
    """rsync's output, a line at a time. progress2 rewrites its line with \\r."""
    # surrogateescape: a file name that isn't UTF-8 still turns back into
    # its own bytes, which the reuse list needs.
    dec = codecs.getincrementaldecoder("utf-8")("surrogateescape")
    leftover = ""
    while True:
        chunk = sys.stdin.buffer.read1(4096)
        if not chunk:
            break
        leftover += dec.decode(chunk).replace("\r", "\n")
        *done, leftover = leftover.split("\n")
        for line in done:
            if line.strip():
                yield line
    if leftover.strip():
        yield leftover


# ——— checking: a dry run of the copy, against the real destination ———


class NewFiles:
    """The new files a check finds, for looking up in older restore points.

    Written as NUL-ended records "SIZE MTIME_NS PATH", only when the caller
    asks (OMA_NEW_FILES, with OMA_NEW_FROM the tree being copied). Each is
    checked against the source itself: rsync's name for a file is escaped,
    and a record the disk can't match exactly is one it can't reuse.
    """

    def __init__(self) -> None:
        out = os.environ.get("OMA_NEW_FILES")
        src = os.environ.get("OMA_NEW_FROM")
        self.f = None
        self.src = os.fsencode(src) if src else b""
        self.files = self.bytes = 0
        if out and src:
            try:
                self.f = open(out, "wb")
            except OSError:
                self.f = None

    def feed(self, m: re.Match) -> None:
        if (self.f is None or m.group("y") != ">" or m.group("x") != "f"
                or m.group("flags") != "+" * 9 or not m.group("name")):
            return
        size = int(m.group("size"))
        if size < REUSE_MIN:
            return
        rel = OCTAL_RE.sub(lambda o: bytes([int(o.group(1), 8)]),
                           m.group("name").encode("utf-8", "surrogateescape"))
        if rel.startswith(b"/") or b"\0" in rel:
            return
        try:
            st = os.lstat(os.path.join(self.src, rel))
        except OSError:
            return
        if not stat.S_ISREG(st.st_mode) or st.st_size != size:
            return
        self.f.write(b"%d %d %s\0" % (size, st.st_mtime_ns, rel))
        self.files += 1
        self.bytes += size

    def close(self) -> None:
        if self.f is not None:
            self.f.close()


def check(tree: str) -> int:
    """`rsync -n` with the copy's own flags: a bar of files compared, and at
    the end what the copy will actually send.

    Without its own "TREE-check" step (a restore onto an empty disk measuring
    what it will copy, or the boot files) this shows as a spinner under the
    copy step instead of a bar of its own.
    """
    plan = Plan.load()
    sid = f"{tree}-check"
    bar = plan.has(sid)
    if not bar:
        sid = tree
    out = Emitter()
    started = time.monotonic()
    new = NewFiles()
    listed = considered = checked = 0
    to_send = files = sent_files = None
    working = "Working out how much there is to copy"
    out.emit(event(plan, sid, detail="" if bar else working), force=True)
    for line in lines():
        compact = line.replace(",", "")
        m = ITEM_RE.match(line)
        if m:
            new.feed(m)
        if m or UPTODATE_RE.search(line):
            checked += 1
        elif (m := LISTED_RE.match(compact)):
            listed = int(m.group("n"))
        elif (m := CONSIDER_RE.match(compact)):
            considered = int(m.group("n"))
        elif (m := TRANSFERRED_RE.match(compact)):
            to_send = int(m.group("n"))
            continue
        elif (m := FILES_RE.match(compact)):
            files = int(m.group("n"))
            continue
        elif (m := SENT_FILES_RE.match(compact)):
            sent_files = int(m.group("n"))
            continue
        elif PROBLEM_RE.match(line):
            out.problem(line)
            continue
        c = TOCHK_RE.search(compact)
        if c and int(c.group("total")):
            considered = considered or int(c.group("total"))
            checked = max(checked, int(c.group("total")) - int(c.group("left")))
        if not out.due():
            continue
        if not bar:
            n = considered or listed
            out.emit(event(plan, sid, detail=f"{working}: {n:,} files" if n else working))
        elif considered:
            n = min(checked, considered)
            # 100 only once rsync has said it finished (its closing figures).
            pct = min(99, 100 * n // considered)
            out.emit(event(plan, sid, percent=pct, unit="files", done=n, total=considered,
                           detail=f"{n:,} of {considered:,} files checked"))
        elif listed:
            out.emit(event(plan, sid, detail=f"{listed:,} files found"))
    new.close()
    if to_send is None:
        # rsync stopped before the end (the caller deals with why). Leave no
        # total behind: a wrong one is worse than none.
        if out.term.open:
            out.term.say("")
        return 0
    # How long comparing every file took: the copy has to do it again.
    plan.set_totals(tree, bytes=to_send, files=files or 0, changed=sent_files or 0,
                    seconds=max(1, int(time.monotonic() - started)))
    plan.save()
    if bar:
        n = considered or files or checked
        out.emit(event(plan, sid, percent=100, unit="files", done=n, total=n,
                       detail=f"{n:,} files checked · {human(to_send)} to copy"), final=True)
    return 0


def set_total(tree: str, size: str, files: str = "0") -> int:
    try:
        b, f = int(size), int(files or 0)
    except ValueError:
        return 0
    plan = Plan.load()
    plan.set_totals(tree, bytes=b, files=f)
    plan.save()
    return 0


def reused(tree: str, size: str) -> int:
    try:
        b = int(size)
    except ValueError:
        return 0
    plan = Plan.load()
    t = plan.totals(tree)
    if isinstance(t.get("bytes"), int):
        plan.set_totals(tree, bytes=max(0, t["bytes"] - b))
        plan.save()
    return 0


# ——— copying ———


class Copy:
    """How far through its two jobs the copy is, each weighed by how long it
    takes: comparing every file (as long as the check took), and sending
    what the check found (at the rate bytes are actually going).

    Taking whichever of the two was further, as this used to, put a copy of
    a few huge films at 91% with 10 GB of 603 GB sent: the small files had
    all been compared, and the bar then sat there for hours.

    "Through the comparing" is counted against every file in the list, not
    just the unchanged ones. A resumed backup meets everything it already
    copied first; against the unchanged files alone that would put the bar
    at nearly 100% before a byte of the rest had moved.
    """

    def __init__(self, plan: Plan, tree: str) -> None:
        self.plan = plan
        self.tree = tree
        t = plan.totals(tree)
        self.total: int | None = t.get("bytes") if isinstance(t.get("bytes"), int) else None
        self.check_seconds = t.get("seconds") if isinstance(t.get("seconds"), int) else 0
        self.first_byte: float | None = None
        self.considered = 0
        self.passed = 0        # files that needed nothing sent
        self.sent = 0          # sizes of files sent in full so far
        self.moving = 0        # rsync's own running byte count, mid-file included
        self.best = 0
        self.done_bytes = 0
        self.tree_bytes: int | None = None
        self.tree_files: int | None = None
        self.transferred: int | None = None

    def feed(self, line: str) -> bool:
        compact = line.replace(",", "")
        m = ITEM_RE.match(line)
        if m:
            if m.group("y") in "<>" and m.group("x") == "f":
                self.sent += int(m.group("size"))
            elif m.group("y") in ".h":
                self.passed += 1
            return True
        if UPTODATE_RE.search(line):
            self.passed += 1
            return True
        if (m := CONSIDER_RE.match(compact)):
            self.considered = int(m.group("n"))
            return True
        if (m := TOTAL_RE.match(compact)):
            self.tree_bytes = int(m.group("n"))
            return False
        if (m := FILES_RE.match(compact)):
            self.tree_files = int(m.group("n"))
            return False
        if (m := TRANSFERRED_RE.match(compact)):
            self.transferred = int(m.group("n"))
            return False
        b = BYTES_RE.match(compact)
        if b:
            # The same measure as "Total transferred file size": sizes of the
            # files sent so far, plus how far into the one it's on.
            self.moving = int(b.group("bytes"))
            if self.moving and self.first_byte is None:
                self.first_byte = time.monotonic()
            c = TOCHK_RE.search(compact)
            if c and not self.considered:
                self.considered = int(c.group("total"))
            return True
        return False

    def rate(self) -> float:
        """Bytes a second, once enough has gone to tell."""
        if self.first_byte is not None:
            took = time.monotonic() - self.first_byte
            if took >= 5 and self.done_bytes >= 32 * 1024 * 1024:
                return self.done_bytes / took
        return ASSUMED_RATE

    def fraction(self) -> float:
        sending = comparing = None
        if self.total is not None:
            sending = self.done_bytes / self.total if self.total else 1.0
        if self.considered:
            comparing = min(self.passed, self.considered) / self.considered
        if sending is None or comparing is None:
            return sending if sending is not None else (comparing or 0.0)
        send_time = (self.total or 0) / self.rate()
        compare_time = self.check_seconds
        if send_time + compare_time <= 0:
            return max(sending, comparing)
        return (sending * send_time + comparing * compare_time) / (send_time + compare_time)

    def figures(self, finished: bool) -> dict:
        done = max(self.sent, self.moving)
        if finished and self.transferred is not None:
            done = self.transferred
        if self.total is not None:
            done = min(done, self.total)
        self.done_bytes = max(self.done_bytes, done)
        pct = int(100 * self.fraction())
        pct = 100 if finished else min(99, pct)
        self.best = max(self.best, pct)
        if self.total is None:
            detail = f"{human(self.done_bytes)} copied"
            total = None
        elif self.total == 0:
            detail = "Nothing new to copy"
            total = 0
        else:
            detail = f"{human(self.done_bytes)} of {human(self.total)}"
            total = self.total
        return event(self.plan, self.tree, percent=self.best, unit="bytes",
                     done=self.done_bytes, total=total, detail=detail)


def copy(tree: str, stats_file: str | None) -> int:
    plan = Plan.load()
    prog = Copy(plan, tree)
    out = Emitter()
    out.emit(prog.figures(False), force=True)
    for line in lines():
        if prog.feed(line):
            if out.due():
                out.emit(prog.figures(False))
        elif PROBLEM_RE.match(line):
            out.problem(line)
    finished = prog.tree_bytes is not None
    out.emit(prog.figures(finished), final=True)
    if stats_file and finished:
        Path(stats_file).write_text(
            json.dumps({"bytes": prog.tree_bytes, "files": prog.tree_files or 0}) + "\n",
            encoding="utf-8")
    return 0


# ——— the rest ———


def clear_plan() -> None:
    try:
        PLAN.unlink(missing_ok=True)
    except OSError:
        pass


def main() -> int:
    if len(sys.argv) < 2:
        return 1
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "steps":
        steps = []
        for a in args:
            sid, _, text = a.partition("=")
            if sid:
                steps.append({"id": sid, "label": text} if text else {"id": sid})
        Plan({"steps": steps, "started": int(time.time())}).save()
    elif cmd == "phase":
        sid = args[0] if args else ""
        plan = Plan.load()
        e = event(plan, sid, args[1] if len(args) > 1 else "")
        write(e)
        Terminal().show(e, final=True)
    elif cmd == "set":
        sid = args[0] if args else ""
        pct = int(args[1]) if len(args) > 1 and args[1].isdigit() else 0
        write(event(Plan.load(), sid, percent=pct, unit="percent", done=pct, total=100))
    elif cmd == "check":
        return check(args[0] if args else "home")
    elif cmd == "total":
        return set_total(*(args + ["", "", ""])[:3])
    elif cmd == "reused":
        return reused(*(args + ["", ""])[:2])
    elif cmd == "copy":
        return copy(args[0] if args else "home", args[1] if len(args) > 1 else None)
    elif cmd == "idle":
        clear_plan()
        write({"running": False, "phase": "idle", "label": "", "line": ""})
    elif cmd == "done":
        clear_plan()
        write({"running": False, "phase": "done", "label": "Done", "percent": 100, "line": "Done"})
    elif cmd == "fail":
        clear_plan()
        # Which disk it failed on (backup.sh's dest_id): "unplugged partway
        # through, press Resume" is about that disk, and stops being true the
        # moment the next backup would go somewhere else.
        write({"running": False, "phase": "error", "label": "", "line": " ".join(args) or "Setup failed",
               "dest": os.environ.get("OMA_DEST_ID") or None})
    else:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
