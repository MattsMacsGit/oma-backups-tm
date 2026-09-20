#!/usr/bin/env python3
"""Write /run/omarchy-backups.status JSON for the plugin.

Two bars, not one: the step running now, and the whole backup.

  progress.py plan JSON           the steps this run will do, and their sizes
  progress.py measure STEP        rsync --dry-run --stats on stdin: how much
                                  this step has to get through
  progress.py phase STEP          a step with nothing to measure ("busy")
  progress.py set STEP PCT        a step that reports its own percentage
  progress.py stream STEP [FILE]  rsync --info=progress2 on stdin; FILE gets
                                  rsync's "Total file size" when it finishes
  progress.py done | idle | fail MESSAGE

Each of those is a separate process, so the run's shape lives in a plan file
next to the status file. The plan holds one entry per step with the bytes and
files it has to get through (from `measure`, or from the last backup's sizes)
and how far it has got. The overall bar is weighted by those bytes, so a huge
"your files" step doesn't sit at "1 of 4" for hours.

For the step bar rsync gives the larger of files-checked and bytes-copied,
held so it never moves backwards: on an incremental backup bytes-copied barely
moves (almost nothing changed) while files-checked does, and switching between
the two made the bar jump around. The overall bar never moves backwards
either. Never calls du: the only walks of the tree are rsync's own.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path

STATUS = Path(os.environ.get("OMARCHY_TM_STATUS_FILE", "/run/omarchy-backups.status"))
PLAN = Path(re.sub(r"\.status$", "", str(STATUS)) + ".plan")

RSYNC_RE = re.compile(
    r"^\s*(?P<bytes>\d+)\s+(?P<pct>\d+)%(?:\s+(?P<speed>\S+/s))?(?:\s+(?P<eta>\d+:\d+(?::\d+)?))?"
)
TOCHK_RE = re.compile(r"to-chk=(?P<left>\d+)/(?P<total>\d+)")
# Folder-by-folder mode: "ir-chk" while rsync is still finding files (the
# total keeps growing, so no honest percentage yet); "to-chk" once it knows.
# backup.sh asks rsync for the whole list up front, so this is a fallback now.
IRCHK_RE = re.compile(r"ir-chk=(?P<left>\d+)/(?P<total>\d+)")
# "(xfr#1234, to-chk=...)" — how many files rsync has actually sent, as
# against how many it has looked at. That ratio, not the byte count, is what
# says whether a step is copying or just checking: it holds however the file
# sizes fall.
XFR_RE = re.compile(r"xfr#(?P<n>\d+)")
TOTAL_RE = re.compile(r"^Total file size:\s*(?P<n>\d+)")
# rsync --info=flist2 while it lists everything before copying anything
# (minutes for a big home on a resume or a slow Pi): "12300 files...".
FILES_RE = re.compile(r"^\s*(?P<n>\d+) files\.\.\.")
# `rsync --dry-run --stats`, for the measuring pass.
STAT_FILES_RE = re.compile(r"^Number of files:\s*(?P<n>[\d,]+)")
STAT_SIZE_RE = re.compile(r"^Total file size:\s*(?P<n>[\d,]+)")

LABEL = {
    "unlock": "Unlocking the backup disk",
    "prepare": "Getting ready",
    "measure": "Working out how much there is to copy",
    "resume": "Carrying on where it stopped",
    "stopping": "Stopping and locking the backup disk",
    "snapshot": "Taking a snapshot of this computer",
    "os": "Copying system files",
    "home": "Copying your files",
    "esp": "Copying boot files",
    "rescue": "Updating the rescue USB",
    "finalize": "Saving the restore point",
    "tidy": "Tidying up old restore points",
    "setup": "Setting up the backup disk",
    "waiting-input": "Waiting for you — enter the new disk password",
}
# Most of a backup is rsync working out what changed, not sending anything.
# Saying "Copying your files" through all of that is simply wrong, so a step
# says which of the two it is actually doing.
CHECK_LABEL = {
    "os": "Checking system files",
    "home": "Checking your files",
    "esp": "Checking boot files",
}
# Steps with a real percentage; every other step is shown as "working".
BAR_STEPS = {"os", "home", "esp", "setup"}
# What a step with nothing to measure is worth on the overall bar, as a share
# of the copying. Saving the restore point and tidying up are quick next to
# the copying, but they aren't instant, so the bar shouldn't sit at "done"
# while they run.
FIXED_WEIGHT = {
    "prepare": 0.001,
    "measure": 0.004,
    "snapshot": 0.004,
    "finalize": 0.02,
    "rescue": 0.01,
    "tidy": 0.01,
}
WRITE_EVERY = 0.5


def write(data: dict) -> None:
    # "at" lets the plugin tell this attempt's error from a leftover one.
    data = dict(data, at=int(time.time()))
    payload = json.dumps(data) + "\n"
    STATUS.parent.mkdir(parents=True, exist_ok=True)
    # One file, read by the plugin and by `oma-backups status`. There used to
    # be a second copy written into the user's own state folder on every
    # update — twice a second for the length of a backup, with a stat and a
    # chown each time — which nothing anywhere ever read.
    tmp = Path(str(STATUS) + ".tmp")
    tmp.write_text(payload, encoding="utf-8")
    os.chmod(tmp, 0o644)
    tmp.replace(STATUS)


def label(step: str) -> str:
    return LABEL.get(step, step or "Backing up")


def human(n: float) -> str:
    size = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:.0f} {unit}" if unit in ("B", "KB") else f"{size:.1f} {unit}"
        size /= 1024
    return f"{n:.0f} B"


def clock(seconds: float) -> str:
    """Seconds as something readable: "6 min", "2 h 40 min"."""
    s = int(max(0, seconds))
    if s < 60:
        return f"{s} sec"
    if s < 3600:
        return f"{s // 60} min"
    h, m = divmod(s // 60, 60)
    return f"{h} h {m:02d} min" if m else f"{h} h"


# ——— the plan: what this run has to get through, and how far it has got ———


class Plan:
    """The steps of this run, with the bytes and files each has to get through.

    Lives in a file because every progress.py call is its own process. A
    missing or unreadable plan is never an error: the step bar still works and
    the overall bar simply doesn't appear.
    """

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
        if not self.data:
            return
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

    def step(self, name: str) -> dict | None:
        for s in self.steps:
            if s.get("name") == name:
                return s
        return None

    def copy_total(self) -> float:
        """Bytes across the steps that actually copy something."""
        total = 0.0
        for s in self.steps:
            if s.get("name") in BAR_STEPS:
                total += float(s.get("total_bytes") or s.get("weight") or 0)
        return total

    def weight(self, s: dict) -> float:
        """What this step is worth on the overall bar, in bytes."""
        measured = s.get("total_bytes") or 0
        if measured:
            return float(measured)
        guess = s.get("weight") or 0
        if guess:
            return float(guess)
        share = FIXED_WEIGHT.get(s.get("name", ""), 0.005)
        return max(1.0, self.copy_total() * share)

    def begin(self, name: str) -> None:
        for s in self.steps:
            if s.get("name") == name:
                if s.get("state") != "done":
                    s["state"] = "running"
            elif s.get("state") == "running":
                s["state"] = "done"
                s["fraction"] = 1.0

    def advance(self, name: str, fraction: float, copied: int = 0, files_done: int = 0) -> None:
        s = self.step(name)
        if s is None:
            return
        s["state"] = "running"
        s["fraction"] = max(float(s.get("fraction") or 0.0), min(1.0, max(0.0, fraction)))
        if copied:
            s["copied"] = copied
        if files_done:
            s["files_done"] = files_done

    def finish(self, name: str) -> None:
        s = self.step(name)
        if s is not None:
            s["state"] = "done"
            s["fraction"] = 1.0

    def position(self) -> tuple[int, int]:
        """Which copying step is running, and how many there are."""
        copying = [s for s in self.steps if s.get("name") in BAR_STEPS]
        total = len(copying) or len(self.steps)
        at = 0
        for n, s in enumerate(copying, start=1):
            if s.get("state") == "running":
                return n, max(1, total)
            if not at and s.get("state") != "done":
                at = n
        return max(1, at or total), max(1, total)

    def overall(self) -> dict:
        """Where the whole run has got to, weighted by bytes."""
        steps = self.steps
        if not steps:
            return {}
        total = sum(self.weight(s) for s in steps) or 1.0
        done = 0.0
        for s in steps:
            w = self.weight(s)
            if s.get("state") == "done":
                done += w
            elif s.get("state") == "running":
                done += w * float(s.get("fraction") or 0.0)
        frac = min(1.0, max(0.0, done / total))
        # Never backwards: measuring a step can make it worth more than the
        # last backup suggested, and the bar must not drop when it does.
        frac = max(frac, float(self.data.get("floor") or 0.0))
        self.data["floor"] = frac
        at, of = self.position()
        out: dict = {
            "overall_percent": int(frac * 100),
            "overall_step": at,
            "overall_steps": of,
        }
        started = float(self.data.get("started") or 0)
        if started:
            elapsed = max(0.0, time.time() - started)
            out["elapsed"] = clock(elapsed)
            # An estimate is only worth showing once enough has happened to
            # make it mean anything: at 1% of a multi-hour copy it is noise.
            if elapsed > 30 and frac > 0.02:
                out["overall_eta"] = clock(elapsed / frac - elapsed)
                out["overall_total_time"] = clock(elapsed / frac)
        return out


def status(
    step: str,
    pct: int | None = None,
    detail: str = "",
    speed: str = "",
    eta: str = "",
    plan: Plan | None = None,
    extra: dict | None = None,
    label_text: str = "",
) -> dict:
    busy = pct is None
    shown = 0 if busy else max(0, min(100, pct))
    shown_label = label_text or label(step)
    data = {
        "running": True,
        "phase": step,
        "label": shown_label,
        "busy": busy,
        "percent": shown,
        "detail": detail,
        "speed": speed,
        "eta": eta,
        "line": shown_label if busy else f"{shown_label}  {shown}%",
    }
    if extra:
        data.update(extra)
    if plan is not None:
        data.update(plan.overall())
    return data


# ——— measuring: one dry run, so the bars have an honest denominator ———


def measure(step: str) -> int:
    """`rsync --dry-run --stats` on stdin: record what this step must copy.

    Writes the file count as it goes so the panel shows something moving, and
    stores the totals in the plan. Nothing here can fail the backup: if the
    numbers don't arrive, the bars fall back to rsync's own percentage.
    """
    plan = Plan.load()
    plan.begin("measure")
    plan.save()
    files = size = 0
    last = 0.0
    write(status("measure", None, "", plan=plan))
    for raw in sys.stdin:
        line = raw.strip()
        m = STAT_FILES_RE.match(line)
        if m:
            files = int(m.group("n").replace(",", ""))
            continue
        m = STAT_SIZE_RE.match(line)
        if m:
            size = int(m.group("n").replace(",", ""))
            continue
        f = FILES_RE.search(line.replace(",", ""))
        if f:
            now = time.monotonic()
            if now - last >= WRITE_EVERY:
                last = now
                write(status("measure", None, f"{int(f.group('n')):,} files so far", plan=plan))
    s = plan.step(step)
    if s is not None and (size or files):
        if size:
            s["total_bytes"] = size
        if files:
            s["files_total"] = files
        plan.save()
    return 0


class RsyncProgress:
    """Turns rsync --info=progress2 lines into a bar that only moves forward."""

    def __init__(self, step: str, plan: Plan) -> None:
        self.step = step
        self.plan = plan
        self.best = 0
        self.last_write = 0.0
        self.total_size: int | None = None
        entry = plan.step(step) or {}
        self.known_bytes = int(entry.get("total_bytes") or 0)
        self.known_files = int(entry.get("files_total") or 0)
        self.started = time.monotonic()
        self.copied = 0
        self.files_done = 0
        # Once sending data is what's driving the bar, the step keeps saying
        # so. Near the end of a copy the file count can edge past the byte
        # count for a moment, and without this the heading flipped back to
        # "Checking your files" at 87% — after twenty minutes of copying.
        self.copying_latched = False

    def note_mode(self, sent_files: int, seen_files: int) -> None:
        """Decide whether this step is copying or checking, and remember it.

        A first backup sends nearly every file it looks at; every backup
        after that looks at hundreds of thousands and sends a handful. Wait
        for a sample worth judging — on the first line, nothing has happened
        either way — then latch, so the heading can go from checking to
        copying but never flaps back.
        """
        if self.copying_latched or seen_files < 100:
            return
        if sent_files and sent_files / seen_files >= 0.3:
            self.copying_latched = True

    def numbers(self, copied: int, files_done: int, files_total: int) -> dict:
        """The figures under the bar, both ways of reading them.

        A first backup copies nearly every byte it looks at, so "43 GB of
        544 GB" is the useful line. Every backup after that mostly *checks*
        files and copies a handful, and the same line would read as 2 GB of
        544 GB while the bar said 40% — so the checking case leads with the
        file count and says plainly how little had to be copied.
        """
        out: dict = {}
        if copied:
            self.copied = copied
        if files_done:
            self.files_done = files_done
        total_bytes = self.known_bytes or self.total_size or 0
        out["copied_bytes"] = self.copied
        if total_bytes:
            out["total_bytes"] = total_bytes
            out["data_text"] = f"{human(self.copied)} of {human(total_bytes)}"
        elif self.copied:
            out["data_text"] = f"{human(self.copied)} copied"
        out["copied_text"] = f"{human(self.copied)} copied" if self.copied else "nothing to copy so far"
        total_files = files_total or self.known_files or 0
        if total_files:
            out["files_done"] = self.files_done
            out["files_total"] = total_files
            out["files_text"] = f"{self.files_done:,} of {total_files:,} files"
            out["checked_text"] = f"{self.files_done:,} of {total_files:,} files checked"
        elif self.files_done:
            out["files_done"] = self.files_done
            out["files_text"] = f"{self.files_done:,} files"
            out["checked_text"] = f"{self.files_done:,} files checked"
        return out

    def detail(self, nums: dict, left_text: str, copying: bool = True) -> str:
        if copying:
            parts = [nums.get("data_text", ""), nums.get("files_text", "")]
        else:
            parts = [nums.get("checked_text", ""), nums.get("copied_text", "")]
        if left_text:
            parts.append(f"{left_text} left")
        return "  ·  ".join(p for p in parts if p)

    def time_left(self, fraction: float) -> str:
        """What's left, from how fast the bar itself has been moving.

        Whatever is driving the bar has to be what the estimate follows:
        bytes on a first backup, files checked on every one after it. Working
        it out from bytes alone said "1000 h" on a backup that was mostly
        checking files it had no need to copy — a couple of GB moved, divided
        by a transfer rate near zero, against a 544 GB tree.

        rsync's own ETA is no better: it only looks at the file it is on.
        """
        if fraction <= 0.005 or fraction >= 1.0:
            return ""
        ran = time.monotonic() - self.started
        # Early on, the rate says more about the first few folders than about
        # the run, and a wild guess is worse than none.
        if ran < 15:
            return ""
        left = ran / fraction - ran
        # Anything past this is a number nobody can act on; say nothing.
        if left > 48 * 3600:
            return ""
        return clock(left)

    def feed(self, line: str) -> dict | None:
        compact = line.replace(",", "")
        t = TOTAL_RE.search(compact.strip())
        if t:
            self.total_size = int(t.group("n"))
            return None
        f = FILES_RE.search(compact)
        if f:
            n = int(f.group("n"))
            return status(self.step, None, f"Checking for changes: {n:,} files so far",
                          plan=self.plan)
        m = RSYNC_RE.search(compact)
        c = TOCHK_RE.search(compact)
        ir = IRCHK_RE.search(compact)
        copied = int(m.group("bytes")) if m else 0
        speed = (m.group("speed") or "") if m else ""
        if ir and not c:
            # Still finding files, so rsync's own percentage is against a
            # total that is still growing — unless the measuring pass already
            # told us how big this step really is.
            checked = int(ir.group("total")) - int(ir.group("left"))
            nums = self.numbers(copied, checked, 0)
            check_label = CHECK_LABEL.get(self.step, "")
            if self.known_bytes:
                self.best = max(self.best, min(99, int(100 * copied / self.known_bytes)))
                self.plan.advance(self.step, self.best / 100, copied, checked)
                left = self.time_left(self.best / 100)
                return status(self.step, self.best, self.detail(nums, left, False), speed,
                              plan=self.plan, extra=nums, label_text=check_label)
            self.plan.begin(self.step)
            detail = self.detail(nums, "", False)
            return status(self.step, None, detail, speed, plan=self.plan, extra=nums,
                          label_text=check_label)
        if not m and not c:
            return None
        byte_pct = int(m.group("pct")) if m else 0
        file_pct = 0
        files_done = files_total = 0
        if c and int(c.group("total")) > 0:
            left_files, files_total = int(c.group("left")), int(c.group("total"))
            files_done = files_total - left_files
            file_pct = int(100 * files_done / files_total)
        if self.known_bytes and copied:
            byte_pct = max(byte_pct, int(100 * copied / self.known_bytes))
        pct = max(byte_pct, file_pct)
        # rsync reports 100% on its very last line; don't show it early.
        if pct >= 100 and not (c and int(c.group("left")) == 0):
            pct = 99
        self.best = max(self.best, pct)
        nums = self.numbers(copied, files_done, files_total)
        # Which of the two is moving the bar: sending files, or working out
        # which ones need sending. That decides the wording and the label.
        x = XFR_RE.search(compact)
        self.note_mode(int(x.group("n")) if x else 0, files_done)
        copying = self.copying_latched
        eta = m.group("eta") if m and copying and m.group("eta") else ""
        if eta.strip("0:") == "":
            eta = ""
        left_text = self.time_left(self.best / 100)
        self.plan.advance(self.step, self.best / 100, copied, files_done)
        label_text = "" if copying else CHECK_LABEL.get(self.step, "")
        return status(self.step, self.best, self.detail(nums, left_text, copying), speed, eta,
                      plan=self.plan, extra=nums, label_text=label_text)

    def maybe_write(self, data: dict, force: bool = False) -> None:
        now = time.monotonic()
        if force or now - self.last_write >= WRITE_EVERY:
            write(data)
            self.last_write = now


def stream(step: str, stats_file: str | None) -> int:
    plan = Plan.load()
    plan.begin(step)
    prog = RsyncProgress(step, plan)
    write(status(step, None, "Checking for changes", plan=plan))
    # Only a person at a terminal wants rsync's raw output; a service's would
    # just fill the system log.
    echo = sys.stderr.isatty()
    leftover = ""
    last = None
    while True:
        chunk = sys.stdin.buffer.read1(256)
        if not chunk:
            break
        if echo:
            try:
                sys.stderr.buffer.write(chunk)
                sys.stderr.buffer.flush()
            except OSError:
                pass
        leftover += chunk.decode("utf-8", "replace").replace("\r", "\n")
        while "\n" in leftover:
            line, leftover = leftover.split("\n", 1)
            if line.strip():
                data = prog.feed(line)
                if data:
                    last = data
                    prog.maybe_write(data)
    if last:
        prog.maybe_write(last, force=True)
    plan.save()
    if stats_file and prog.total_size is not None:
        Path(stats_file).write_text(f"{prog.total_size}\n", encoding="utf-8")
    return 0


def clear_plan() -> None:
    try:
        PLAN.unlink(missing_ok=True)
    except OSError:
        pass


def main() -> int:
    if len(sys.argv) < 2:
        return 1
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "idle":
        clear_plan()
        write({"running": False, "phase": "idle", "label": "", "busy": False, "percent": 0,
               "detail": "", "speed": "", "eta": "", "line": ""})
    elif cmd == "plan":
        # One JSON argument: {"steps": [{"name": "home", "weight": 123}, ...]}
        try:
            data = json.loads(args[0]) if args else {}
        except ValueError:
            return 1
        steps = []
        for s in data.get("steps", []):
            if isinstance(s, dict) and s.get("name"):
                steps.append({
                    "name": str(s["name"]),
                    "weight": int(s.get("weight") or 0),
                    "total_bytes": int(s.get("total_bytes") or 0),
                    "files_total": int(s.get("files_total") or 0),
                    "state": "done" if s.get("done") else "pending",
                    "fraction": 1.0 if s.get("done") else 0.0,
                })
        Plan({"steps": steps, "started": time.time(), "floor": 0.0}).save()
    elif cmd == "phase":
        step = args[0] if args else ""
        plan = Plan.load()
        plan.begin(step)
        plan.save()
        write(status(step, 0 if step in BAR_STEPS else None, plan=plan))
    elif cmd == "set":
        step = args[0] if args else ""
        pct = int(args[1]) if len(args) > 1 and args[1].isdigit() else 0
        plan = Plan.load()
        if pct >= 100:
            plan.finish(step)
        else:
            plan.advance(step, pct / 100)
        plan.save()
        write(status(step, pct, speed=args[2] if len(args) > 2 else "",
                     eta=args[3] if len(args) > 3 else "", plan=plan))
    elif cmd == "measure":
        return measure(args[0] if args else "home")
    elif cmd == "done":
        clear_plan()
        write({"running": False, "phase": "done", "label": "Done", "busy": False, "percent": 100,
               "detail": "", "speed": "", "eta": "0:00", "line": "Done", "overall_percent": 100})
    elif cmd == "fail":
        clear_plan()
        write({"running": False, "phase": "error", "label": "", "busy": False, "percent": 0,
               "detail": "", "speed": "", "eta": "", "line": " ".join(args) or "Setup failed"})
    elif cmd == "stream":
        return stream(args[0] if args else "rsync", args[1] if len(args) > 1 else None)
    else:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
