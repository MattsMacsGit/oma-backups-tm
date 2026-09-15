# Paste this as the first message in a new Grok Build session

Continue **OmaBackups** (Time Machine for Omarchy). Work in `/home/test/Work/omarchy-tm` (or the copy on the user’s main OS). **Never format, restore onto, or wipe `/dev/nvme0n1`.** Never format Ventoy.

Read `README.md` and this file before changing anything. Validate in the **actual bar panel** (screenshot with `grim`) and by booting the USB for restore — do not claim UI or restore works from CLI alone.

## Where we are (2026-09-13, end of testrig night)

**Working**

- Encrypted 3-part USB capsule, wipe/setup from the plugin (two confirms).
- Engine: btrfs RO snapshot of `@`/`@home` → `rsync -aHAX --delete --delete-excluded` → dest RO snapshot. Not restic / send / dd.
- Skip list (GTK picker subprocess, not Qt FolderDialog). Recompiled every backup from `SUDO_USER` home.
- Plugin `oma.backups` on the bar right. Home page: last copy, Backup now/Stop, last **5** restore points + **More**, gear. Settings: skip, show terminal, show all disks, erase.
- Dated restore points (`Sunday 13 Sep  20:22`), not folder codes. Click opens that date’s `$USER` folder via `oma-backups open TS`.
- Stop backup works.
- Progress bar: each phase is 0–100 (OS / Home / Boot). rsync **3.5 sends `--info=progress2` on stdout**, not stderr. `backup.sh` must `2>&1 | lib/progress.py stream PHASE`. Verified status JSON moves (e.g. Home 0→2→78).
- Testrig user `test` has passwordless sudo (`/etc/sudoers.d/test-yolo`). Do not copy that to a real machine.

**Not done (next session, in order)**

1. **Boot the backup USB from firmware / Limine** into the restore TUI (`lib/restore_tui.py`) and complete a restore onto a **blank** disk. Not the live root USB, not Ventoy, not nvme0n1 unless the user explicitly wants to restore the Framework disk from the rescue stick.
2. Tighten rescue: `refresh-rescue` / LIVE partition I/O, kernel from **this** machine’s `/boot`, Limine `OmaBackups Restore` entry.
3. Backup **scheduler** in Settings (user asked to defer until restore works).
4. Optional: hide the floating terminal (`install-polkit.sh` + toggle off “Show backup terminal”).

## Product rules (do not bikeshed)

| Layer | Tool |
|---|---|
| Freeze | `btrfs subvolume snapshot -r` of `@` and `@home` |
| Copy | `rsync -aHAX --delete --delete-excluded --info=progress2` |
| Encryption | LUKS2 on the data partition only |
| History | dest `os/current` + `home/current` snapshotted after each rsync |
| Dest FS | btrfs `compress=zstd:3` |
| Rescue | 1G FAT32 `OMARCHY-EFI` + 16G ext4 `OMARCHY-LIVE` + rest LUKS→btrfs |

## Testrig facts

- Hostname `testrig`, user `test`, Omarchy 4.0.1.
- **Live root (do not format):** USB `sda` — 2G vfat `/boot` + LUKS → btrfs.
- **Ventoy (do not format):** ~1TB Ventoy/VTOYEFI. Often `sdb`/`sdc`; letters shuffle.
- **Backup dest:** 1.8T Seagate USB. Labels `OMARCHY-EFI` + `OMARCHY-LIVE` + LUKS (inner fs `OMARCHY-TM` or `OMARCHY-BACKUPS`). **Letters shuffle** — use labels/`TRAN=usb`.
- **Never touch:** `nvme0n1` 3.6T (user’s real Framework disk).
- Code: `/home/test/Work/omarchy-tm`. Plugin install: `~/.config/omarchy/plugins/oma.backups` — **rsync from `plugin/oma.backups/`** then `omarchy-restart-shell`. `rescanPlugins` often does not reload QML. **Never `omarchy refresh shell`.**
- Skip list: `~/.config/omarchy-backups/skip-paths.txt`.

## Hard lessons (do not repeat)

1. Root with `HOME=/root` ignores skip list. Always `SUDO_USER`. Never write excludes to `/tmp`.
2. Qt `FolderDialog` in Quickshell SIGSEGVs. GTK `lib/pick_path.py` only.
3. Repeater row remove on the same click SIGABRTs. `ListModel` + `Qt.callLater`.
4. `pty.fork()` around rsync steals sudo TTY. Never.
5. `du -sb` while rsync runs freezes the disk. Never.
6. Format must **close leftover LUKS mappers by real `lsblk -nr` name** (tree glyphs like `└─omarchy-backups` make `cryptsetup close` fail). Wipe LUKS header **before** FAT/ext4. Abort if UUID does not change. Encrypt LUKS **before** pacstrap so a later failure cannot leave the old volume.
7. **Stale mapper:** USB re-enumerates (`sdc`→`sdd`→`sdb`). Old `cryptsetup` mapper points at a gone major:minor (`device: (null)`), btrfs error-locks **read-only**, `remount,rw` is refused. Detect stale (`cryptsetup status` device null or not a blockdev), `cryptsetup close`, reopen the **current** partition. **Do not bind-mount** the Files/udisks mount (often RO). Mount `/dev/mapper/…` **rw** at `/run/omarchy-backups`.
8. Omarchy ISO will not fit on FAT32. Rescue = small userspace + this machine’s kernel on EFI.
9. Status: never treat missing `running` as false. Never treat `stale: true` as “backup finished” while the plugin just launched one (`launchedBackup`). `BarIconButton` is a **direct child of Panel**. `IpcHandler` needs `import Quickshell.Io` in **Panel.qml** or the widget fails to load (`IpcHandler is not a type`).
10. Restore-point list: parse `Sunday 13 Sep  20:22 | 20260913T102202Z` from `oma-backups snapshots`. Do not use QML `Date` for labels. Do not `write_cache([])` when the disk is merely unmounted (that wiped the UI list).
11. rsync 3.5 `--info=progress2` goes to **stdout**. Engine: `rsync … 2>&1 | python3 lib/progress.py stream PHASE`. PIPESTATUS[0] for rsync’s exit. Treat rsync 23/24 as warnings, still snapshot dest.
12. Disk names change. Identify by label + TRAN.

## CLI

`oma-backups` (`~/.local/bin`, also `omarchy-backups`):

```
detect [--json]
disks [--json] [--all]
backup [--yes] [--home-only]
stop
snapshots
open TIMESTAMP
mount / umount
format-disk /dev/sdX
restore-to-disk /dev/TARGET --snapshot TS [--dry-run] [--allow-internal]
restore-tui
refresh-rescue
doctor
status
```

## Validate

- Panel: `omarchy-shell -q oma.backups toggle` then `grim`. Home shows dates + More if >5. Gear opens settings.
- Progress: poll `/run/omarchy-backups.status` during a backup; `percent` must move off 0 while rsync runs.
- Restore: boot the USB, TUI unlocks LUKS, pick a **VALID** (os+home+esp) point, restore to a blank disk. Home-only points are not full restores.
