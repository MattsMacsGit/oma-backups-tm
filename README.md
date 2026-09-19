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
3. **Automatic backups** — hourly, daily or weekly, with old restore points
   thinned out Time Machine-style.
4. **File history** — click a date to open your home folder as it was, read-only,
   in Files. Copy files out.
5. **No password prompts** for everyday use once the laptop is linked to its disk.
6. **Bare-metal restore** — firmware-boot the USB (Limine: “Rescue Disk”).
   Real Omarchy live environment + a restore wizard. Pick a date, pick a disk,
   type the name and YES.
7. **Optional Raspberry Pi** — keep the USB in an always-on Pi and back up over
   the network.

## Install (Omarchy)

```bash
git clone https://github.com/MattsMacsGit/oma-backups-tm.git ~/src/oma-backups
cd ~/src/oma-backups
./install.sh
```

Open the **OmaBackups** disk icon on the bar. Plug in a USB disk.

To update: `git pull` in the clone, then `./install.sh` again. If the laptop is
linked (see below), this asks for sudo once to refresh the linked copy.

## Uninstall

```bash
~/src/oma-backups/uninstall.sh          # keeps your skip list / settings
~/src/oma-backups/uninstall.sh --purge  # removes those too
```

Undoes what `install.sh` set up on this account, and removes the backup
services, the polkit rule and the root-owned copy in `/usr/local/lib/oma-backups`.
Then offers to delete the cloned repo folder too. Never touches any backup USB
disk.

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

## Automatic backups

Settings → **Back up automatically**, then pick **Hourly**, **Daily** or
**Weekly**. The home page shows when the next one is due.

- A systemd timer checks every hour and backs up when one is due.
- Skipped quietly when the backup disk isn't plugged in (or the Pi can't be
  reached), or the battery is under 20%.
- A notification only after three missed intervals in a row (3 hours for
  hourly, 3 days for daily, 3 weeks for weekly), at most once a day.
- The timer runs from a root-owned copy in `/usr/local/lib/oma-backups`, never
  from the user-owned clone. `./install.sh` refreshes it when you update.

## Keeping restore points

Each restore point only takes space for what changed since the last one, so
keeping many is cheap. After every backup, **Smart thinning** (the default):

- keeps every restore point from the last 24 hours
- keeps one per day for 30 days, then one per week
- when the disk is under 10% free, deletes the oldest first
- never deletes the newest restore point

Turn Smart thinning off in Settings to keep everything; you get a warning when
the disk is nearly full instead. Preview what thinning would do:
`oma-backups prune --dry-run`.

## Linking the laptop (no password prompts)

Linking happens when you set up a disk or pair a Pi. Existing setups get a
**Stop asking for my password** button on the home page. `oma-backups link`
asks for sudo once and:

- adds a root-only unlock key held by this laptop to the backup disk
- installs systemd services for back up now, opening a restore point, and the
  hourly check
- adds a polkit rule letting **only this user**, **only from an active local
  session**, start and stop **only those services** without a password

After that, backing up, stopping, automatic backups and opening restore points
don't ask for a password. Setting up or erasing a disk, restoring, and pairing
or unpairing a Pi still do.

The disk stays encrypted. Away from this laptop it's useless without its
password.

## Opening restore points

Click a date on the home page. Your own home folder from that date opens in
Files, **read-only**. Copy what you need out, then press **Done** in the panel
to close it (on a Pi this also locks the disk again).

Works with the USB plugged in, or from a paired Pi over `sshfs` (slower, and a
notification says it's opening). On the Pi, the folder is served by
`sftp-server -R` inside a `bubblewrap` sandbox that contains nothing else.

## Using a different disk

Settings → **Use a different disk**: pick another USB, confirm the erase, and it
becomes the backup disk. The old disk isn't touched and keeps its restore
points.

The current disk is remembered by its encryption ID, so two backup USBs plugged
in at once never get mixed up.

## Back up to a Raspberry Pi (beta)

Keep the backup USB plugged into an always-on Pi (Raspberry Pi OS / Debian 12
or newer) and back up over your network or Tailscale.

1. Set up the backup USB and run a backup, as usual.
2. With it still plugged into the laptop: Settings → **Back up to a Pi**, or
   `oma-backups remote pair my-pi` (a Tailscale name, IP, or ssh alias). This
   adds a laptop-only unlock key to the disk and sets up the Pi over your normal
   SSH login (it asks for the Pi's sudo password once).
3. Plug the USB into the Pi. Backups now go there whenever the USB isn't
   plugged into the laptop.

The disk stays locked between backups; the laptop sends the unlock key each
time. The laptop's SSH key can only reach a small gatekeeper (`pi/oma-gate`)
that unlocks this one disk and writes backups to it, nothing else on the Pi.
The home page shows the disk's free space as of the last backup.
Full restores still need the USB brought back and booted.

After updating OmaBackups, update the Pi's gatekeeper too (keeps the pairing):

```bash
curl -fsSL https://raw.githubusercontent.com/MattsMacsGit/oma-backups-tm/main/pi/pi-setup.sh | sudo bash -s -- --update
```

Unpairing (`oma-backups remote forget`) removes the Pi connection but keeps the
laptop's unlock key, which automatic backups to the USB still use. To clean up
the Pi, run the same script there with `--uninstall`.

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

- **Home:** last copy, disk free space, Backup now / Stop, next automatic
  backup, last 5 restore points (click to open), **More**, gear
- **Settings:** automatic backups, Smart thinning, quick skips, skip list, show
  all disks, back up to a Pi, use a different disk, erase / start over

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
oma-backups prune [--dry-run]
oma-backups schedule enable | disable | status
oma-backups snapshots
oma-backups browse SNAPSHOT
oma-backups remote pair HOST | status | forget
oma-backups link [--refresh]
oma-backups doctor
oma-backups version
oma-backups restore-to-disk /dev/TARGET --snapshot TS --dry-run
```

`oma-backups --help` lists everything.

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
