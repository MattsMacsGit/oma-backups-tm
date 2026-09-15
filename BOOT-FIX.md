# Restored disk boots splash then never unlocks LUKS

## Symptom

Firmware and Limine see the disk. Omarchy splash appears, then either:

- no LUKS prompt at all, or
- `Failed to mount '/dev/mapper/root' on real root` and an initramfs shell

This is the **same bug**. The kernel/UKI is waiting on the *source* machine’s LUKS PARTUUID, which is not on the restored card, so `/dev/mapper/root` never appears.

`/etc/fstab` and `/etc/default/limine` can look correct. Those files are only read **after** unlock. Boot uses the ESP:

- `EFI/Linux/omarchy_linux.efi` (UKI `.cmdline` section)
- `limine.conf` `cmdline:`

`restore-to-disk` rsyncs the backup ESP (old UKI, dated at backup time), rewrites `/etc/default/limine`, then `limine-mkinitcpio` often does **not** rewrite the UKI. Result: splash from the old UKI, hang.

## Check (from a running machine with the restored ESP mounted)

```bash
lsblk -n -o PARTUUID /dev/sdX2          # LUKS partition of the restored disk
strings /path/to/ESP/EFI/Linux/omarchy_linux.efi | grep cryptdevice
grep cmdline: /path/to/ESP/limine.conf
```

Those three PARTUUIDs must match. On the 1TB restore they did not:

| Place | PARTUUID |
|---|---|
| Disk `sdb2` | `7e0a055c-ad29-401c-a984-672de32f8db3` |
| `/etc/default/limine` (after unlock) | `7e0a055c-…` (rewritten, unused at boot) |
| UKI + `limine.conf` | `e9ffc778-…` (original testrig) |

## Manual fix already applied on this card (15 Sep)

1. `objcopy --update-section=.cmdline=…` on `EFI/Linux/omarchy_linux.efi`
2. Same `cryptdevice=PARTUUID=7e0a055c-…:root` in `limine.conf`
3. Stripped `resume=` / `resume_offset=` (invalid on a new disk; can hang initramfs)
4. Removed the Limine `#hash` on the UKI path so the edited file is not rejected

Backups next to the files:

- `EFI/Linux/omarchy_linux.efi.bak-pre-partuuid-fix`
- `limine.conf.bak-pre-partuuid-fix`

**Boot the default Omarchy / linux entry. Do not pick Snapshots** — that submenu still points at a copy of the old UKI under `limine_history/`.

## What `restore-to-disk.sh` does now

After mkinitcpio (which can exit 0 **without** rewriting the UKI):

1. `lib/patch_boot_cmdline.py --verify-only` — every `cryptdevice=` in the UKI and `limine.conf` must be the **new** PARTUUID
2. If not, dump/update the UKI `.cmdline` with **the restored OS’s** `objcopy` (`arch-chroot`; the Arch ISO has no binutils) and rewrite `limine.conf`
3. Drop `limine_history/` (source-machine Snapper UKIs)
4. Verify again; **abort the restore** if it still would not unlock

Also: do not write empty `resume=`. Clear `etc/limine-entry-tool.d/resume.conf` on the restored `@`.

A restore is not finished until:

```text
strings $ESP/EFI/Linux/omarchy_linux.efi | grep cryptdevice
```

shows the **new** disk’s PARTUUID.

## Retry

Unplug/replug if the ESP is still mounted on another machine, then firmware-boot the 1TB card. You should get the LUKS prompt after splash. Unlock with the passphrase set during restore.
