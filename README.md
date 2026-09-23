# OmaBackups

**v1.3.2** — Time Machine-style **encrypted backups** for
[Omarchy](https://omarchy.org/).

A USB disk keeps dated copies of your system and your home folder. Click a
date to open that day's files read-only. Boot the same USB, or a small network
stick, to put the whole machine back. The everyday UI is an Omarchy bar plugin,
and there is a CLI for everything it does.

This is **off-box** backup: the copies live on a disk you can unplug, or on a
Raspberry Pi across the room. Snapper + Limine snapshots stay for "undo a bad
update".

> Setting up a disk and restoring onto one both **erase that disk**. Until you
> have booted a restored disk yourself, on hardware you can afford to lose,
> keep another copy of anything you cannot lose.

## What you get

1. **Bar plugin** — disk icon. Backup now, stop, dated restore points, settings.
2. **Encrypted backup USB** — plug in, set it up from the plugin (wipe is explicit).
3. **Automatic backups** — hourly, daily or weekly, with old restore points
   thinned out Time Machine-style.
4. **File history** — click a date to open your home folder as it was, read-only,
   in Files. Copy files out.
5. **No password prompts** for everyday use once the laptop is linked to its disk.
6. **Bare-metal restore** — firmware-boot the USB (Limine: "Rescue Disk").
   Real Omarchy live environment + a restore wizard. Pick what to bring back
   (everything, or just the system and your settings), pick a date, pick a
   disk, type the name and YES.
7. **Restore over the network** — a separate bootable stick restores this
   laptop from the Pi without the backup disk: on your own network, or from
   anywhere over Tailscale.
8. **Optional Raspberry Pi** — keep the USB in an always-on Pi and back up over
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

### If the bar icon goes missing

`omarchy plugin enable oma.backups`, then `omarchy-restart-shell`.

Do **not** run `omarchy refresh shell` — that resets the bar and drops
third-party plugins. Restart is fine; refresh is not.

## Your first backup

Pick the USB in the panel, confirm the erase, and set a password for it. That
password is the disk's own — not your login — and you need it to restore.

Setting up the disk **does not start a backup**. When it finishes, the disk is
ready and empty: go through Settings first (what to skip, how often to back up),
then press **Backup now** when you are ready. The first one copies everything
and takes a while; later ones only copy what changed.

While it runs, the panel shows two bars: the step running now — how much data
of how much, how many files of how many, and how long that step has left — and
underneath, the whole backup, weighted by how much data each step has to move.

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

## No password prompts

Linking happens when you set up a disk. Existing setups get a **Stop asking for
my password** button on the home page. `oma-backups link` asks for sudo once
and:

- adds a root-only unlock key held by this laptop to the backup disk
- installs systemd services for back up now, opening a restore point, and the
  hourly check
- adds a polkit rule letting **only this user**, **only from an active local
  session**, start and stop **only those services** without a password

After that, backing up, stopping, automatic backups and opening restore points
don't ask for a password. Setting up or erasing a disk, and restoring, still do.

The disk stays encrypted. Away from this laptop it's useless without its
password.

## Opening restore points

Click a date on the home page. Your own home folder from that date opens in
Files, **read-only**. Copy what you need out, then press **Done** in the panel
to close it.

## Using a different disk

Settings → **Use a different disk**: pick another USB, confirm the erase, and it
becomes the backup disk. The old disk isn't touched and keeps its restore
points.

The current disk is remembered by its encryption ID, so two backup USBs plugged
in at once never get mixed up. If the disk you set up isn't plugged in and a
different backup USB is, nothing is written to it: backups go to the Pi if you
have one, and otherwise say which disk they were expecting.

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

The Pi section only appears in Settings once the backup disk has a restore
point on it: pairing moves a working backup disk to the Pi, so there has to be
a backup on it first.

The disk stays locked between backups; the laptop sends the unlock key each
time. The laptop's SSH key can only reach a small gatekeeper (`pi/oma-gate`)
that unlocks this one disk and writes backups to it, nothing else on the Pi.
The home page shows the disk's free space as of the last backup.

Restore points on the Pi open in Files the same way, over `sshfs` (slower, and
a notification says it's opening). On the Pi, the folder is served by
`sftp-server -R` inside a `bubblewrap` sandbox that contains nothing else.

When the Pi is on the same network as the laptop, backups go straight to its
local address instead of round through the Tailscale tunnel, which is faster
and leaves the Pi's CPU for the copy. The Pi's addresses are noted at pairing
and refreshed after each backup, so a new DHCP lease sorts itself out. Whatever
address is used, the Pi's key is still checked under the name you paired it as.

After updating OmaBackups, update the Pi's gatekeeper too (keeps the pairing).
Do that from a copy of this same tree, on the Pi. The old curl one-liner
installs main, which can be older than the laptop.

```bash
sudo ./pi/pi-setup.sh --update
```

Unpairing (`oma-backups remote forget`) removes the Pi connection but keeps the
laptop's unlock key, which automatic backups to the USB still use.

**Heat:** a Pi 4 doing a big first backup can sit at 80–85 °C in a cupboard and
throttle, which makes the backup slower still. A heatsink, a fan, or just more
air around it is worth it if your first backup is large.

**Power:** a USB-powered backup drive plugged into a hub the Pi's other drives
share can knock those drives offline for a moment while it spins up. Stop
services that use them (e.g. Docker) before plugging it in, or give the
backup drive its own power.

### Network rescue stick

A USB that restores this laptop from the Pi, without the backup disk: at home,
or from anywhere over Tailscale. Make one and check it boots before you need
it, and keep it somewhere other than the laptop bag, so a lost or stolen laptop
doesn't take it along.

You need:

- a paired Pi with the backup disk plugged in, at least one restore point on
  it, and a linked laptop (the Settings section only shows up once all of
  these are true)
- the Pi's gatekeeper at version 9 or newer (run the `--update` command above)
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

## Restoring

Boot the backup USB (firmware boot menu → Limine: **Rescue Disk**), or the
network rescue stick. Pick a date, then how to restore:

- **Quick System Rescue** (recommended) — Omarchy, your apps and all your
  settings, but not the contents of Documents, Pictures, Videos, Downloads and
  so on. Those folders come back empty, and anything over 100 MB is left for
  later. You're back at a working desktop much sooner and can start working
  right away, then bring your files back with **Restore my files** whenever it
  suits you. Need something sooner? Open the restore point in the plugin and
  copy out just what you need.
- **Full Unattended Restore** — the system and your whole home folder, as it
  was on that date. It takes the longest, but you can walk away.

Then pick a disk, and type the disk name and YES. Restoring **wipes** the disk
you restore onto. When it's done, the wizard offers to restart into the
restored system (take the USB out first) or open a command line.

Restore from a running desktop is expert-only (`--allow-internal`). The
intended path is **booting**.

### Restore my files

After a **Quick System Rescue**, the plugin shows **Restore my files**.
It copies back everything that was left behind, without overwriting anything
you've changed since. Stop it and carry on later if you like. Until your files
are back, the restore point they came from is kept safe from thinning — it's
the only one that still has them.

AI models kept in the system area (Ollama's, in `/var/lib/ollama`) are left on
the backup by a Quick System Rescue too: they're often many gigabytes. **Restore
my files** puts them back first, in a terminal, because that needs your
password. Skip it and your files still come back; the panel then offers **Put
AI models back** for later, and backups stay paused until they are.

### Backups pause until the system is whole again

A system restored with **Quick System Rescue** is missing files that are still in
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

## Uninstall

```bash
~/src/oma-backups/uninstall.sh                  # asks about your settings
~/src/oma-backups/uninstall.sh --purge          # removes them without asking
~/src/oma-backups/uninstall.sh --keep-settings  # keeps them without asking
```

Undoes what `install.sh` set up on this account, and removes the backup
services, the polkit rule and the root-owned copy in `/usr/local/lib/oma-backups`.
Then offers to delete the cloned repo folder too. Never touches any backup USB
disk.

Your settings are the skip list and the rest of `~/.config/omarchy-backups`.
Deleting them is the default, so that reinstalling gives you a genuinely fresh
start rather than quietly bringing back folders you once skipped.

### Removing it from the Pi

If you paired a Raspberry Pi, clean that up separately — from a copy of this same tree, **on the Pi**:

```bash
sudo ./pi/pi-setup.sh --uninstall
```

It locks the backup disk, deletes the `omabackups` account and its home, and
removes the gatekeeper, its config and its sudoers rule. `btrfs-progs` and
`cryptsetup` are left installed. The backup disk itself is untouched — it
keeps its restore points, and you can plug it back into a laptop and use it.

## Safety

- USB disks only, unless **Show all disks** (Settings)
- Live root is never a format/restore target
- Wiping requires an explicit erase confirm
- The disk is checked again, immediately before it is wiped, to make sure it is
  still the disk you picked
- Ventoy / Clonezilla sticks stay hidden unless you show all disks
- A disk that already has backups is **used as-is** until you explicitly start over
- Disks that already hold something — a backup disk, a rescue stick, a system —
  say so in every list they appear in. They are never hidden: it is your disk
- While the backup disk is mounted, its folders are readable by everyone on
  this computer, which is what lets restore points open in Files as you. On a
  machine with other accounts on it, that is worth knowing. The disk itself
  stays encrypted, and it is locked again between backups

## How a backup works

Omarchy is LUKS + btrfs `@` / `@home`. Each backup:

1. Freeze with `btrfs subvolume snapshot -r`
2. Work out the size of the job, so the progress bars mean something
3. `rsync -aHAX --delete --delete-excluded` onto the USB (skip list applied every time)
4. Snapshot the destination so you can browse dated copies

## UI

- **Home:** last copy, disk free space, Backup now / Stop, next automatic
  backup, last 5 restore points (click to open), **More**, gear. While a backup
  runs: a bar for the step and a bar for the whole run. After a part restore it
  also shows **Restore my files**, and Backup now is greyed out until your
  files are back.
- **Settings:** automatic backups, Smart thinning, quick skips, skip list, show
  all disks, back up to a Pi, network rescue stick, use a different disk,
  erase / start over

Skip list: `~/.config/omarchy-backups/skip-paths.txt`. Nothing of yours is
skipped to begin with; the recommended quick-skips (Trash, caches, thumbnails)
are switches you can turn off like any other. Compiled into rsync excludes at
the start of **every** backup.

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
oma-backups open TIMESTAMP    # open one restore point read-only in Files
oma-backups remote pair HOST | status | forget
oma-backups rescue-stick /dev/sdX
oma-backups link [--refresh]
oma-backups doctor
oma-backups version
oma-backups restore-to-disk /dev/TARGET --snapshot TS --dry-run
oma-backups restore-to-disk /dev/TARGET --snapshot TS --level settings
```

`oma-backups --help` lists everything.

## Backup USB layout

| Partition | Size | Filesystem | Role |
|---|---|---|---|
| `OMABOOT` | 1G | FAT32 | Limine + Omarchy ISO kernel |
| `OmaRescue` | 16G | ext4 | Real Omarchy ISO (`arch/`) + restore scripts |
| LUKS → `OmaBackups` | rest | btrfs zstd | `os/`, `home/`, `esp/`, `meta/` |

The network rescue stick is `OMANETBOOT` / `OmaNetRescue` / LUKS →
`OmaNetKeys`.

Disks made before v1.1 are labelled `OMARCHY-EFI` / `OMARCHY-LIVE` /
`OMARCHY-TM` (and `OMANET-*`). Both sets are recognised, so an older disk
keeps working exactly as it did — nothing is relabelled behind your back.

None of these partitions are mounted by the desktop when you plug them in: a
udev rule installed by `oma-backups link` turns off auto-mounting, so no
windows pop up. The tool mounts what it needs itself. The boot and key
partitions are hidden from the file manager entirely.

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

The folders keep the older `omarchy-backups` spelling. Renaming them would
mean migrating existing installs, which is not worth the risk.

## Working on it

After editing the plugin's QML, `omarchy-shell shell rescanPlugins` is often
not enough — use `omarchy-restart-shell`.

`share/selftest.sh` runs the unprivileged checks. It never formats or restores.

## License

MIT. See `LICENSE`.
