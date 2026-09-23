#!/usr/bin/env bash
# Populate or refresh the rescue OS on the rescue + boot partitions.
#
# Rescue is the real Omarchy installer ISO — same archiso layout as a
# plain Arch ISO (arch/x86_64/airootfs.sfs etc.), so extraction/patching
# work the same way, but it already ships gum, binutils, btrfs-progs,
# cryptsetup, jq, rsync and everything else our tooling needs, and
# restoring a machine boots into something that actually looks like
# Omarchy. Our scripts live next to the ISO files on the rescue partition and
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

# Oldest Omarchy release this rescue flow is built/tested against (real
# archiso layout, gum/binutils/jq etc already in the package set — see
# the file header). An older ISO a user still happens to have lying
# around in Downloads is not safe to assume compatible; bump this only
# if a verified-working older version turns up, never lower it to make
# an error go away.
OMARCHY_ISO_MIN_VERSION="4.0"

# Version comes from the filename (official releases are always
# omarchy-X.Y.Z-N.iso) — cheap, no need to mount anything just to check.
# Empty if the filename doesn't match that pattern at all.
omarchy_iso_version_of() {
  local base
  base="$(basename "$1")"
  if [[ $base =~ omarchy-([0-9]+(\.[0-9]+)*) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
  # Always exit 0: called as `ver="$(omarchy_iso_version_of "$p")"`, an
  # unprotected assignment under this file's `set -e` — a non-match
  # here must mean "unknown version" (empty string), never abort the
  # whole script.
  return 0
}

omarchy_iso_version_ok() {
  local ver=$1
  [[ -n $ver ]] || return 1
  local lowest
  lowest="$(printf '%s\n%s\n' "$ver" "$OMARCHY_ISO_MIN_VERSION" | sort -V | head -1)"
  [[ $lowest == "$OMARCHY_ISO_MIN_VERSION" ]]
}

# omarchy_iso_path() communicates via these two globals, not stdout+exit
# code — it's called as a plain statement (never `x="$(omarchy_iso_path)"`),
# because a command-substitution caller runs it in a subshell, and these
# globals would then be invisible to the caller the instant that subshell
# exits (a real bug caught by testing: OMARCHY_ISO_REJECTED always came
# back empty when called the $(...) way, even though the function set it
# correctly — right value, wrong shell).
OMARCHY_ISO_FOUND=""
# "path:version" for the first candidate that existed but didn't meet
# OMARCHY_ISO_MIN_VERSION, so ensure_omarchy_iso can say "found X but
# it's too old" instead of a generic "nothing found" when the user does
# have an ISO, just not a new enough one.
OMARCHY_ISO_REJECTED=""

# Where a real Omarchy ISO might already be, checked in order. OMARCHY_TM_ISO
# (settable via format-disk.sh --iso) always wins; then anywhere a prior run
# cached one; then the newest-by-version omarchy*.iso sitting in the user's
# own Downloads, since that is where https://omarchy.org/ naturally lands
# one. A candidate below OMARCHY_ISO_MIN_VERSION is skipped, not just
# deprioritized — an old ISO left over from a previous install must never
# silently win just for being the newest *file* present.
omarchy_iso_path() {
  local p ver
  OMARCHY_ISO_FOUND=""
  for p in \
    "${OMARCHY_TM_ISO:-}" \
    /var/cache/oma-backups/omarchy.iso \
    "${OMARCHY_TM_USER_HOME:-$HOME}/.cache/oma-backups/omarchy.iso"
  do
    [[ -n $p && -f $p ]] || continue
    ver="$(omarchy_iso_version_of "$p")"
    if omarchy_iso_version_ok "$ver"; then
      OMARCHY_ISO_FOUND="$p"
      return 0
    fi
    [[ -z $OMARCHY_ISO_REJECTED ]] && OMARCHY_ISO_REJECTED="$p:${ver:-unknown}"
  done
  local downloads="${OMARCHY_TM_USER_HOME:-$HOME}/Downloads"
  if [[ -d $downloads ]]; then
    while IFS= read -r p; do
      [[ -n $p ]] || continue
      ver="$(omarchy_iso_version_of "$p")"
      if omarchy_iso_version_ok "$ver"; then
        OMARCHY_ISO_FOUND="$p"
        return 0
      fi
      [[ -z $OMARCHY_ISO_REJECTED ]] && OMARCHY_ISO_REJECTED="$p:${ver:-unknown}"
    done < <(find "$downloads" -maxdepth 1 -iname 'omarchy*.iso' -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | cut -d' ' -f2-)
  fi
  return 1
}

# Structural sanity check only — we don't know which version the user has,
# so there's no checksum to verify against; just confirm it is really an
# archiso-layout Omarchy ISO before mounting it.
# Reading the table of contents of a ~6 GB ISO is not free, and this used to
# happen twice per setup: once for the early "do we even have an ISO" check,
# then again when it was actually used. Remember the one that passed.
OMARCHY_ISO_VERIFIED=""
omarchy_iso_looks_valid() {
  [[ -n $OMARCHY_ISO_VERIFIED && $1 == "$OMARCHY_ISO_VERIFIED" ]] && return 0
  bsdtar -tf "$1" 2>/dev/null | grep -qx 'arch/x86_64/airootfs.sfs' || return 1
  OMARCHY_ISO_VERIFIED="$1"
}

ensure_omarchy_iso() {
  if omarchy_iso_path && omarchy_iso_looks_valid "$OMARCHY_ISO_FOUND"; then
    printf '%s\n' "$OMARCHY_ISO_FOUND"
    return 0
  fi
  # Everything here goes to stderr on purpose: callers doing a plain
  # `ensure_omarchy_iso >/dev/null` preflight check to fail fast (see
  # format-disk.sh) must not also silence the only explanation the user
  # gets — that happened for real, is why this comment exists, and cost
  # a confusing "just dumped to the terminal" bug report to catch.
  {
    if [[ -n $OMARCHY_ISO_REJECTED ]]; then
      local rej_file=${OMARCHY_ISO_REJECTED%%:*} rej_ver=${OMARCHY_ISO_REJECTED##*:}
      gum style --bold --foreground 3 "Found $(basename "$rej_file") (version $rej_ver), but it's older than $OMARCHY_ISO_MIN_VERSION."
      gum style "This rescue USB needs Omarchy $OMARCHY_ISO_MIN_VERSION or newer."
    else
      gum style --bold --foreground 3 "No Omarchy installer ISO found."
    fi
    echo
    gum style "This rescue USB boots the real Omarchy installer, so restoring a"
    gum style "machine feels like the machine itself — not a bare rescue shell."
    echo
    gum style "Get a current one from $OMARCHY_ISO_INFO_URL, then either:"
    gum style "  • leave it in ~/Downloads (it's picked up automatically) and run this again, or"
    gum style "  • point at it directly: OMARCHY_TM_ISO=/path/to/omarchy.iso oma-backups first-run /dev/sdX"
    gum style "    (or: oma-backups format-disk /dev/sdX --iso /path/to/omarchy.iso)"
    echo
    gum style --foreground 8 "It's yours either way — also just a normal bootable Omarchy USB."
  } >&2
  die "waiting on an Omarchy ISO — run this again once you have one"
}

extract_omarchy_iso() {
  local live=$1
  local iso loop
  rescue_umask
  progress set setup 40
  # Not `iso="$(ensure_omarchy_iso)"`: a command substitution runs in a
  # subshell, so the ISO-verified cache it sets would be thrown away again.
  ensure_omarchy_iso >/dev/null
  iso="$OMARCHY_ISO_FOUND"
  step "Using Omarchy ISO: $(basename "$iso")"
  progress set setup 45
  # Subshell so the cleanup trap belongs to this block alone. A failure during
  # the copy used to leave the ISO still loop-mounted with nothing said about
  # it; a trap in the function itself would replace the caller's (format-disk
  # and rescue-stick both install one).
  (
    loop="$(mktemp -d /run/oma-archiso-XXXXXX)"
    trap 'umount "$loop" 2>/dev/null || umount -l "$loop" 2>/dev/null || true; rmdir "$loop" 2>/dev/null || true' EXIT
    mount -o loop,ro "$iso" "$loop"
    [[ -d $loop/arch ]] || die "That file is not an Omarchy installer ISO (there is no arch/ folder inside it)."
    step "Extracting the Omarchy live system (the big one — it's ~6GB)"
    # No progress output on this one (plain rsync, no --info=progress2), so
    # say up front that silence is expected: on a slow USB stick this single
    # step is 10-15 minutes and people reasonably think it has hung.
    step "This step shows no progress and can take 10-15 minutes on a slower USB stick. That is normal — please be patient and leave it running."
    rsync -a --delete "$loop/arch/" "$live/arch/"
  )
  [[ -d $live/arch/x86_64 || -d $live/arch/boot ]] || die "extracted ISO missing arch/boot or arch/x86_64"
  progress set setup 65
  step "Omarchy live system extracted"
}

install_rescue_files() {
  local live=$1 efi=$2
  rescue_umask
  mkdir -p "$live/oma-backups" "$efi"
  # The two excludes at the end are not about what to copy — nothing in the
  # repo matches them — but about what --delete must leave alone. Both are
  # written onto the stick after this runs and exist nowhere else:
  # network-rescue.json is the only thing that makes a stick restore from the
  # Pi (restore_tui reads it for --from-pi), and etc-omarchy-backups holds the
  # config this machine was set up with. A full build writes them afterwards
  # so never noticed; a refresh would have quietly turned a network stick into
  # one that hunts for a backup disk that isn't there.
  rsync -a --delete \
    --exclude '.git/' \
    --exclude '.claude-notes/' \
    --exclude '.cache/' \
    --exclude 'plugin/omarchy.omabackups/' \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    --exclude 'network-rescue.json' \
    --exclude 'etc-omarchy-backups/' \
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
# it mounts the rescue partition by label and starts the wizard. Does not need
# /run/archiso/bootmnt to still be there (that is what failed last boot).
patch_airootfs() {
  local live=$1
  local sfs="$live/arch/x86_64/airootfs.sfs"
  local launch
  [[ -f $sfs ]] || die "missing $sfs"
  ensure_deps unsquashfs mksquashfs
  rescue_umask
  launch="$OMARCHY_TM_ROOT/share/oma-rescue-launch.sh"
  [[ -f $launch ]] || die "missing $launch"
  # Subshell with its own cleanup trap: this unpacks and repacks ~6-10 GB in
  # /var/tmp, and a failure in the repack (the slow, most interruptible step)
  # used to leave every byte of it behind without a word, so a second failed
  # attempt quietly added another copy.
  (
  ok=0
  work="$(mktemp -d /var/tmp/oma-airoot.XXXXXX)"
  newsfs="$(mktemp /var/tmp/oma-airootfs.XXXXXX.sfs)"
  cleanup_airoot() {
    local mb=0
    if ((ok == 0)) && [[ -d $work ]]; then
      mb="$(du -sm "$work" 2>/dev/null | awk '{print $1+0}')"
    fi
    rm -rf "$work" "$newsfs"
    ((mb > 100)) && warn "Cleaned up ${mb} MB of half-built rescue image from /var/tmp."
    return 0
  }
  trap cleanup_airoot EXIT
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
  mksquashfs "$work" "$newsfs" -noappend -comp xz -b 1048576 -Xbcj x86
  progress set setup 92
  mv -f "$newsfs" "$sfs"
  (cd "$live/arch/x86_64" && sha512sum airootfs.sfs >airootfs.sha512)
  ok=1
  )
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

# LABEL/TITLE default to the backup disk's; a network rescue stick passes its own.
install_rescue_limine() {
  local disk=$1 efi=$2 live_label=${3:-OmaRescue} title=${4:-Rescue Disk}
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
  # One entry, not two: this USB only ever does one job (the text restore
  # wizard), so a separate "text console" fallback entry offered nothing
  # that always-on nomodeset doesn't already cover — nomodeset is harmless
  # for a plain text console and removes a choice that was really just an
  # internal compatibility fallback, not a real decision for the user to
  # make. One entry, named "Rescue Disk".
  {
    cat <<LIM
timeout: 8
interface_branding: OmaBackups
/$title
    protocol: linux
    path: boot():/vmlinuz-linux
LIM
    ((${#ucode_lines[@]})) && printf '%s\n' "${ucode_lines[@]}"
    cat <<LIM
    module_path: boot():/initramfs-linux.img
    cmdline: archisobasedir=arch archisolabel=$live_label nomodeset cms_verify=n
LIM
  } >"$efi/limine.conf"

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
