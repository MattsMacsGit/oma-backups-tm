# OmaBackups

**v1.0.0** — first full backup + bare-metal restore proven.

Time Machine for [Omarchy](https://omarchy.org/). A USB disk holds encrypted
system + home copies. The same USB boots a restore wizard. The daily UI is an
Omarchy bar plugin — not a separate app.

This is the **off-box** copy. Snapper + Limine snapshots stay for “undo a bad
update.”

## What you get

1. **Bar plugin** — disk icon on the right. Backup now, stop, dated restore points, settings gear.
2. **Encrypted backup USB** — plug in, set it up from the plugin (wipe is explicit).
3. **File history** — pick a date, browse that copy of your files, copy them wherever you want.
4. **Bare-metal restore** — firmware-boot the USB (Limine: “OmaBackups Restore”). That starts the official Arch live environment and a restore wizard. Pick a date, pick a disk (every disk is listed), type the name and YES.

## Install (any Omarchy)

```bash
git clone https://github.com/MattsMacsGit/oma-backups-tm.git ~/src/oma-backups
cd ~/src/oma-backups
./install.sh
```

Open the **OmaBackups** disk icon on the bar. Plug in a USB disk.

Do **not** run `omarchy refresh shell` — that resets the bar and drops
third-party plugins. If the icon is missing: `omarchy plugin enable oma.backups`
then `omarchy-restart-shell` (restart is OK; refresh is not).

After editing the plugin QML, `omarchy-shell shell rescanPlugins` is often not
enough — use `omarchy-restart-shell`.

## How a backup works

Omarchy is already LUKS + btrfs `@` / `@home`. Each backup:

1. Freeze with `btrfs subvolume snapshot -r`
2. `rsync -aHAX --delete --delete-excluded` onto the USB (excludes applied every time)
3. Snapshot the destination so you can browse dated copies

Not restic. Not `btrfs send`. Not `dd`.

Progress: rsync 3.x sends `--info=progress2` on **stdout** (not stderr). The
engine pipes `2>&1` into `lib/progress.py` and writes
`/run/omarchy-backups.status`. Each stage (OS / Home / Boot) is its own 0–100 bar.

## Safety

- USB disks only, unless **Show all disks** (in Settings)
- Live root is never a target
- Wiping requires **Erase this backup disk** plus a second confirm
- Ventoy / Clonezilla sticks stay hidden unless you show all disks
- A disk that already has backups is **used as-is** until you explicitly start over

## UI

- **Home:** last copy, Backup now / Stop, last 5 restore points, **More** for older ones, gear
- **Settings (gear):** skip list, show terminal, show all disks, erase / start over

Skip list: `~/.config/omarchy-backups/skip-paths.txt`. Compiled into rsync
excludes at the start of **every** backup from `SUDO_USER`’s home.

## CLI

`oma-backups` is on `PATH` after install (`~/.local/bin`).

```bash
oma-backups detect
oma-backups disks            # USB default
oma-backups disks --all
oma-backups backup --yes
oma-backups stop
oma-backups snapshots
oma-backups doctor
oma-backups restore-to-disk /dev/TARGET --snapshot TS --dry-run
```

Full restore from a running desktop is expert-only (`--allow-internal`).
The intended path is booting the USB.

## Layout of the backup USB

| Partition | Size | Filesystem | Role |
|---|---|---|---|
| `OMARCHY-EFI` | 1G | FAT32 | Limine + Arch ISO kernel |
| `OMARCHY-LIVE` | 16G | ext4 | Official Arch ISO (`arch/`) + restore scripts |
| LUKS → `OMARCHY-TM` / `OMARCHY-BACKUPS` | rest | btrfs zstd | `os/`, `home/`, `esp/`, `meta/` |

Disk letters (`sda`/`sdb`/`sdc`) shuffle. Identify by label and `lsblk TRAN`.
