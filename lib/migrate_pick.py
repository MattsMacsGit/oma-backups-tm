#!/usr/bin/env python3
"""oma-migrate picker: choose what comes back after a fresh install.

A full-screen list in the terminal, grouped like the scan (settings, apps,
files, extras). Everything suggested "keep" starts ticked. Arrow keys or the
mouse move the highlight, Space ticks or unticks, Enter saves. When the
whole list doesn't fit on one screen it is split into pages, one per group,
and saving waits until every page has been looked at to the bottom.

Picks are saved to ~/.config/omarchy-backups/migrate.json, inside the home
folder, so every backup carries them. Running the picker again opens that
saved config rather than scanning, so after a fresh install it is still the
old system's config and anything left behind can be picked later. "Scan
again" (n) replaces it with a fresh scan of this computer, after a warning,
and only once the new scan is saved. The saved config records which install it came
from (a hash of /etc/machine-id), so the picker can say when it's showing an
old system's config.

  migrate_pick.py           pick
  migrate_pick.py --show    print the saved picks
"""

from __future__ import annotations

import argparse
import curses
import json
import locale
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import migrate_scan as ms  # noqa: E402

PICKS_FILE = ms.HOME / ".config" / "omarchy-backups" / "migrate.json"
# Written by Migrate my saved config: which items it has brought back, and from
# which restore point.
MIGRATED_FILE = ms.HOME / ".local" / "state" / "omarchy-backups" / "migrated.json"

UTF8 = "utf" in (locale.getpreferredencoding(False) or "").lower()
BOX_ON = "[✔]" if UTF8 else "[x]"
BOX_OFF = "[ ]"
ARROW = "▸" if UTF8 else ">"
DOT = "·" if UTF8 else "-"
TICK = "✔" if UTF8 else "ok"
TODO = "●" if UTF8 else "*"
MORE_DOWN = "▼" if UTF8 else "v"
MORE_UP = "▲" if UTF8 else "^"

SUGG_TEXT = {"keep": "Keep", "leave": "Leave", "you": "Up to you"}

# Colour pair numbers. Plain ANSI colours, so they follow the Omarchy theme.
C_GREEN, C_RED, C_YELLOW, C_ACCENT, C_MUTED = 1, 2, 3, 4, 5
SUGG_COLOR = {"keep": C_GREEN, "leave": C_RED, "you": C_YELLOW}


# ------------------------------------------------------------------ model

class Model:
    def __init__(self, scan: dict, previous: dict | None):
        self.scan = scan
        self.items = scan["items"]
        picks = (previous or {}).get("picks", {})
        self.loaded_from = (previous or {}).get("saved_at")
        for i in self.items:
            i["keep"] = bool(picks[i["id"]]) if i["id"] in picks else i["suggest"] == "keep"
        self.groups = [g for g in scan["groups"] if any(i["group"] == g["id"] for i in self.items)]
        self.by_group = {g["id"]: [i for i in self.items if i["group"] == g["id"]] for g in self.groups}
        self.seen: set[str] = set()
        self.dirty = False
        sid = scan.get("install_id", "")
        self.from_other_install = bool(sid) and sid != ms.install_id()
        # On the new system, what Migrate my saved config already brought back.
        self.back: set[str] = set()
        if self.from_other_install:
            try:
                self.back = set(json.loads(MIGRATED_FILE.read_text()).get("done", []))
            except (OSError, ValueError):
                pass

    def kept(self) -> list[dict]:
        return [i for i in self.items if i["keep"]]

    def kept_bytes(self) -> tuple[int, bool]:
        total, unknown = 0, False
        for i in self.kept():
            if i["bytes"] is None and i["paths"]:
                unknown = True
            total += i["bytes"] or 0
        return total, unknown

    def unseen(self) -> list[dict]:
        return [g for g in self.groups if g["id"] not in self.seen]

    def toggle(self, item: dict) -> None:
        item["keep"] = not item["keep"]
        self.dirty = True

    def reset(self, items: list[dict]) -> None:
        for i in items:
            want = i["suggest"] == "keep"
            if i["keep"] != want:
                i["keep"] = want
                self.dirty = True

    def to_file(self) -> dict:
        return {
            "format": 1,
            "tool": "oma-migrate",
            "saved_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "scanned_at": self.scan["scanned_at"],
            "omarchy_version": self.scan["omarchy_version"],
            "user": self.scan["user"],
            "install_id": self.scan.get("install_id", ""),
            "picks": {i["id"]: i["keep"] for i in self.items},
            "groups": self.groups,
            "items": self.items,
            "notes": self.scan.get("notes", {}),
        }


def load_previous() -> dict | None:
    try:
        return json.loads(PICKS_FILE.read_text())
    except (OSError, ValueError):
        return None


def save(model: Model) -> Path:
    PICKS_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = PICKS_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(model.to_file(), indent=1) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, PICKS_FILE)
    return PICKS_FILE


def size_text(i: dict) -> str:
    if not i["paths"]:
        return ""
    if i["bytes"] is None:
        return "system" if i["needs_admin"] else "?"
    return ms.human(i["bytes"])


# --------------------------------------------------------------------- UI

class Picker:
    TOP = 4      # title, blank, tabs, rule
    BOTTOM = 5   # detail x2, rule, totals, keys

    def __init__(self, scr, model: Model):
        self.scr = scr
        self.m = model
        self.page = 0
        self.cursor: dict[int, int] = {}
        self.offset: dict[int, int] = {}
        self.message = ("", 0)
        self.tab_spans: list[tuple[int, int, int]] = []
        self.button_spans: dict[str, tuple[int, int, int]] = {}
        self.pages: list[list[dict]] = []
        self.modal: str | None = None

    # ---- layout

    def size(self) -> tuple[int, int]:
        return self.scr.getmaxyx()

    def list_height(self) -> int:
        h, _ = self.size()
        return max(1, h - self.TOP - self.BOTTOM)

    def layout(self) -> None:
        """One page if everything fits, otherwise one page per group."""
        total = sum(len(v) for v in self.m.by_group.values()) + len(self.m.groups) * 2
        old = [g["id"] for g in self.pages[self.page]] if self.pages else None
        if total <= self.list_height():
            self.pages = [self.m.groups]
        else:
            self.pages = [[g] for g in self.m.groups]
        if old:
            for n, p in enumerate(self.pages):
                if p[0]["id"] in old or old[0] in [g["id"] for g in p]:
                    self.page = n
                    break
        self.page = min(self.page, len(self.pages) - 1)

    def lines(self, page: int) -> list[tuple[str, object]]:
        groups = self.pages[page]
        out: list[tuple[str, object]] = []
        for n, g in enumerate(groups):
            if len(groups) > 1:
                if n:
                    out.append(("gap", None))
                out.append(("head", g))
            for i in self.m.by_group[g["id"]]:
                out.append(("item", i))
        return out

    def item_rows(self, page: int) -> list[int]:
        return [n for n, (k, _) in enumerate(self.lines(page)) if k == "item"]

    def current(self) -> dict | None:
        rows = self.item_rows(self.page)
        if not rows:
            return None
        c = self.cursor.get(self.page, rows[0])
        if c not in rows:
            c = rows[0]
        self.cursor[self.page] = c
        return self.lines(self.page)[c][1]  # type: ignore[return-value]

    def move(self, delta: int) -> None:
        rows = self.item_rows(self.page)
        if not rows:
            return
        c = self.cursor.get(self.page, rows[0])
        idx = rows.index(c) if c in rows else 0
        idx = max(0, min(len(rows) - 1, idx + delta))
        self.cursor[self.page] = rows[idx]
        self.scroll_to_cursor()

    def scroll_to_cursor(self) -> None:
        lh = self.list_height()
        c = self.cursor.get(self.page, 0)
        off = self.offset.get(self.page, 0)
        if c < off:
            off = c
            # keep a group heading in view above the first row
            if off > 0 and self.lines(self.page)[off - 1][0] == "head":
                off -= 1
        elif c >= off + lh:
            off = c - lh + 1
        total = len(self.lines(self.page))
        self.offset[self.page] = max(0, min(off, max(0, total - lh)))

    def go_page(self, n: int) -> None:
        self.page = max(0, min(len(self.pages) - 1, n))
        self.scroll_to_cursor()

    def mark_seen(self) -> None:
        """A group counts as looked at once its last row has been on screen."""
        lines = self.lines(self.page)
        off = self.offset.get(self.page, 0)
        bottom = off + self.list_height()
        for n, (k, v) in enumerate(lines):
            if k == "item":
                g = v["group"]  # type: ignore[index]
                last = max(i for i, (kk, vv) in enumerate(lines) if kk == "item" and vv["group"] == g)  # type: ignore[index]
                if last < bottom:
                    self.m.seen.add(g)

    def flash(self, text: str, color: int = C_YELLOW) -> None:
        self.message = (text, color)

    # ---- drawing

    def put(self, y: int, x: int, text: str, attr: int = 0) -> int:
        h, w = self.size()
        if y < 0 or y >= h or x >= w:
            return x
        n = max(0, w - x - (1 if y == h - 1 else 0))
        if n <= 0:
            return x
        try:
            self.scr.addnstr(y, x, text, n, attr)
        except curses.error:
            pass
        return x + min(len(text), n)

    def col(self, pair: int, extra: int = 0) -> int:
        return (curses.color_pair(pair) if curses.has_colors() else 0) | extra

    def draw(self) -> None:
        self.scr.erase()
        h, w = self.size()
        if h < 16 or w < 64:
            self.put(0, 0, "Make the terminal bigger to pick (at least 64 x 16).", self.col(C_YELLOW))
            self.scr.refresh()
            return
        self.mark_seen()

        # Title
        x = self.put(0, 1, "oma-migrate", self.col(C_ACCENT, curses.A_BOLD))
        self.put(0, x + 2, "Prepare for a fresh install")
        when = nice_date(self.m.scan["scanned_at"])
        ov = self.m.scan["omarchy_version"]
        if self.m.from_other_install:
            choices = [f"Your old system's saved config · scanned {when} on Omarchy {ov}",
                       f"Your old system's saved config · {when}", f"Old system · {when}"]
        else:
            choices = [f"Scanned {when} · Omarchy {ov}", f"Scanned {when}"]
        room = w - (x + 2 + len("Prepare for a fresh install")) - 4
        ver = next((c for c in choices if len(c) <= room), "")
        if ver:
            self.put(0, w - len(ver) - 2, ver, self.col(C_YELLOW if self.m.from_other_install else C_MUTED))

        # Tabs
        self.tab_spans = []
        x = 1
        for n, p in enumerate(self.pages):
            if len(self.pages) == 1:
                label = f" Everything ({len(self.m.items)}) "
                done = not self.m.unseen()
            else:
                g = p[0]
                label = f" {n + 1} {g['title']} ({len(self.m.by_group[g['id']])}) "
                done = g["id"] in self.m.seen
            mark = TICK if done else TODO
            start = x
            attr = curses.A_REVERSE | curses.A_BOLD if n == self.page else 0
            x = self.put(2, x, label, attr)
            x = self.put(2, x, mark + " ", self.col(C_GREEN if done else C_YELLOW, curses.A_BOLD))
            self.tab_spans.append((start, x, n))
            x += 1
        self.put(3, 1, ("─" if UTF8 else "-") * (w - 2), self.col(C_MUTED))

        # List
        self.current()  # sets the highlight on a page's first visit
        lines = self.lines(self.page)
        lh = self.list_height()
        off = self.offset.get(self.page, 0)
        cur = self.cursor.get(self.page)
        name_w = max(18, min(34, w // 4))
        size_w = 9
        for row in range(lh):
            n = off + row
            if n >= len(lines):
                break
            y = self.TOP + row
            kind, v = lines[n]
            if kind == "head":
                g = v  # type: ignore[assignment]
                items = self.m.by_group[g["id"]]
                self.put(y, 1, g["title"], self.col(C_ACCENT, curses.A_BOLD))
                self.put(y, 2 + len(g["title"]), f"{sum(i['keep'] for i in items)} of {len(items)} kept", self.col(C_MUTED))
                continue
            if kind != "item":
                continue
            i = v  # type: ignore[assignment]
            sel = n == cur
            base = curses.A_REVERSE if sel else 0
            if sel:
                self.put(y, 0, " " * (w - 1), base)
            x = self.put(y, 1, (ARROW if sel else " ") + " ", base | curses.A_BOLD)
            if i["keep"]:
                x = self.put(y, x, BOX_ON, self.col(C_GREEN, curses.A_BOLD | base))
            else:
                x = self.put(y, x, BOX_OFF, self.col(C_MUTED, base))
            x += 1
            name = i["name"] if len(i["name"]) <= name_w else i["name"][: name_w - 1] + "…"
            self.put(y, x, name, base | (curses.A_BOLD if i["keep"] else 0))
            x += name_w + 1
            st = size_text(i)
            self.put(y, x + size_w - len(st), st, self.col(C_MUTED, base))
            x += size_w + 2
            if i["id"] in self.m.back:
                x = self.put(y, x, f"{TICK} Back", self.col(C_GREEN, curses.A_BOLD | base))
                self.put(y, x, "  already brought back", self.col(C_MUTED, base))
                continue
            s = i["suggest"]
            tag = SUGG_TEXT[s]
            if s != "you":
                tag = "Suggested: " + tag
            x = self.put(y, x, tag, self.col(SUGG_COLOR[s], curses.A_BOLD | base))
            if i["why"]:
                self.put(y, x, f"  {i['why']}", self.col(C_MUTED, base))
        if off > 0:
            self.put(self.TOP, w - 3, MORE_UP, self.col(C_YELLOW, curses.A_BOLD))
        if off + lh < len(lines):
            more = len(lines) - off - lh
            t = f"{MORE_DOWN} {more} more below "
            self.put(self.TOP + lh - 1, w - len(t) - 1, t, self.col(C_YELLOW, curses.A_BOLD))

        # Detail of the highlighted row
        y = h - self.BOTTOM
        i = self.current()
        if i:
            what = i["what"] or ""
            if i["kind"] == "package":
                what = (what + "  " if what else "") + f"({'AUR' if i.get('source') == 'aur' else 'package'}: {' '.join(i['packages'])})"
            self.put(y, 2, what, self.col(C_MUTED))
            if i["id"] in self.m.back:
                self.put(y + 1, 2, "Already brought back by Migrate my saved config. Unticking it doesn't remove anything.", self.col(C_MUTED))
            elif i["paths"]:
                paths = ", ".join(p["path"] for p in i["paths"][:4]) + (" …" if len(i["paths"]) > 4 else "")
                verb = "Brings back" if i["keep"] else "Would bring back"
                x = self.put(y + 1, 2, verb + ": ", curses.A_BOLD)
                self.put(y + 1, x, paths)
            elif i["kind"] in ("package", "flatpak", "tool"):
                self.put(y + 1, 2, "Installs the app again. No settings to bring back.", self.col(C_MUTED))
        self.put(y + 2, 1, ("─" if UTF8 else "-") * (w - 2), self.col(C_MUTED))

        # Totals, or a message
        y = h - 2
        text, color = self.message
        if text:
            self.put(y, 2, text, self.col(color, curses.A_BOLD))
        else:
            kept = self.m.kept()
            b, unknown = self.m.kept_bytes()
            x = self.put(y, 2, f"Keeping {len(kept)} of {len(self.m.items)}", curses.A_BOLD)
            x = self.put(y, x, f"  {DOT}  about {ms.human(b)} to copy back" + (" + system settings" if unknown else ""), self.col(C_MUTED))
            todo = self.m.unseen()
            if todo:
                self.put(y, x, f"  {DOT}  still to look at: " + ", ".join(g["title"] for g in todo), self.col(C_YELLOW, curses.A_BOLD))
            else:
                self.put(y, x, f"  {DOT}  every page looked at", self.col(C_GREEN))

        # Keys and buttons
        y = h - 1
        keys = [("↑↓" if UTF8 else "up/down", "move"), ("Space", "keep / don't"), ("←→" if UTF8 else "left/right", "pages"), ("r", "reset page")]
        x = 2
        for k, d in keys:
            x = self.put(y, x, k, self.col(C_ACCENT, curses.A_BOLD))
            x = self.put(y, x + 1, d, self.col(C_MUTED)) + 3
        self.button_spans = {}
        save_l, quit_l, scan_l = " Enter  Save picks ", " q  Quit ", " n  Scan again "
        sx = w - len(save_l) - len(quit_l) - 4
        if sx - len(scan_l) - 2 > x:
            nx = sx - len(scan_l) - 2
            self.button_spans["rescan"] = (nx, nx + len(scan_l), y)
            self.put(y, nx, scan_l, curses.A_REVERSE)
        if sx > x:
            self.button_spans["quit"] = (sx, sx + len(quit_l), y)
            self.put(y, sx, quit_l, curses.A_REVERSE)
            qx = sx + len(quit_l) + 2
            ready = not self.m.unseen()
            self.button_spans["save"] = (qx, qx + len(save_l), y)
            self.put(y, qx, save_l, self.col(C_GREEN if ready else C_MUTED, curses.A_REVERSE | curses.A_BOLD))

        if self.modal:
            self.draw_modal()
        self.scr.refresh()

    def draw_modal(self) -> None:
        h, w = self.size()
        if self.modal == "save":
            b, unknown = self.m.kept_bytes()
            body = [
                "Save your config?",
                "",
                f"Keeping {len(self.m.kept())} of {len(self.m.items)} things, about {ms.human(b)} to copy back.",
                "They are saved in your home folder, so your next backup carries them.",
                "",
                "Enter  save        Esc  go back",
            ]
        elif self.modal == "rescan":
            when = nice_date(self.m.scan["scanned_at"])
            body = [
                "Scan this computer again?",
                "",
                f"This replaces your saved config from {when} with a fresh scan of this",
                "computer, and your choices start again from the suggestions.",
                "",
                "Only do this when you're planning your next fresh install.",
            ]
            if self.m.from_other_install:
                body += [
                    "",
                    "This saved config is from your OLD system. Once replaced, you can't pick from it",
                    "here any more. (A copy stays in the backup you made before the wipe.)",
                ]
            body += ["", "Nothing is replaced until you look through the new scan and save.", "", "y  scan again        n  go back"]
        elif self.modal == "scanning":
            body = ["Scanning this computer …", "", "This takes a few seconds."]
        else:
            body = ["Quit without saving?", "", "Your changes on this screen will be lost.", "", "y  quit        n  go back"]
        bw = min(w - 4, max(len(s) for s in body) + 6)
        bh = len(body) + 2
        y0, x0 = (h - bh) // 2, (w - bw) // 2
        for r in range(bh):
            self.put(y0 + r, x0, " " * bw, curses.A_REVERSE)
        for r, s in enumerate(body):
            attr = curses.A_REVERSE | (curses.A_BOLD if r == 0 else 0)
            self.put(y0 + 1 + r, x0 + 3, s, attr)

    # ---- input

    def handle(self, key: int) -> str | None:
        """Returns "save" or "quit" when the picker should end."""
        self.message = ("", 0)
        self.mark_seen()
        if self.modal == "save":
            if key in (10, 13, curses.KEY_ENTER):
                return "save"
            if key in (27, ord("n"), ord("q")):
                self.modal = None
            return None
        if self.modal == "rescan":
            if key in (ord("y"), ord("Y")):
                return "rescan"
            if key in (27, ord("n"), ord("N"), 10, 13, ord("q")):
                self.modal = None
            return None
        if self.modal == "quit":
            if key in (ord("y"), ord("Y")):
                return "quit"
            if key in (27, ord("n"), ord("N"), 10, 13):
                self.modal = None
            return None

        lh = self.list_height()
        if key in (curses.KEY_UP, ord("k")):
            self.move(-1)
        elif key in (curses.KEY_DOWN, ord("j")):
            self.move(1)
        elif key == curses.KEY_PPAGE:
            self.move(-(lh - 1))
        elif key == curses.KEY_NPAGE:
            self.move(lh - 1)
        elif key == curses.KEY_HOME:
            self.move(-10_000)
        elif key == curses.KEY_END:
            self.move(10_000)
        elif key in (ord(" "), ord("x")):
            i = self.current()
            if i:
                self.m.toggle(i)
        elif key in (curses.KEY_RIGHT, ord("\t"), ord("l")):
            if self.page < len(self.pages) - 1:
                self.go_page(self.page + 1)
            else:
                self.flash("That's the last page. Press Enter to save when you're happy.", C_ACCENT)
        elif key in (curses.KEY_LEFT, curses.KEY_BTAB, ord("h")):
            self.go_page(self.page - 1)
        elif ord("1") <= key <= ord("9") and key - ord("1") < len(self.pages):
            self.go_page(key - ord("1"))
        elif key == ord("n"):
            self.modal = "rescan"
        elif key == ord("r"):
            for g in self.pages[self.page]:
                self.m.reset(self.m.by_group[g["id"]])
            self.flash("This page is back to the suggestions.", C_ACCENT)
        elif key in (10, 13, curses.KEY_ENTER, ord("s")):
            self.try_save()
        elif key in (ord("q"), 27):
            if self.m.dirty:
                self.modal = "quit"
            else:
                return "quit"
        elif key == curses.KEY_MOUSE:
            return self.handle_mouse()
        elif key == curses.KEY_RESIZE:
            self.layout()
            self.scroll_to_cursor()
        return None

    def replace_model(self, model: Model) -> None:
        self.m = model
        self.m.dirty = True
        self.modal = None
        self.page = 0
        self.cursor, self.offset = {}, {}
        self.layout()
        self.flash("Fresh scan of this computer. Look through every page, then save to replace the old list.", C_ACCENT)

    def try_save(self) -> None:
        todo = self.m.unseen()
        if todo:
            names = ", ".join(g["title"] for g in todo)
            self.flash(f"Look through every page first. Still to look at: {names}", C_YELLOW)
            for n, p in enumerate(self.pages):
                if any(g["id"] not in self.m.seen for g in p):
                    if n != self.page:
                        self.go_page(n)
                    else:
                        self.move(10_000)  # same page: take them to the bottom of it
                    break
            return
        self.modal = "save"

    def handle_mouse(self) -> str | None:
        try:
            _, mx, my, _, bstate = curses.getmouse()
        except curses.error:
            return None
        wheel_up = getattr(curses, "BUTTON4_PRESSED", 0)
        wheel_down = getattr(curses, "BUTTON5_PRESSED", 0x200000)
        if bstate & wheel_up:
            self.move(-3)
            return None
        if bstate & wheel_down:
            self.move(3)
            return None
        # One click arrives as a press and then a release (mouseinterval is 0,
        # so curses doesn't merge them). Act on the press only, or a click
        # on the box ticks it and unticks it again straight away.
        clicked = bstate & (curses.BUTTON1_PRESSED | curses.BUTTON1_CLICKED)
        if not clicked:
            return None
        if self.modal:
            return None
        for x0, x1, n in self.tab_spans:
            if my == 2 and x0 <= mx < x1:
                self.go_page(n)
                return None
        for name, (x0, x1, y) in self.button_spans.items():
            if my == y and x0 <= mx < x1:
                if name == "save":
                    self.try_save()
                elif name == "rescan":
                    self.modal = "rescan"
                else:
                    return self.handle(ord("q"))
                return None
        row = my - self.TOP
        if 0 <= row < self.list_height():
            n = self.offset.get(self.page, 0) + row
            lines = self.lines(self.page)
            if n < len(lines) and lines[n][0] == "item":
                self.cursor[self.page] = n
                # A click on the box itself ticks it, like a checkbox.
                if 1 <= mx <= 6:
                    self.m.toggle(lines[n][1])  # type: ignore[arg-type]
        return None


def nice_date(stamp: str) -> str:
    try:
        import calendar
        t = time.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ")
        return time.strftime("%-d %b %Y", time.localtime(calendar.timegm(t)))
    except (ValueError, TypeError):
        return stamp or "an earlier date"


def run_picker(model: Model) -> tuple[str, Model]:
    def main(scr) -> tuple[str, Model]:
        curses.curs_set(0)
        if curses.has_colors():
            curses.start_color()
            try:
                curses.use_default_colors()
                bg = -1
            except curses.error:
                bg = curses.COLOR_BLACK
            curses.init_pair(C_GREEN, curses.COLOR_GREEN, bg)
            curses.init_pair(C_RED, curses.COLOR_RED, bg)
            curses.init_pair(C_YELLOW, curses.COLOR_YELLOW, bg)
            curses.init_pair(C_ACCENT, curses.COLOR_CYAN, bg)
            curses.init_pair(C_MUTED, 8 if curses.COLORS > 8 else curses.COLOR_WHITE, bg)
        curses.mousemask(curses.ALL_MOUSE_EVENTS | curses.REPORT_MOUSE_POSITION)
        curses.mouseinterval(0)
        scr.keypad(True)
        p = Picker(scr, model)
        p.layout()
        while True:
            p.draw()
            result = p.handle(scr.getch())
            if result == "rescan":
                p.modal = "scanning"
                p.draw()
                p.replace_model(Model(ms.scan(sizes=True, quiet=True), None))
                continue
            if result:
                return result, p.m

    os.environ.setdefault("ESCDELAY", "25")
    return curses.wrapper(main)


def show() -> int:
    data = load_previous()
    if not data:
        print(f"No saved config yet. Run oma-migrate to make one ({PICKS_FILE}).")
        return 1
    print(f"Config saved {data['saved_at']} on Omarchy {data['omarchy_version']}  ({PICKS_FILE})\n")
    items = data["items"]
    for g in data["groups"]:
        rows = [i for i in items if i["group"] == g["id"]]
        print(f"== {g['title']}")
        for i in rows:
            print(f"  {'Keep ' if i['keep'] else '  -  '}  {i['name']}")
        print()
    kept = [i for i in items if i["keep"]]
    print(f"Keeping {len(kept)} of {len(items)}.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Pick what comes back after a fresh install.")
    ap.add_argument("--show", action="store_true", help="print the saved picks")
    a = ap.parse_args()
    if a.show:
        return show()
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        print("oma-migrate: the picker needs a terminal. Use 'oma-migrate scan --json' from scripts.", file=sys.stderr)
        return 1
    previous = load_previous()
    if previous and previous.get("items"):
        # The saved config, not a new scan: after a fresh install this is the
        # only record of the old system. "Scan again" in the picker replaces it.
        model = Model(previous, previous)
    else:
        print("oma-migrate: looking at what's on this computer …", file=sys.stderr)
        model = Model(ms.scan(sizes=True, quiet=True), None)
    result, model = run_picker(model)
    if result != "save":
        print("Nothing saved." + (f" Your saved config is still in {PICKS_FILE}." if previous else ""))
        return 0
    path = save(model)
    b, _ = model.kept_bytes()
    print(f"Saved your config: keeping {len(model.kept())} of {len(model.items)} things (about {ms.human(b)}).")
    print(f"  {ms.tilde(path)}")
    print("Your next backup carries this file. Run oma-migrate again any time to change your mind.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
