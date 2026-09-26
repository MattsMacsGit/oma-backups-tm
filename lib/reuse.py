#!/usr/bin/env python3
"""Put files the backup disk already has into a working copy, before a backup
sends them again.

  reuse.py ROOT KIND TS [TS ...] < records

A file that has dropped out of the working copy -- a folder that was skipped
for a while, one moved away and back, a system restored from this very disk
-- is still in older restore points. rsync only compares against the working
copy, so it would send the file again and the disk would keep it twice. This
makes the working copy's file share the restore point's stored copy instead
(a btrfs clone: instant, and it takes no space), and the backup that follows
finds it already there.

Records on stdin are NUL-ended "SIZE MTIME_NS PATH", PATH relative to the
tree, as lib/progress.py's check writes them. TS are the restore points to
look in, best first; each file comes from the first one holding exactly that
file (same size, same modification time), and only where the working copy
has nothing at that path. Prints "FILES BYTES": what was reused.

ROOT is the backup disk's top level (ROOT/KIND/current, ROOT/KIND/TS). The
Pi's gatekeeper runs this as root on paths a laptop names, so every step
through the tree is taken without following symlinks, and nothing outside
ROOT/KIND is ever opened.
"""

from __future__ import annotations

import errno
import fcntl
import os
import re
import stat
import sys
from typing import BinaryIO, Iterator

FICLONE = 0x40049409
STAMP = re.compile(r"^\d{8}T\d{6}Z$")
MAX_RECORD = 16384
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


class Refused(Exception):
    pass


def records(stream: BinaryIO) -> Iterator[tuple[int, int, list[bytes]]]:
    """(size, mtime_ns, path parts) for every well-formed record."""
    buf = b""
    while True:
        chunk = stream.read(1 << 16)
        if not chunk:
            break
        buf += chunk
        *whole, buf = buf.split(b"\0")
        if len(buf) > MAX_RECORD:
            raise Refused("a record is too long")
        for rec in whole:
            parsed = parse(rec)
            if parsed:
                yield parsed


def parse(rec: bytes) -> tuple[int, int, list[bytes]] | None:
    try:
        size, mtime, path = rec.split(b" ", 2)
        size_n, mtime_n = int(size), int(mtime)
    except ValueError:
        return None
    parts = path.split(b"/")
    if size_n < 0 or not all(parts) or any(p in (b".", b"..") for p in parts):
        return None
    return size_n, mtime_n, parts


def open_dir(parent: int, parts: list[bytes], create: bool = False) -> int | None:
    """A directory under PARENT, one step at a time, never through a symlink.
    With CREATE, missing ones are made (rsync sets their owner and mode)."""
    fd = os.dup(parent)
    try:
        for name in parts:
            try:
                nxt = os.open(name, DIR_FLAGS, dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    return None
                try:
                    os.mkdir(name, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
                nxt = os.open(name, DIR_FLAGS, dir_fd=fd)
            except OSError as e:
                if e.errno in (errno.ENOTDIR, errno.ELOOP):
                    return None
                raise
            os.close(fd)
            fd = nxt
        out, fd = fd, -1
        return out
    finally:
        if fd >= 0:
            os.close(fd)


def exists(parent: int, parts: list[bytes]) -> bool:
    d = open_dir(parent, parts[:-1])
    if d is None:
        # A file where a folder should be counts as there: leave it to rsync.
        return _blocked(parent, parts[:-1])
    try:
        os.stat(parts[-1], dir_fd=d, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False
    finally:
        os.close(d)


def _blocked(parent: int, parts: list[bytes]) -> bool:
    fd = os.dup(parent)
    try:
        for name in parts:
            try:
                st = os.stat(name, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                return False
            if not stat.S_ISDIR(st.st_mode):
                return True
            nxt = os.open(name, DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = nxt
        return False
    finally:
        os.close(fd)


def find(points: list[int], size: int, mtime: int, parts: list[bytes]) -> int | None:
    """An open fd on the first restore point's copy of exactly this file."""
    for root in points:
        d = open_dir(root, parts[:-1])
        if d is None:
            continue
        try:
            fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=d)
        except OSError:
            continue
        finally:
            os.close(d)
        st = os.fstat(fd)
        if stat.S_ISREG(st.st_mode) and st.st_size == size and st.st_mtime_ns == mtime:
            return fd
        os.close(fd)
    return None


def clone(src: int, current: int, parts: list[bytes]) -> bool:
    d = open_dir(current, parts[:-1], create=True)
    if d is None:
        return False
    name = parts[-1]
    try:
        try:
            dst = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                          0o600, dir_fd=d)
        except FileExistsError:
            return False
        try:
            fcntl.ioctl(dst, FICLONE, src)
            st = os.fstat(src)
            os.fchown(dst, st.st_uid, st.st_gid)
            os.fchmod(dst, stat.S_IMODE(st.st_mode))
            for key in os.listxattr(src):
                try:
                    os.setxattr(dst, key, os.getxattr(src, key))
                except OSError:
                    pass  # rsync -X puts right whatever didn't take
            # Last: rsync takes a file with the right size and time as done.
            os.utime(dst, ns=(st.st_atime_ns, st.st_mtime_ns))
        except OSError:
            os.close(dst)
            os.unlink(name, dir_fd=d)
            return False
        os.close(dst)
        return True
    finally:
        os.close(d)


def reuse(root: str, kind: str, stamps: list[str], stream: BinaryIO) -> tuple[int, int]:
    if kind not in ("os", "home"):
        raise Refused(f"can't reuse files into {kind!r}")
    if not stamps or not all(STAMP.match(ts) for ts in stamps):
        raise Refused("restore points must be named like 20260926T010203Z")
    top = os.open(root, DIR_FLAGS)
    fds: list[int] = []
    try:
        base = open_dir(top, [kind.encode()])
        if base is None:
            raise Refused(f"no {kind} folder on the backup disk")
        fds.append(base)
        current = open_dir(base, [b"current"])
        if current is None:
            raise Refused(f"no {kind}/current on the backup disk")
        fds.append(current)
        points = []
        for ts in dict.fromkeys(stamps):
            fd = open_dir(base, [ts.encode()])
            if fd is not None:
                fds.append(fd)
                points.append(fd)
        files = total = 0
        for size, mtime, parts in records(stream):
            if not points or exists(current, parts):
                continue
            src = find(points, size, mtime, parts)
            if src is None:
                continue
            try:
                if clone(src, current, parts):
                    files += 1
                    total += size
            finally:
                os.close(src)
        return files, total
    finally:
        for fd in reversed(fds):
            os.close(fd)
        os.close(top)


def main() -> int:
    if len(sys.argv) < 4:
        print("usage: reuse.py ROOT KIND TS [TS ...] < records", file=sys.stderr)
        return 2
    try:
        files, total = reuse(sys.argv[1], sys.argv[2], sys.argv[3:], sys.stdin.buffer)
    except Refused as e:
        print(f"reuse: {e}", file=sys.stderr)
        return 2
    print(files, total)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
