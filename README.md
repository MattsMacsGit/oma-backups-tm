# OmaBackups

**Time Machine-style encrypted backups for [Omarchy](https://omarchy.org/).**

Plug in a USB disk and OmaBackups keeps dated copies of your whole computer:
the system, your apps, your settings and your files. Open any day's files from
the bar. If the computer dies, boot the backup disk and put everything back,
onto the same machine or a completely different one.

Everything is driven from a disk icon on the Omarchy bar. No config files to
edit, and a command line for everything if you want it.

> Setting up a backup disk and restoring onto a disk both **erase that disk**.
> Until you've restored once yourself, onto hardware you can afford to lose,
> keep another copy of anything you can't lose.

## Features

**Everyday backups**

- **One click, or automatic.** Back up now, or hourly, daily or weekly. After
  the first backup, only what changed is copied.
- **Encrypted.** The backup disk is locked with its own password. Lost or
  stolen, it's useless to anyone else.
- **No password prompts.** Once set up, everyday backups and browsing don't ask.
- **Old copies thinned out for you.** Every copy from the last day, one a day
  for a month, then one a week, and the oldest go first when space runs low.
- **Honest progress.** One step at a time, with a bar that measures what's
  really being copied.
- **Leave things out.** Caches, Trash, Downloads, game libraries, virtual
  machines, AI models, or any folder you pick.
- **Disk health check.** Each night a slice of the backup disk is read back and
  checked, so a failing disk is spotted before you need it.

**Getting things back**

- **File history.** Click a date and that day's home folder opens in Files,
  read-only. Copy out what you need.
- **Whole-machine restore.** Boot the backup disk, pick a date, pick a disk.
  You get your computer back as it was: Omarchy, your apps, your settings.
- **Back to work fast.** *Quick System Rescue* brings back the system and
  settings first, so you're at a working desktop sooner. Your files follow
  with one button when it suits you, and you can choose what to leave behind.
- **Any machine.** A restored disk boots on a different computer, not just the
  one it came from.

**Optional extras**

- **Back up to a Raspberry Pi.** Leave the backup disk in an always-on Pi and
  back up over your home network, or from anywhere over Tailscale. The Pi only
  lets your laptop unlock and write to that one disk.
- **Network rescue stick.** A small USB that restores your computer from the
  Pi, without the backup disk: at home, or from anywhere over Tailscale.

## What you need

- A computer running [Omarchy](https://omarchy.org/)
- A USB disk for backups (it gets erased when you set it up)
- Optional: a Raspberry Pi (Raspberry Pi OS or Debian 12 or newer) and a spare
  USB of 8 GB or more for the network rescue stick

## Install

```bash
git clone https://github.com/MattsMacsGit/oma-backups-tm.git ~/src/oma-backups
cd ~/src/oma-backups
./install.sh
```

A disk icon appears on the bar.

## Getting started

1. Plug in a USB disk and open the **OmaBackups** icon.
2. Pick the disk, confirm the erase, and give it a password. This is the
   disk's own password, not your login. **Write it down**: you need it to
   restore.
3. Go through **Settings**: what to leave out, and how often to back up.
4. Press **Backup now**. The first backup copies everything and takes a while;
   later ones are quick.

## Restoring

**Just a few files:** click a date in the panel, copy what you need out of
Files, and press **Done**.

**The whole computer:** start it from the backup disk (from your computer's
boot menu, pick the USB, then **Rescue Disk**), or from the network rescue
stick. The restore wizard walks you through it: pick a date, pick how much to
bring back, pick the disk to restore onto.

Make sure your rescue options boot *before* you need them.

## Safety

- The disk your computer is running from is never offered for erasing.
- Every other disk is listed, with a warning if it already holds something.
- Erasing always needs you to confirm, and the disk is checked again right
  before it's wiped.
- A disk that already has backups on it is used as it is, never wiped behind
  your back.

## Learn more

The [technical guide](docs/TECHNICAL.md) has the full detail: how backups
work, the Raspberry Pi setup, the network rescue stick, updating, uninstalling,
disk layout and the command line.

## License

MIT. See [LICENSE](LICENSE).
