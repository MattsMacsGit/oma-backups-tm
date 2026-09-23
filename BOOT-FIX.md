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

After mkinitcpio, `lib/patch_boot_cmdline.py` runs unconditionally and:

1. drops `limine_history/` — the source machine's Snapper UKIs, every one of
   which points at a PARTUUID this disk does not have. Always, even when the
   main entry is already correct
2. checks every `cryptdevice=` in the UKI and `limine.conf` is the **new**
   PARTUUID
3. if not, dumps and updates the UKI `.cmdline` with the restored OS’s
   `objcopy` (`arch-chroot`; the Arch ISO has no binutils) and rewrites
   `limine.conf`
4. verifies again, and **aborts the restore** if the disk still would not unlock

Hibernation `resume=` / `resume_offset=` are stripped (invalid on a new disk).

A restore is not finished until:

```text
strings $ESP/EFI/Linux/omarchy_linux.efi | grep cryptdevice
```

shows the **new** disk’s PARTUUID. That check runs after `limine-install`,
and it is the last write to the UKI and `limine.conf`. The restore also
stops if `EFI/BOOT/BOOTX64.EFI` is missing.

The patched UKI is unsigned. Secure Boot will refuse it until Secure Boot
is off, or the file is signed again. TPM auto-unlock is not restored.
A computer that only does BIOS will not boot this disk: the stick and the
restored disk are UEFI, `EFI/BOOT/BOOTX64.EFI`.

