# OmaBackups has moved

OmaBackups 2.0 lives here now: **https://github.com/MattsMacsGit/omabackups**

Live incremental backups while you work, a Rescue USB that brings the whole
computer back, and Migrate onto a fresh Omarchy.

This repo (1.x) is no longer updated and will be removed soon. A 1.x already
installed keeps working until you move over: nothing here is downloaded
while it runs.

## Moving from 1.x to 2.0

On Omarchy, in a terminal.

**1. Remove 1.x**

```
~/.local/share/oma-backups/uninstall.sh --purge
```

It asks for your computer's password once (to remove its timer and system
files). When it asks to delete the source folder, say Yes unless you want to
keep that copy of 1.x. `--purge` also deletes 1.x's settings.

**2. Install 2.0**

```
git clone https://github.com/MattsMacsGit/omabackups
```

```
omabackups/packaging/install-edge.sh
```

Then click the OmaBackups icon on the bar (a clock turning back) and set up
backups. Everything else is in
[the 2.0 guide](https://github.com/MattsMacsGit/omabackups/blob/main/docs/GUIDE.md).

**Your 1.x backups** stay where they are: removing 1.x doesn't touch the
backup disk or the backup server, and they still open with 1.x's backup
password. 2.0 starts a backup of its own. Keep the old one until 2.0's first
backup has finished.
