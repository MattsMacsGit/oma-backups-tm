#!/usr/bin/env bash
# Populate or refresh the rescue OS on OMARCHY-LIVE + OMARCHY-EFI.
#
# Rescue is the official Arch Linux ISO (installer environment): working
# console, linux-firmware, iwd/network later. Our scripts live next to
# the ISO files on OMARCHY-LIVE and start via archiso's script= cmdline.
# Sourced or executed. Expects OMARCHY_TM_ROOT. Root required.
set -euo pipefail

if [[ -z ${OMARCHY_TM_ROOT:-} ]]; then
  OMARCHY_TM_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
  export OMARCHY_TM_ROOT
fi
# shellcheck source=lib/common.sh
source "$OMARCHY_TM_ROOT/lib/common.sh"

ARCH_ISO_URL="${OMARCHY_TM_ARCH_ISO_URL:-https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso}"
ARCH_ISO_SUMS_URL="${OMARCHY_TM_ARCH_ISO_SUMS_URL:-https://geo.mirror.pkgbuild.com/iso/latest/sha256sums.txt}"

# common.sh uses umask 077 for secrets; rescue files on LIVE/EFI must be readable.
rescue_umask() { umask 022; }

arch_iso_cache_path() {
  if [[ -n ${OMARCHY_TM_ISO:-} && -f ${OMARCHY_TM_ISO} ]]; then
    printf '%s\n' "$OMARCHY_TM_ISO"
    return 0
  fi
  local p
  for p in \
    /var/cache/oma-backups/archlinux-x86_64.iso \
    "${OMARCHY_TM_USER_HOME:-$HOME}/.cache/oma-backups/archlinux-x86_64.iso" \
    "$OMARCHY_TM_ROOT/.cache/archlinux-x86_64.iso"
  do
    if [[ -f $p ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  printf '%s\n' "${OMARCHY_TM_USER_HOME:-$HOME}/.cache/oma-backups/archlinux-x86_64.iso"
}

ensure_arch_iso() {
  local iso dest dir sums want got
  ensure_deps curl
  iso="$(arch_iso_cache_path)"
  if [[ -f $iso && -s $iso ]]; then
    printf '%s\n' "$iso"
    return 0
  fi
  dest="${OMARCHY_TM_USER_HOME:-$HOME}/.cache/oma-backups/archlinux-x86_64.iso"
  if [[ ${EUID:-$(id -u)} -eq 0 && ! -w $(dirname "$dest") ]]; then
    dest=/var/cache/oma-backups/archlinux-x86_64.iso
  fi
  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  log "downloading official Arch ISO to $dest" >&2
  curl -fL --retry 5 --retry-all-errors -C - -o "$dest.part" "$ARCH_ISO_URL"
  mv "$dest.part" "$dest"
  if curl -fsSL -o "$dir/sha256sums.txt" "$ARCH_ISO_SUMS_URL"; then
    want="$(awk '/archlinux-x86_64.iso$/{print $1; exit}' "$dir/sha256sums.txt" || true)"
    if [[ -n $want ]]; then
      got="$(sha256sum "$dest" | awk '{print $1}')"
      [[ $got == "$want" ]] || die "Arch ISO checksum mismatch (got $got want $want)"
      log "Arch ISO checksum ok" >&2
    fi
  else
    log "WARNING: could not fetch sha256sums.txt — ISO not verified" >&2
  fi
  printf '%s\n' "$dest"
}

extract_arch_iso() {
  local live=$1
  local iso loop
  rescue_umask
  progress set setup 40
  iso="$(ensure_arch_iso | tail -n 1)"
  [[ -f $iso ]] || die "Arch ISO not found ($iso)"
  progress set setup 55
  loop=$(mktemp -d /run/oma-archiso-XXXXXX)
  mount -o loop,ro "$iso" "$loop"
  [[ -d $loop/arch ]] || { umount "$loop"; rmdir "$loop"; die "ISO has no /arch — not an Arch ISO"; }
  mkdir -p "$live/arch"
  rsync -a --delete "$loop/arch/" "$live/arch/"
  umount "$loop"
  rmdir "$loop"
  [[ -d $live/arch/x86_64 || -d $live/arch/boot ]] || die "extracted ISO missing arch/boot or arch/x86_64"
  progress set setup 65
  log "official Arch ISO extracted onto LIVE"
}

install_rescue_extras() {
  local live=$1
  rescue_umask
  mkdir -p "$live/oma-extra"
  # jq is used by the restore engine and is not on the stock Arch ISO.
  local pkg
  pkg="$(ls -1 /var/cache/pacman/pkg/jq-*.pkg.tar.zst 2>/dev/null | tail -1 || true)"
  if [[ -z $pkg ]]; then
    pacman -Sw --noconfirm jq >/dev/null 2>&1 || true
    pkg="$(ls -1 /var/cache/pacman/pkg/jq-*.pkg.tar.zst 2>/dev/null | tail -1 || true)"
  fi
  if [[ -n $pkg && -f $pkg ]]; then
    bsdtar -x -C "$live/oma-extra" -f "$pkg"
  else
    log "WARNING: jq package not available — restore engine needs jq"
  fi
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
  install_rescue_extras "$live"
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
  log "patching Arch live image with restore launcher (this takes a few minutes)"
  progress set setup 68
  unsquashfs -f -d "$work" "$sfs" >/dev/null
  progress set setup 80
  mkdir -p "$work/usr/local/bin" "$work/root"
  cp "$launch" "$work/usr/local/bin/oma-rescue-launch"
  chmod 755 "$work/usr/local/bin/oma-rescue-launch"
  touch "$work/etc/oma-backups-rescue"
  if [[ -f $work/root/.zlogin ]] && grep -q oma-rescue-launch "$work/root/.zlogin"; then
    :
  else
    cat >>"$work/root/.zlogin" <<'Z'

# OmaBackups — start restore wizard on tty1
if [[ -x /usr/local/bin/oma-rescue-launch && $(tty 2>/dev/null) == /dev/tty1 ]]; then
  /usr/local/bin/oma-rescue-launch || true
fi
Z
  fi
  # Signature of the stock ISO no longer matches; do not leave a stale sig.
  rm -f "$live/arch/x86_64/airootfs.sfs.cms.sig"
  local newsfs=/var/tmp/oma-airootfs.sfs.new
  rm -f "$newsfs"
  mksquashfs "$work" "$newsfs" -noappend -comp xz -b 1048576 -Xbcj x86
  progress set setup 92
  mv -f "$newsfs" "$sfs"
  (cd "$live/arch/x86_64" && sha512sum airootfs.sfs >airootfs.sha512)
  rm -rf "$work"
  log "Arch live image patched"
}

install_rescue_kernel() {
  local live=$1 efi=$2
  local src
  rescue_umask
  mkdir -p "$efi"
  rm -f "$efi/amd-ucode.img" "$efi/intel-ucode.img"
  src="$(find "$live/arch/boot" -type f -name 'vmlinuz-linux' 2>/dev/null | head -1 || true)"
  [[ -n $src ]] || die "no vmlinuz-linux on LIVE — extract the Arch ISO first"
  cp "$src" "$efi/vmlinuz-linux"
  src="$(find "$live/arch/boot" -type f -name 'initramfs-linux.img' 2>/dev/null | head -1 || true)"
  [[ -n $src ]] || die "no initramfs-linux.img on LIVE — extract the Arch ISO first"
  cp "$src" "$efi/initramfs-linux.img"
  for src in "$live/arch/boot/amd-ucode.img" "$live/arch/boot/intel-ucode.img"; do
    [[ -f $src ]] && cp "$src" "$efi/"
  done
  log "copied Arch ISO kernel to EFI"
}

install_rescue_limine() {
  local disk=$1 efi=$2
  local ucode=""
  rescue_umask
  [[ -f $efi/amd-ucode.img ]] && ucode+=$'\n    module_path: boot():/amd-ucode.img'
  [[ -f $efi/intel-ucode.img ]] && ucode+=$'\n    module_path: boot():/intel-ucode.img'
  # Official Arch live. script= is archiso automated_script on tty1.
  # Safe entry adds nomodeset if a GPU still blanks the console.
  cat >"$efi/limine.conf" <<'LIM'
timeout: 8
interface_branding: OmaBackups
/OmaBackups Restore
    protocol: linux
    path: boot():/vmlinuz-linux
LIM
  # Append ucode + initramfs + cmdline (variable parts).
  {
    printf '%s\n' "$ucode"
    cat <<LIM
    module_path: boot():/initramfs-linux.img
    cmdline: archisobasedir=arch archisolabel=OMARCHY-LIVE cms_verify=n
/OmaBackups Restore (text console)
    protocol: linux
    path: boot():/vmlinuz-linux
LIM
    printf '%s\n' "$ucode"
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
  if command -v limine-install >/dev/null && [[ -n $disk && -b $disk ]]; then
    limine-install "$disk" || true
  fi
  [[ -f $efi/EFI/BOOT/BOOTX64.EFI ]] || log "WARNING: no BOOTX64.EFI — USB may not UEFI-boot"
  progress set setup 99
}

# Full LIVE+EFI populate used by format-disk and refresh-rescue.
install_archiso_rescue() {
  local live=$1 efi=$2
  rescue_umask
  mkdir -p "$live" "$efi"
  if [[ -d $live/usr && ! -d $live/arch ]]; then
    log "replacing old pacstrap rescue with official Arch ISO"
    find "$live" -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf {} +
  fi
  extract_arch_iso "$live"
  patch_airootfs "$live"
  install_rescue_files "$live" "$efi"
  install_rescue_kernel "$live" "$efi"
  progress set setup 96
}

# Back-compat names used by format-disk.sh / refresh-rescue.sh
pacstrap_rescue() {
  local live=$1
  extract_arch_iso "$live"
}

write_rescue_fstab() {
  # Archiso does not use a LIVE-as-root fstab. Keep a no-op for callers.
  :
}
