# OmaBackups

**v0.9.1 beta** — not a 1.0 release.

Time Machine-style **encrypted USB backups** for [Omarchy](https://omarchy.org/).
A USB disk holds system + home copies. The same USB can boot a restore wizard.
The daily UI is an Omarchy bar plugin.

This is **off-box** backup. Snapper + Limine snapshots stay for “undo a bad
update.”

> **Beta.** Format and restore **wipe disks**. A bug can destroy the machine
> you restore onto, or the USB you format. Do not use this as your only copy.
> Keep Clonezilla (or similar) until you have booted a restored disk
> successfully **on hardware you can afford to lose**.

## What you get

1. **Bar plugin** — disk icon. Backup now, stop, dated restore points, settings.
2. **Encrypted backup USB** — plug in, set it up from the plugin (wipe is explicit).
3. **File history** — pick a date, browse that copy, copy files out.
4. **Bare-metal restore** — firmware-boot the USB (Limine: “Rescue Disk”).
   Real Omarchy live environment + a restore wizard. Pick a date, pick a disk,
   type the name and YES.

## Install (Omarchy)

```bash
git clone https://github.com/MattsMacsGit/oma-backups-tm.git ~/src/oma-backups
cd ~/src/oma-backups
./install.sh
```

Open the **OmaBackups** disk icon on the bar. Plug in a USB disk.

## Uninstall

```bash
~/src/oma-backups/uninstall.sh          # keeps your skip list / settings
~/src/oma-backups/uninstall.sh --purge  # removes those too
```

Undoes what `install.sh` set up on this account, then offers to delete the
cloned repo folder too. Never touches any backup USB disk.

Do **not** run `omarchy refresh shell` — that resets the bar and drops
third-party plugins. If the icon is missing: `omarchy plugin enable oma.backups`
then `omarchy-restart-shell` (restart is OK; refresh is not).

After editing plugin QML, `omarchy-shell shell rescanPlugins` is often not
enough — use `omarchy-restart-shell`.

## How a backup works

Omarchy is LUKS + btrfs `@` / `@home`. Each backup:

1. Freeze with `btrfs subvolume snapshot -r`
2. `rsync -aHAX --delete --delete-excluded` onto the USB (skip list applied every time)
3. Snapshot the destination so you can browse dated copies

Not restic. Not `btrfs send`. Not `dd`.

## Back up to a Raspberry Pi (beta)

Keep the backup USB plugged into an always-on Pi (Raspberry Pi OS / Debian 12
or newer) and back up over your network or Tailscale.

1. Set up the backup USB and run a backup, as usual.
2. With it still plugged into the laptop: `oma-backups remote pair <pi-name>`
   (a Tailscale name, IP, or ssh alias). This adds a laptop-only unlock key to
   the disk and sets up the Pi over your normal SSH login (it asks for the
   Pi's sudo password once).
3. Plug the USB into the Pi. Backups now go there whenever the USB isn't
   plugged into the laptop.

The disk stays locked between backups; the laptop sends the unlock key each
time. The laptop's SSH key can only reach a small gatekeeper (`pi/oma-gate`)
that unlocks this one disk and writes backups to it, nothing else on the Pi.
Full restores still need the USB brought back and booted.

**Power:** a USB-powered backup drive plugged into a hub the Pi's other drives
share can knock those drives offline for a moment while it spins up. Stop
services that use them (e.g. Docker) before plugging it in, or give the
backup drive its own power.

## Safety

- USB disks only, unless **Show all disks** (Settings)
- Live root is never a format/restore target
- Wiping requires an explicit erase confirm
- Ventoy / Clonezilla sticks stay hidden unless you show all disks
- A disk that already has backups is **used as-is** until you explicitly start over

Restore from a running desktop is expert-only (`--allow-internal`).
The intended path is **booting the USB**.

## UI

- **Home:** last copy, Backup now / Stop, last 5 restore points, **More**, gear
- **Settings:** skip list, show all disks, erase / start over

Skip list: `~/.config/omarchy-backups/skip-paths.txt`. Compiled into rsync
excludes at the start of **every** backup.

## CLI

After install, `oma-backups` is on `PATH` (`~/.local/bin`).

```bash
oma-backups detect
oma-backups disks            # USB default
oma-backups disks --all
oma-backups backup --yes
oma-backups stop
oma-backups snapshots
oma-backups doctor
oma-backups version
oma-backups restore-to-disk /dev/TARGET --snapshot TS --dry-run
```

## Backup USB layout

| Partition | Size | Filesystem | Role |
|---|---|---|---|
| `OMARCHY-EFI` | 1G | FAT32 | Limine + Omarchy ISO kernel |
| `OMARCHY-LIVE` | 16G | ext4 | Real Omarchy ISO (`arch/`) + restore scripts |
| LUKS → `OMARCHY-TM` | rest | btrfs zstd | `os/`, `home/`, `esp/`, `meta/` |

Disk names (`sda` / `nvme0n1` / …) shuffle. Identify by **label** and `lsblk TRAN`.

## Names

| What | Name |
|---|---|
| Product | OmaBackups |
| Plugin id | `oma.backups` |
| CLI | `oma-backups` |
| Config | `~/.config/omarchy-backups/` |
| Runtime | `/run/omarchy-backups` |

`omarchy-backups` and `omarchy-tm` are aliases of the same CLI.

## License

MIT. See `LICENSE`.
