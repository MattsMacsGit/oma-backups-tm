#!/usr/bin/env bash
# Populate or refresh the rescue OS on OMARCHY-LIVE + OMARCHY-EFI.
#
# Rescue is the real Omarchy installer ISO — same archiso layout as a
# plain Arch ISO (arch/x86_64/airootfs.sfs etc.), so extraction/patching
# work the same way, but it already ships gum, binutils, btrfs-progs,
# cryptsetup, jq, rsync and everything else our tooling needs, and
# restoring a machine boots into something that actually looks like
# Omarchy. Our scripts live next to the ISO files on OMARCHY-LIVE and
# start via archiso's script= cmdline.
# Sourced or executed. Expects OMARCHY_TM_ROOT. Root required.
set -euo pipefail

if [[ -z ${OMARCHY_TM_ROOT:-} ]]; then
  OMARCHY_TM_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
  export OMARCHY_TM_ROOT
fi
# shellcheck source=lib/common.sh
source "$OMARCHY_TM_ROOT/lib/common.sh"

# Omarchy ISO releases are version-specific filenames (no stable "latest"
# URL to curl), so this never auto-downloads on its own — the user gets
# it from https://omarchy.org/ themselves (or already has a copy). It's
# theirs to keep either way: also just a normal bootable Omarchy USB.
OMARCHY_ISO_INFO_URL="https://omarchy.org/"

# common.sh uses umask 077 for secrets; rescue files on LIVE/EFI must be readable.
rescue_umask() { umask 022; }

# Where a real Omarchy ISO might already be, checked in order. OMARCHY_TM_ISO
# (settable via format-disk.sh --iso) always wins; then anywhere a prior run
# cached one; then the newest omarchy*.iso sitting in the user's own
# Downloads, since that is where https://omarchy.org/ naturally lands one.
omarchy_iso_path() {
  local p
  for p in \
    "${OMARCHY_TM_ISO:-}" \
    /var/cache/oma-backups/omarchy.iso \
    "${OMARCHY_TM_USER_HOME:-$HOME}/.cache/oma-backups/omarchy.iso"
  do
    [[ -n $p && -f $p ]] && { printf '%s\n' "$p"; return 0; }
  done
  local downloads="${OMARCHY_TM_USER_HOME:-$HOME}/Downloads"
  if [[ -d $downloads ]]; then
    p="$(find "$downloads" -maxdepth 1 -iname 'omarchy*.iso' -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | head -1 | cut -d' ' -f2-)"
    [[ -n $p && -f $p ]] && { printf '%s\n' "$p"; return 0; }
  fi
  return 1
}

# Structural sanity check only — we don't know which version the user has,
# so there's no checksum to verify against; just confirm it is really an
# archiso-layout Omarchy ISO before mounting it.
omarchy_iso_looks_valid() {
  bsdtar -tf "$1" 2>/dev/null | grep -qx 'arch/x86_64/airootfs.sfs'
}

ensure_omarchy_iso() {
  local iso
  if iso="$(omarchy_iso_path)" && omarchy_iso_looks_valid "$iso"; then
    printf '%s\n' "$iso"
    return 0
  fi
  gum style --bold --foreground 3 "No Omarchy installer ISO found."
  echo
  gum style "This rescue USB boots the real Omarchy installer, so restoring a"
  gum style "machine feels like the machine itself — not a bare rescue shell."
  echo
  gum style "Get it from $OMARCHY_ISO_INFO_URL, then either:"
  gum style "  • leave it in ~/Downloads (it's picked up automatically), or"
  gum style "  • point at it directly: OMARCHY_TM_ISO=/path/to/omarchy.iso oma-backups first-run /dev/sdX"
  gum style "    (or: oma-backups format-disk /dev/sdX --iso /path/to/omarchy.iso)"
  echo
  gum style --foreground 8 "It's yours either way — also just a normal bootable Omarchy USB."
  die "waiting on an Omarchy ISO — run this again once you have one"
}

extract_omarchy_iso() {
  local live=$1
  local iso loop
  rescue_umask
  progress set setup 40
  iso="$(ensure_omarchy_iso)"
  step "Using Omarchy ISO: $(basename "$iso")"
  progress set setup 45
  loop=$(mktemp -d /run/oma-archiso-XXXXXX)
  mount -o loop,ro "$iso" "$loop"
  [[ -d $loop/arch ]] || { umount "$loop"; rmdir "$loop"; die "ISO has no /arch — not an archiso-layout Omarchy ISO"; }
  step "Extracting the Omarchy live system (this is the big one — it's ~6GB)"
  rsync -a --delete "$loop/arch/" "$live/arch/"
  umount "$loop"
  rmdir "$loop"
  [[ -d $live/arch/x86_64 || -d $live/arch/boot ]] || die "extracted ISO missing arch/boot or arch/x86_64"
  progress set setup 65
  step "Omarchy live system extracted"
}

install_rescue_files() {
  local live=$1 efi=$2
  rescue_umask
  mkdir -p "$live/oma-backups" "$efi"
  rsync -a --delete \
    --exclude '.git/' \
    --exclude '.cache/' \
    --exclude 'plugin/omarchy.omabackups/' \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    "$OMARCHY_TM_ROOT"/ "$live/oma-backups/"
  chmod 755 "$live/oma-backups/share/rescue-run.sh" \
    "$live/oma-backups/share/oma-rescue-launch.sh"
  cp "$OMARCHY_TM_ROOT/share/RESTORE.txt" "$efi/RESTORE.txt"
  if [[ -f /etc/omarchy-backups/config.toml ]]; then
    mkdir -p "$live/oma-backups/etc-omarchy-backups"
    cp /etc/omarchy-backups/config.toml "$live/oma-backups/etc-omarchy-backups/config.toml"
  fi
}

# Official live-CD pattern: tiny launcher inside the squashfs. After login
# it mounts OMARCHY-LIVE by label and starts the wizard. Does not need
# /run/archiso/bootmnt to still be there (that is what failed last boot).
patch_airootfs() {
  local live=$1
  local sfs="$live/arch/x86_64/airootfs.sfs"
  local work launch
  [[ -f $sfs ]] || die "missing $sfs"
  ensure_deps unsquashfs mksquashfs
  rescue_umask
  launch="$OMARCHY_TM_ROOT/share/oma-rescue-launch.sh"
  [[ -f $launch ]] || die "missing $launch"
  work=$(mktemp -d /var/tmp/oma-airoot.XXXXXX)
  step "Patching the rescue image with the restore launcher (the slow part — repacking ~6GB, can take a while)"
  progress set setup 68
  unsquashfs -f -d "$work" "$sfs" >/dev/null
  progress set setup 80
  mkdir -p "$work/usr/local/bin" "$work/root"
  cp "$launch" "$work/usr/local/bin/oma-rescue-launch"
  chmod 755 "$work/usr/local/bin/oma-rescue-launch"
  touch "$work/etc/oma-backups-rescue"
  # Replace outright, don't append: the real Omarchy ISO's own .zlogin
  # ends by calling ~/.automated_script.sh, which launches Omarchy's own
  # interactive OS-install configurator and blocks there — appending
  # after it never actually gets reached, the rescue USB just boots
  # straight into "install a new Omarchy" instead of our restore wizard.
  # This rescue USB only ever does one thing, so it owns tty1 outright.
  # (Keeps Omarchy's own screen-reader accessibility check — harmless
  # and worth preserving.)
  cat >"$work/root/.zlogin" <<'Z'
# fix for screen readers
if grep -Fqa 'accessibility=' /proc/cmdline &> /dev/null; then
    setopt SINGLE_LINE_ZLE
fi

# OmaBackups — start the restore wizard on tty1
if [[ -x /usr/local/bin/oma-rescue-launch && $(tty 2>/dev/null) == /dev/tty1 ]]; then
  /usr/local/bin/oma-rescue-launch || true
fi
Z
  # Signature of the stock ISO no longer matches; do not leave a stale sig.
  rm -f "$live/arch/x86_64/airootfs.sfs.cms.sig"
  local newsfs=/var/tmp/oma-airootfs.sfs.new
  rm -f "$newsfs"
  mksquashfs "$work" "$newsfs" -noappend -comp xz -b 1048576 -Xbcj x86
  progress set setup 92
  mv -f "$newsfs" "$sfs"
  (cd "$live/arch/x86_64" && sha512sum airootfs.sfs >airootfs.sha512)
  rm -rf "$work"
  step "Rescue image patched"
}

install_rescue_kernel() {
  local live=$1 efi=$2
  local src
  rescue_umask
  mkdir -p "$efi"
  rm -f "$efi/amd-ucode.img" "$efi/intel-ucode.img"
  # Omarchy's kernel build is suffixed (e.g. vmlinuz-linux-t2), not the
  # plain "vmlinuz-linux" a stock Arch ISO ships — glob it rather than
  # assuming the exact name. Our own boot config always references the
  # fixed destination names below, so nothing downstream needs to know
  # which variant was actually on the ISO.
  src="$(find "$live/arch/boot" -type f -name 'vmlinuz-linux*' 2>/dev/null | head -1 || true)"
  [[ -n $src ]] || die "no vmlinuz-linux* on LIVE — extract the Omarchy ISO first"
  cp "$src" "$efi/vmlinuz-linux"
  src="$(find "$live/arch/boot" -type f -name 'initramfs-linux*.img' 2>/dev/null | head -1 || true)"
  [[ -n $src ]] || die "no initramfs-linux*.img on LIVE — extract the Omarchy ISO first"
  cp "$src" "$efi/initramfs-linux.img"
  for src in "$live/arch/boot/amd-ucode.img" "$live/arch/boot/intel-ucode.img"; do
    [[ -f $src ]] && cp "$src" "$efi/"
  done
  step "Kernel copied to the boot partition"
}

install_rescue_limine() {
  local disk=$1 efi=$2
  rescue_umask
  # Lines, not a single string with an embedded leading newline — the old
  # "\n    module_path: ..." form always left a stray blank line in the
  # middle of each entry's property block once concatenated after the
  # heredoc above it (visible with `cat -A`; happened even with zero
  # ucode files, since printf '%s\n' "" alone emits a blank line). Whether
  # or not that's what made Limine's own menu show a phantom duplicate,
  # it was malformed config either way.
  local -a ucode_lines=()
  [[ -f $efi/amd-ucode.img ]] && ucode_lines+=("    module_path: boot():/amd-ucode.img")
  [[ -f $efi/intel-ucode.img ]] && ucode_lines+=("    module_path: boot():/intel-ucode.img")
  # Real Omarchy live environment (archiso under the hood). script= is
  # archiso automated_script on tty1. Safe entry adds nomodeset if a GPU
  # still blanks the console.
  cat >"$efi/limine.conf" <<'LIM'
timeout: 8
interface_branding: OmaBackups
/OmaBackups Restore
    protocol: linux
    path: boot():/vmlinuz-linux
LIM
  # Append ucode + initramfs + cmdline (variable parts).
  {
    ((${#ucode_lines[@]})) && printf '%s\n' "${ucode_lines[@]}"
    cat <<LIM
    module_path: boot():/initramfs-linux.img
    cmdline: archisobasedir=arch archisolabel=OMARCHY-LIVE cms_verify=n
/OmaBackups Restore (text console)
    protocol: linux
    path: boot():/vmlinuz-linux
LIM
    ((${#ucode_lines[@]})) && printf '%s\n' "${ucode_lines[@]}"
    cat <<'LIM'
    module_path: boot():/initramfs-linux.img
    cmdline: archisobasedir=arch archisolabel=OMARCHY-LIVE nomodeset cms_verify=n
LIM
  } >>"$efi/limine.conf"

  mkdir -p "$efi/EFI/BOOT" "$efi/EFI/limine"
  local efi_src
  for efi_src in \
    /usr/share/limine/BOOTX64.EFI \
    /usr/share/limine/limine-uefi.efi
  do
    if [[ -f $efi_src ]]; then
      cp "$efi_src" "$efi/EFI/BOOT/BOOTX64.EFI"
      cp "$efi_src" "$efi/EFI/limine/limine-uefi.efi"
      break
    fi
  done
  # limine-install (Omarchy's system tool) manages the *current* system's
  # own bootloader via $ESP_PATH — it has no way to target an arbitrary
  # disk, doesn't take one as an argument, and was never applicable here.
  # We already write everything the USB needs directly, above.
  [[ -f $efi/EFI/BOOT/BOOTX64.EFI ]] || warn "no BOOTX64.EFI — USB may not UEFI-boot"
  progress set setup 99
}

# Full LIVE+EFI populate used by format-disk and refresh-rescue.
install_archiso_rescue() {
  local live=$1 efi=$2
  rescue_umask
  mkdir -p "$live" "$efi"
  if [[ -d $live/usr && ! -d $live/arch ]]; then
    step "Replacing the old rescue image"
    find "$live" -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf {} +
  fi
  extract_omarchy_iso "$live"
  patch_airootfs "$live"
  install_rescue_files "$live" "$efi"
  install_rescue_kernel "$live" "$efi"
  progress set setup 96
}

write_rescue_fstab() {
  # Archiso does not use a LIVE-as-root fstab. Keep a no-op for callers.
  :
}
