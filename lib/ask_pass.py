#!/usr/bin/env python3
"""GTK passphrase prompt in a separate process (Quickshell must not own dialogs)."""

from __future__ import annotations

import argparse
import os
import sys


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--title", default="OmaBackups")
    p.add_argument(
        "--prompt",
        default="Encryption password for the backup disk",
    )
    p.add_argument("--confirm", action="store_true", help="ask twice and require a match")
    args = p.parse_args()
    try:
        import gi

        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk
    except Exception as e:
        print(f"password prompt unavailable: {e}", file=sys.stderr)
        return 2

    def ask(title: str) -> str | None:
        dlg = Gtk.Dialog(title=args.title, flags=0)
        dlg.add_buttons(
            Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
            Gtk.STOCK_OK, Gtk.ResponseType.OK,
        )
        dlg.set_default_response(Gtk.ResponseType.OK)
        box = dlg.get_content_area()
        box.set_spacing(8)
        box.set_border_width(12)
        label = Gtk.Label(label=title, xalign=0)
        label.set_line_wrap(True)
        entry = Gtk.Entry()
        entry.set_visibility(False)
        entry.set_activates_default(True)
        box.add(label)
        box.add(entry)
        dlg.show_all()
        resp = dlg.run()
        text = entry.get_text() if resp == Gtk.ResponseType.OK else None
        dlg.destroy()
        while Gtk.events_pending():
            Gtk.main_iteration()
        return text

    a = ask(args.prompt)
    if not a:
        return 1
    if args.confirm:
        b = ask("Confirm password")
        if a != b:
            print("passwords did not match", file=sys.stderr)
            return 1
    sys.stdout.write(a)
    return 0


if __name__ == "__main__":
    os.environ.setdefault("GDK_BACKEND", "wayland")
    raise SystemExit(main())
