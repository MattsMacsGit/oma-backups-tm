# Resume on testrig (small Omarchy)

Booted from the **1TB USB card** (2G ESP + LUKS, hostname `testrig`, Omarchy 4.0.1, user `test`). Code is at `~/Work/omarchy-tm`.

## Why this install

| | Size |
|---|---|
| `@` (OS + programs) | ~75G |
| `@home` without Videos | ~5G |
| `@home/test/Videos` | ~572G — **exclude** |

Full send with Videos excluded is ~80G. That is the test. Do not send Videos.

## Disks (names may shuffle after reboot — use labels/models)

| What | How to recognize | Do |
|---|---|---|
| **This OS** | 2G vfat + LUKS ~929G, hostname testrig | Live root. Never format. |
| **Time Capsule dest** | 1.8T Seagate Expansion, FAT32 label `OMABACKUP` (wiped clean) | `format-disk` this into 8G `OMARCHY-ISO` + LUKS `OMARCHY-TM`. |
| **Framework NVMe** | 3.6T `CT4000P3PSSD8` | **NEVER format or restore-to-disk onto this.** Config `safety.refuse_models` includes it. |
| **Ventoy** | labels Ventoy / VTOYEFI | Never touch. Clonezilla + Omarchy ISO live here. |

## After reboot

```bash
cd ~/Work/omarchy-tm
./omarchy-tm detect
# confirm: SUPPORTED, testrig, Videos excluded, CT4000P3PSSD8 REFUSE, OMARCHY-TM candidate
./omarchy-tm backup --dry-run
# then mount the capsule and a real small backup
sudo ./omarchy-tm mount --disk /dev/DISK_WITH_OMARCHY-TM
sudo ./omarchy-tm backup --yes
```

Say in Grok Build: **resume omarchy-tm on testrig** (this file).

## Boot after restore-to-disk

If splash appears and LUKS never does, read **BOOT-FIX.md**. The UKI on the ESP kept the source PARTUUID; fstab looking “right” is not enough. `restore-to-disk.sh` now verifies/patches the UKI before it claims success.

## v1.0 still

Self-bootable restore UKI + Quickshell GUI. This testrig pass is only to prove send → incremental → restore-to-disk --dry-run (and a blank-disk restore if we have a spare) in minutes, not hours.
