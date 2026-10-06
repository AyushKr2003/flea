#!/usr/bin/env bash
# The U1 proof and the unlock threat pins (GM ruling 13): the canary reaches udisksctl unlock on stdin alone, no newline, then EOF.
set -u
. "$(dirname "$0")/../tools/flea-sandbox-guard"
cd "$(dirname "$0")/.." || exit 1

CANARY='S3cr3t-canary-1006'

if ! command -v qs >/dev/null; then
    echo "unlock-stdin.sh: qs is not installed, cannot drive the unlock dialog"
    exit 1
fi

# A marked sandbox of its own under the fixture root, so cleanup deletes only what this run owns.
test_root=$(mktemp -d "$FIXTURE_ROOT/flea-unlock-stdin-XXXXXX") || exit 1
# The allocated path must be absolute and non-empty before the sandbox trusts it.
case $test_root in
  /*/*) ;;
  *) echo "FAIL: mktemp -d gave '$test_root', which is not an absolute path two components deep"; exit 1 ;;
esac
sandbox_require "$test_root" || exit 1
: > "$test_root/$SANDBOX_MARKER" || exit 1
cleanup() { sandbox_remove "$test_root"; }
trap cleanup EXIT

mkdir -p "$test_root/config" "$test_root/home" "$test_root/state" "$test_root/runtime" "$test_root/bin" || exit 1
chmod 700 "$test_root/runtime" || exit 1
# The probe imports ui/ as Flea, and ui/'s qs.Commons resolves against this root, as it does from ui/boot.
ln -s "$PWD/ui" "$test_root/config/flea" || exit 1
ln -s "$(readlink -f ui/boot/Commons)" "$test_root/config/Commons" || exit 1
ln -s "$(readlink -f ui/boot/Ui)" "$test_root/config/Ui" || exit 1
cp tests/unlock-stdin.qml "$test_root/config/shell.qml" || exit 1

# The stub udisksctl: unlock refuses twice, then unlocks; every recorder is a cat that exits only on EOF.
mkdir -p "$test_root/stub" || exit 1
cat > "$test_root/bin/udisksctl" <<EOF
#!/bin/sh
d="$test_root/stub"
n=0
if [ -f "\$d/attempt" ]; then n=\$(cat "\$d/attempt"); fi
printf '%s\n' "\$@" > "\$d/argv\$((n+1))"
env > "\$d/childenv\$((n+1))"
case "\$1" in
  unlock)
    n=\$((n+1)); printf '%s' "\$n" > "\$d/attempt"
    tr '\0' ' ' < "/proc/\$\$/cmdline" > "\$d/cmdself\$n"
    tr '\0' '\n' < "/proc/\$\$/environ" > "\$d/envself\$n"
    tr '\0' ' ' < "/proc/\$PPID/cmdline" > "\$d/cmdparent\$n"
    cat > "\$d/stdin\$n"
    if [ "\$n" -eq 1 ]; then
      echo "Fehler beim Entsperren von /dev/sdb1: GDBus.Error:org.freedesktop.UDisks2.Error.Failed: Fehler beim Aktivieren des Geräts: Operation nicht erlaubt" >&2
      exit 1
    fi
    if [ "\$n" -eq 2 ]; then
      echo "Fehler: GDBus.Error:org.freedesktop.UDisks2.Error.NotAuthorized: Legitimierung wurde abgebrochen" >&2
      exit 1
    fi
    echo "Unlocked /dev/sdb1 as /dev/dm-0."
    ;;
  mount) echo "Mounted /dev/dm-0 at /run/media/gm/Backup." ;;
  lock) exit 0 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$test_root/bin/udisksctl" || exit 1

output=$(env -u DISPLAY -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
    HOME="$test_root/home" XDG_STATE_HOME="$test_root/state" XDG_RUNTIME_DIR="$test_root/runtime" \
    PATH="$test_root/bin:$PATH" \
    QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=generic QT_FORCE_STDERR_LOGGING=1 \
    timeout 90 qs -p "$test_root/config" 2>&1)
qs_status=$?

# Sample input, a probe line "  INFO qml: UNLOCKSTDIN PASS retry-unlocks-and-mounts", then the receipt "UNLOCKSTDIN DONE failures=0".
pass_count=$(printf '%s\n' "$output" | grep -c 'UNLOCKSTDIN PASS')
fail_count=$(printf '%s\n' "$output" | grep -c 'UNLOCKSTDIN FAIL')
done_count=$(printf '%s\n' "$output" | grep -c 'UNLOCKSTDIN DONE')
expected_passes=11
verdict=0
if [ "$qs_status" -ne 143 ]; then
    printf 'FAIL qs exited %s, want the owned self-kill 143 after DONE\n' "$qs_status"
    verdict=1
fi
if [ "$done_count" -ne 1 ]; then
    printf 'FAIL completion receipts %s, want exactly 1 DONE beside the PASS\n' "$done_count"
    verdict=1
fi
if [ "$pass_count" -ne "$expected_passes" ] || [ "$fail_count" -ne 0 ]; then
    printf 'FAIL want %s PASS and 0 FAIL, got %s PASS and %s FAIL\n' "$expected_passes" "$pass_count" "$fail_count"
    verdict=1
fi
# S3: the bytes. The secret alone, no trailing newline, on all three attempts.
for n in 1 2 3; do
    if ! printf '%s' "$CANARY" | cmp -s - "$test_root/stub/stdin$n"; then
        printf 'FAIL attempt %s did not write exactly the secret with no newline\n' "$n"
        verdict=1
    fi
done
# S1: the secret never reaches argv; the unlock line names the device and the key file only.
for f in "$test_root"/stub/argv*; do
    if grep -qF "$CANARY" "$f"; then
        printf 'FAIL the passphrase reached argv in %s\n' "$f"
        verdict=1
    fi
done
grep -q -- '--key-file' "$test_root/stub/argv1" || { printf 'FAIL the unlock argv names no key file\n'; verdict=1; }
grep -q -- '/dev/sdb1' "$test_root/stub/argv1" || { printf 'FAIL the unlock argv names no device\n'; verdict=1; }
# S1+S2: the waiting child's cmdline and environ and its parent's cmdline carry no secret bytes.
for f in "$test_root"/stub/cmdself* "$test_root"/stub/envself* "$test_root"/stub/cmdparent* "$test_root"/stub/childenv*; do
    if grep -qF "$CANARY" "$f"; then
        printf 'FAIL the canary reached %s\n' "$f"
        verdict=1
    fi
done
[ -f "$test_root/stub/cmdself1" ] || { printf 'FAIL no live child dump was recorded\n'; verdict=1; }
# The child runs under LC_ALL=C, so udisksctl's own wording is deterministic.
grep -q '^LC_ALL=C$' "$test_root/stub/childenv1" || { printf 'FAIL the unlock child ran without LC_ALL=C\n'; verdict=1; }
# S4: every log the flow writes. The qs log carries no canary bytes.
if printf '%s\n' "$output" | grep -qF "$CANARY"; then
    printf 'FAIL the canary reached the qs log\n'
    verdict=1
fi
# S5: no Ipc.qml reader names the field, the secret holder or the passphrase.
for word in passphrase Passphrase _secret "field.text"; do
    if grep -qF "$word" ui/Ipc.qml; then
        printf 'FAIL ui/Ipc.qml names %s\n' "$word"
        verdict=1
    fi
done
# S7: no file written; the rig's own shell.qml types the canary, so the grep is proved against it as the control.
if [ "$(grep -rFl "$CANARY" "$test_root/config" | wc -l)" -eq 0 ]; then
    printf 'FAIL the control grep found no canary in the rig shell.qml\n'
    verdict=1
fi
if grep -rF "$CANARY" "$test_root/home" "$test_root/state" "$test_root/runtime" 2>/dev/null; then
    printf 'FAIL the canary reached a product-written file\n'
    verdict=1
fi
# The offscreen platform itself says it cannot mask a FloatingWindow; that one line is the platform's, never the dialog's.
platform_warning='This plugin does not support setting window masks'
warnings=$(printf '%s\n' "$output" | grep -aE 'TypeError|ReferenceError|WARN|ERROR' | grep -vF "$platform_warning")
if [ -n "$warnings" ]; then
    printf 'FAIL the unlock harness logged a warning\n'
    printf '%s\n' "$warnings"
    verdict=1
fi
if [ "$verdict" -ne 0 ]; then
    printf '%s\n' "$output"
    exit 1
fi
printf '%s\n' "$output" | grep -o 'UNLOCKSTDIN PASS.*'
printf 'UNLOCKSTDIN STATUS qs_exit=%s done=1\n' "$qs_status"
