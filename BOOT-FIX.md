# Restored disk: splash, then no LUKS prompt

## Symptom

Firmware and Limine see the disk. Omarchy splash appears, then either:

- no LUKS prompt, or
- `Failed to mount '/dev/mapper/root' on real root` and an initramfs shell

Same bug: the kernel/UKI is waiting on the **source** machine’s LUKS PARTUUID,
which is not on the restored disk, so `/dev/mapper/root` never appears.

`/etc/fstab` and `/etc/default/limine` can look correct. Those files are only
read **after** unlock. Boot uses the ESP:

- `EFI/Linux/omarchy_linux.efi` (UKI `.cmdline` section)
- `limine.conf` `cmdline:`

`restore-to-disk` rsyncs the backup ESP (old UKI), rewrites `/etc/default/limine`,
then `limine-mkinitcpio` often exits 0 **without** rewriting the UKI.

## Check (ESP of the restored disk mounted)

```bash
lsblk -n -o PARTUUID /dev/DISK2          # LUKS partition of the restored disk
strings /path/to/ESP/EFI/Linux/omarchy_linux.efi | grep cryptdevice
grep cmdline: /path/to/ESP/limine.conf
```

Those three PARTUUIDs must be the same.

## What restore does now

After mkinitcpio:

1. `lib/patch_boot_cmdline.py --verify-only` — every `cryptdevice=` in the UKI
   and `limine.conf` must be the **new** PARTUUID
2. If not, dump/update the UKI `.cmdline` with the restored OS’s `objcopy`
   (`arch-chroot`; Arch ISO has no binutils) and rewrite `limine.conf`
3. Drop `limine_history/` (source-machine Snapper UKIs)
4. Verify again; **abort** if it still would not unlock

Hibernation `resume=` / `resume_offset=` are stripped (invalid on a new disk).

A restore is not finished until:

```text
strings $ESP/EFI/Linux/omarchy_linux.efi | grep cryptdevice
```

shows the **new** disk’s PARTUUID.

Boot the default Omarchy entry, not a Snapshots submenu left over from the
source machine.
