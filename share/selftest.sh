#!/usr/bin/env bash
# Unprivileged checks. Never formats or restores.
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CLI="$ROOT/omarchy-backups"
# Its own scratch directory, not fixed names in a shared /tmp.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail=0
ok() { printf 'OK    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }

echo "== OmaBackups selftest =="

"$CLI" detect >"$WORK/detect.txt" 2>&1 || true
if grep -q SUPPORTED "$WORK/detect.txt"; then ok "detect SUPPORTED"; else bad "detect not SUPPORTED"; cat "$WORK/detect.txt"; fi

usb="$("$CLI" disks | awk '{print $1}' | tr '\n' ' ')"
echo "USB disks: $usb"
echo "$usb" | grep -q nvme && bad "nvme shown without --all" || ok "disks USB-only (no nvme)"

all="$("$CLI" disks --all)"
echo "$all" | grep -E 'nvme|internal' >/dev/null && ok "disks --all lists internal" || bad "disks --all missing internal"
# A Ventoy stick is the owner's USB: listed with a warning, never refused.
if echo "$all" | grep -qi ventoy; then
  "$CLI" disks | grep -qi ventoy && ok "Ventoy listed by default" || bad "Ventoy hidden from the disk list"
  if echo "$all" | grep -i ventoy | grep -q REFUSE; then
    bad "Ventoy refused"
  else
    echo "$all" | grep -i ventoy | grep -qi 'erasing removes Ventoy' && ok "Ventoy listed with a warning" || bad "Ventoy listed without a warning"
  fi
fi

"$CLI" compile-excludes >"$WORK/ex.txt"
grep -q Videos "$WORK/ex.txt" && ok "compile-excludes has Videos skip" || echo "(no Videos in skip list — ok if user did not add it)"
grep -q '.cache' "$WORK/ex.txt" && ok "defaults include .cache" || bad "defaults missing .cache"

"$CLI" status | jq -e 'has("running")' >/dev/null && ok "status JSON" || bad "status JSON"

# restore dry-run must refuse live root
live="$("$CLI" detect --json | jq -r .live_root_disk)"
if "$CLI" --dry-run restore-to-disk "$live" --snapshot 19700101T000000Z >"$WORK/restore-live.txt" 2>&1; then
  bad "restore-to-disk dry-run on live root should fail"
else
  grep -qi refuse "$WORK/restore-live.txt" && ok "restore refuses live root" || ok "restore dry-run rejected live root"
fi

# nvme without --allow-internal. On a laptop whose only nvme IS the live root
# there is nothing to test here: refusing it is the live-root rule above doing
# its job, not the internal-disk rule, so skip rather than report a failure.
nvme="$(lsblk -dn -o PATH,TRAN | awk '$2=="nvme"{print $1; exit}')"
if [[ -n $nvme && $nvme == "$live" ]]; then
  printf 'SKIP  nvme internal-disk checks (the only nvme here is the live root)\n'
  nvme=""
fi
if [[ -n $nvme ]]; then
  if "$CLI" --dry-run restore-to-disk "$nvme" --snapshot 19700101T000000Z >"$WORK/restore-nvme.txt" 2>&1; then
    bad "restore-to-disk dry-run on nvme should need --allow-internal"
  else
    grep -qiE 'internal|refus' "$WORK/restore-nvme.txt" && ok "restore refuses nvme without --allow-internal" || {
      cat "$WORK/restore-nvme.txt"
      bad "nvme refuse message unclear"
    }
  fi
  if "$CLI" --dry-run restore-to-disk "$nvme" --snapshot 19700101T000000Z --allow-internal >"$WORK/restore-nvme-allow.txt" 2>&1; then
    grep -qi 'ERASES\|Dry-run' "$WORK/restore-nvme-allow.txt" && ok "restore --allow-internal dry-run prints plan" || ok "restore --allow-internal dry-run exited 0"
  else
    grep -qi 'ERASES\|Dry-run\|not mounted\|VALID' "$WORK/restore-nvme-allow.txt" && ok "restore --allow-internal dry-run did not write" || {
      cat "$WORK/restore-nvme-allow.txt"
      bad "unexpected nvme --allow-internal dry-run failure"
    }
  fi
fi

"$CLI" doctor >"$WORK/doctor.txt" 2>&1 || true
cat "$WORK/doctor.txt"

# Byte-code goes to the scratch directory, not next to the source (this is
# what used to leave lib/__pycache__ behind after every run). `python3 -m
# py_compile` has no way to say where to put it — that is the py_compile
# module's own `cfile`, so call it directly rather than through -m.
compiled=1
for py in "$ROOT/lib/"*.py "$ROOT/pi/oma-gate"; do
  python3 -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' \
    "$py" "$WORK/$(basename "$py").pyc" || compiled=0
done
((compiled)) && ok "python compiles" || bad "python compile"
python3 - "$ROOT" <<'PY' && ok "UKI cmdline rewriter maps PARTUUID" || bad "UKI cmdline rewriter"
import sys
sys.path.insert(0, sys.argv[1] + "/lib")
import patch_boot_cmdline as p
old = "cryptdevice=PARTUUID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:root resume= resume_offset=1"
new = p.patch_text(old, "00000000-1111-2222-3333-444444444444")
assert "00000000-1111-2222-3333-444444444444" in new
assert "aaaaaaaa" not in new
assert "resume" not in new
PY

echo
if [[ $fail -eq 0 ]]; then
  echo "selftest passed"
  exit 0
fi
echo "selftest had failures"
exit 1
