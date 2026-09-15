#!/usr/bin/env python3
"""Folder/file picker in a separate process so Quickshell does not crash."""

from __future__ import annotations

import argparse
import os
import sys


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--file", action="store_true", help="pick a file instead of a folder")
    args = p.parse_args()
    home = os.environ.get("HOME") or "/home"
    try:
        import gi

        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk
    except Exception as e:
        print(f"picker unavailable: {e}", file=sys.stderr)
        return 2

    action = Gtk.FileChooserAction.OPEN if args.file else Gtk.FileChooserAction.SELECT_FOLDER
    title = "Skip this file in backups" if args.file else "Skip this folder in backups"
    dlg = Gtk.FileChooserNative.new(title, None, action, "Select", "Cancel")
    dlg.set_current_folder(home)
    if dlg.run() == Gtk.ResponseType.ACCEPT:
        path = dlg.get_filename()
        if path:
            print(path)
            return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
