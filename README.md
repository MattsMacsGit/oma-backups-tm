# OmaBackups

**v1.1.0** — restore levels, "Restore my files", and a network rescue stick
that restores from the Pi without the backup disk.

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
   Real Omarchy live environment + a restore wizard. Pick what to bring back
   (everything, or just the system and your settings), pick a date, pick a
   disk, type the name and YES.
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

### Removing it from the Pi

If you paired a Raspberry Pi, clean that up separately — run this **on the Pi**:

```bash
curl -fsSL https://raw.githubusercontent.com/MattsMacsGit/oma-backups-tm/main/pi/pi-setup.sh | sudo bash -s -- --uninstall
```

It locks the backup disk, deletes the `omabackups` account and its home, and
removes the gatekeeper, its config and its sudoers rule. `btrfs-progs` and
`cryptsetup` are left installed. The backup disk itself is untouched — it
keeps its restore points, and you can plug it back into a laptop and use it.

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

## Restoring

Boot the backup USB (firmware boot menu → Limine: **Rescue Disk**). The wizard
asks what to bring back:

- **Everything** — the system and your whole home folder, as it was on that date.
- **System + settings** — Omarchy, your apps and all your settings, but not the
  contents of Documents, Pictures, Videos, Downloads and so on. Those folders
  come back empty, and anything over 100 MB is left for later. It's much
  quicker, and gets you to a working desktop sooner.

Then pick a date, pick a disk, and type the disk name and YES. Restoring
**wipes** the disk you restore onto.

### Restore my files

After a **System + settings** restore, the plugin shows **Restore my files**.
It copies back everything that was left behind, without overwriting anything
you've changed since. Stop it and carry on later if you like. Until your files
are back, the restore point they came from is kept safe from thinning — it's
the only one that still has them.

### Backups pause until the system is whole again

A system restored with **System + settings** is missing files that are still in
the backup. If it backed up in that state, rsync would delete them from the
backup's current copy and turn the gap into a restore point. That matters most
when you restore onto a spare disk and boot it to check it: the restored system
is a faithful clone, so it has the same backup disk, the same Pi and the same
schedule as the machine it came from.

So on a restored system:

- automatic backups don't run, and say so once a day
- **Backup now** is greyed out

Press **Restore my files** and backups start again by themselves. If you meant
to keep only what's on this system — setting up a second machine, say — hold
**Ctrl** and the Backup now button wakes up. It spells out what gets dropped
before anything happens. From a terminal that's
`oma-backups backup --force-after-restore`.

### Sync apps

Pause or quit Nextcloud, Dropbox, Syncthing and friends before restoring, and
start them again once you're happy with the result. A sync client that comes
back with your restored settings starts refilling those folders itself, at the
same time as **Restore my files**, and you end up with two things writing the
same tree.

Restoring an older date over a synced folder needs more care: everything you've
done since looks like a deletion to the sync client, and it may push that up to
the server.

## Using a different disk

Settings → **Use a different disk**: pick another USB, confirm the erase, and it
becomes the backup disk. The old disk isn't touched and keeps its restore
points.

The current disk is remembered by its encryption ID, so two backup USBs plugged
in at once never get mixed up.

## Back up to a Raspberry Pi

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
Full restores still need the USB brought back and booted, unless you have made
a network rescue stick (below).

When the Pi is on the same network as the laptop, backups go straight to its
local address instead of round through the Tailscale tunnel, which is faster
and leaves the Pi's CPU for the copy. The Pi's addresses are noted at pairing
and refreshed after each backup, so a new DHCP lease sorts itself out. Whatever
address is used, the Pi's key is still checked under the name you paired it as.

After updating OmaBackups, update the Pi's gatekeeper too (keeps the pairing):

```bash
curl -fsSL https://raw.githubusercontent.com/MattsMacsGit/oma-backups-tm/main/pi/pi-setup.sh | sudo bash -s -- --update
```

Unpairing (`oma-backups remote forget`) removes the Pi connection but keeps the
laptop's unlock key, which automatic backups to the USB still use. To clean up
the Pi, run the same script there with `--uninstall`.

**Heat:** a Pi 4 doing a big first backup can sit at 80–85 °C in a cupboard and
throttle, which makes the backup slower still. A heatsink, a fan, or just more
air around it is worth it if your first backup is large.

**Power:** a USB-powered backup drive plugged into a hub the Pi's other drives
share can knock those drives offline for a moment while it spins up. Stop
services that use them (e.g. Docker) before plugging it in, or give the
backup drive its own power.

### Network rescue stick (new)

A USB that restores this laptop from the Pi, without the backup disk: at
home, or from anywhere over Tailscale. Proven on hardware both ways, but it is
the newest part of this, so make one and check it boots before you need it. Keep it somewhere other than the laptop
bag, so a lost or stolen laptop doesn't take it along.

You need:

- a paired Pi with the backup disk plugged in, at least one restore point on
  it, and a linked laptop (the Settings section only shows up once all of
  these are true)
- the Pi's gatekeeper at version 7 or newer (run the `--update` command above)
- a USB of 8 GB or bigger, and an Omarchy ISO (the same one the backup disk's
  rescue uses)
- for away-from-home restores: Tailscale already working on the laptop and the
  Pi. The stick carries its own copy of Tailscale; at boot you log in by
  scanning a code with your phone. No Tailscale login is stored on the stick.

Settings → **Network rescue stick**, pick the USB, confirm the erase, and type
the backup disk's password (or `oma-backups rescue-stick /dev/sdX`).

To restore: boot any computer from the stick and type the backup disk's
password. It opens the stick, connects (it offers Wi-Fi if there's no cable),
finds the Pi on your home network or over Tailscale, and sends the password
there to unlock the backup disk. Then it's the usual restore wizard.

What's on the stick: the Omarchy ISO and the restore wizard (not secret), and a
small partition locked with the backup disk's password that holds the Pi's
address and fingerprint and the stick's own SSH key. That key can only unlock,
list, read and lock; it can't write, delete or open anything else on the Pi.
Making a new stick switches off the previous one's key, so if a stick goes
missing, make a new one. If you change the backup disk's password, make a new
stick too: the old one would still open, but couldn't unlock the backup disk.

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
  backup, last 5 restore points (click to open), **More**, gear. After a
  part restore it also shows **Restore my files**, and Backup now is greyed
  out until your files are back.
- **Settings:** automatic backups, Smart thinning, quick skips, skip list, show
  all disks, back up to a Pi, network rescue stick, use a different disk,
  erase / start over

Skip list: `~/.config/omarchy-backups/skip-paths.txt`. Compiled into rsync
excludes at the start of **every** backup.

## CLI

After install, `oma-backups` is on `PATH` (`~/.local/bin`).

```bash
oma-backups detect
oma-backups disks            # USB default
oma-backups disks --all
oma-backups backup --yes
oma-backups backup --force-after-restore   # back up a part-restored system anyway
oma-backups stop
oma-backups prune [--dry-run]
oma-backups schedule enable | disable | status
oma-backups snapshots
oma-backups browse SNAPSHOT
oma-backups remote pair HOST | status | forget
oma-backups rescue-stick /dev/sdX
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
