#!/usr/bin/env bash
# Unprivileged checks. Never formats or restores.
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CLI="$ROOT/omarchy-backups"
fail=0
ok() { printf 'OK    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }

echo "== OmaBackups selftest =="

"$CLI" detect >/tmp/oma-detect.txt 2>&1 || true
if grep -q SUPPORTED /tmp/oma-detect.txt; then ok "detect SUPPORTED"; else bad "detect not SUPPORTED"; cat /tmp/oma-detect.txt; fi

usb="$("$CLI" disks | awk '{print $1}' | tr '\n' ' ')"
echo "USB disks: $usb"
echo "$usb" | grep -q nvme && bad "nvme shown without --all" || ok "disks USB-only (no nvme)"
echo "$usb" | grep -qi ventoy && bad "Ventoy shown without --all" || ok "Ventoy hidden by default"

all="$("$CLI" disks --all)"
echo "$all" | grep -q nvme || echo "$all" | grep -q nvme0 || true
echo "$all" | grep -E 'nvme|internal' >/dev/null && ok "disks --all lists internal" || bad "disks --all missing internal"
if echo "$all" | grep -qi ventoy; then
  if echo "$all" | grep -i ventoy | grep -qiE 'REFUSE|installer'; then
    ok "Ventoy marked installer/REFUSE"
  else
    bad "Ventoy listed without installer/REFUSE"
  fi
fi

"$CLI" compile-excludes >/tmp/oma-ex.txt
grep -q Videos /tmp/oma-ex.txt && ok "compile-excludes has Videos skip" || echo "(no Videos in skip list — ok if user did not add it)"
grep -q '.cache' /tmp/oma-ex.txt && ok "defaults include .cache" || bad "defaults missing .cache"

"$CLI" status | jq -e 'has("running")' >/dev/null && ok "status JSON" || bad "status JSON"

# restore dry-run must refuse live root
live="$("$CLI" detect --json | jq -r .live_root_disk)"
if "$CLI" --dry-run restore-to-disk "$live" --snapshot 19700101T000000Z >/tmp/oma-restore-live.txt 2>&1; then
  bad "restore-to-disk dry-run on live root should fail"
else
  grep -qi refuse /tmp/oma-restore-live.txt && ok "restore refuses live root" || ok "restore dry-run rejected live root"
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
  if "$CLI" --dry-run restore-to-disk "$nvme" --snapshot 19700101T000000Z >/tmp/oma-restore-nvme.txt 2>&1; then
    bad "restore-to-disk dry-run on nvme should need --allow-internal"
  else
    grep -qiE 'internal|refus' /tmp/oma-restore-nvme.txt && ok "restore refuses nvme without --allow-internal" || {
      cat /tmp/oma-restore-nvme.txt
      bad "nvme refuse message unclear"
    }
  fi
  if "$CLI" --dry-run restore-to-disk "$nvme" --snapshot 19700101T000000Z --allow-internal >/tmp/oma-restore-nvme-allow.txt 2>&1; then
    grep -qi 'ERASES\|Dry-run' /tmp/oma-restore-nvme-allow.txt && ok "restore --allow-internal dry-run prints plan" || ok "restore --allow-internal dry-run exited 0"
  else
    grep -qi 'ERASES\|Dry-run\|not mounted\|VALID' /tmp/oma-restore-nvme-allow.txt && ok "restore --allow-internal dry-run did not write" || {
      cat /tmp/oma-restore-nvme-allow.txt
      bad "unexpected nvme --allow-internal dry-run failure"
    }
  fi
fi

"$CLI" doctor >/tmp/oma-doctor.txt 2>&1 || true
cat /tmp/oma-doctor.txt

python3 -m py_compile "$ROOT/lib/"*.py && ok "python compiles" || bad "python compile"
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
