#!/usr/bin/env bash
# A second shelf add while one runs waits its turn; offscreen, no display or lock.
set -u
. "$(dirname "$0")/../tools/flea-sandbox-guard"
cd "$(dirname "$0")/.." || exit 1

if ! command -v qs >/dev/null; then
    echo "shelf-add-queue.sh: qs is not installed, cannot drive the shelf queue"
    exit 1
fi

# A marked sandbox of its own under the fixture root, so cleanup deletes only what this run owns.
test_root=$(mktemp -d "$FIXTURE_ROOT/flea-shelf-add-queue-XXXXXX") || exit 1
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
cp tests/shelf-add-queue.qml "$test_root/config/shell.qml" || exit 1

# A stub flea that sleeps on every call so the second add overlaps the first.
# The third call fails with one stderr line, so the queued add after a refusal is proved too.
cat > "$test_root/bin/flea" <<'STUB'
#!/bin/bash
d=$(dirname "$0")
n=$(cat "$d/calls" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$d/calls"
echo "$*" >> "$d/args.log"
sleep 0.8
if [ "$n" -eq 3 ]; then
  echo "flea: shelf exploded" >&2
  exit 1
fi
exit 0
STUB
chmod +x "$test_root/bin/flea" || exit 1

output=$(env -u DISPLAY -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
    HOME="$test_root/home" XDG_STATE_HOME="$test_root/state" XDG_RUNTIME_DIR="$test_root/runtime" \
    FLEA_BIN="$test_root/bin/flea" \
    QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=generic QT_FORCE_STDERR_LOGGING=1 \
    timeout 30 qs -p "$test_root/config" 2>&1)
qs_status=$?

# Sample input, one probe line: "  INFO qml: SHELFQUEUE PASS two-queued-adds-report-in-order".
# Sample input, the receipt: "  INFO qml: SHELFQUEUE DONE failures=0".
# The owned termination is the probe's own self-kill (SIGTERM, 143) after its one DONE receipt; a PASS beside any other status is a double's, never a proof.
pass_count=$(printf '%s\n' "$output" | grep -c 'SHELFQUEUE PASS')
fail_count=$(printf '%s\n' "$output" | grep -c 'SHELFQUEUE FAIL')
done_count=$(printf '%s\n' "$output" | grep -c 'SHELFQUEUE DONE')
expected_passes=2
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
    printf 'FAIL a queued shelf add reported out of order, or a refusal stopped the queue\n'
    printf '%s\n' "$output" | grep -aE 'SHELFQUEUE|ERROR|error'
    verdict=1
fi
# The offscreen platform itself says it cannot mask a FloatingWindow; that one line is the platform's, never the queue's.
platform_warning='This plugin does not support setting window masks'
warnings=$(printf '%s\n' "$output" | grep -aE 'TypeError|ReferenceError|WARN|ERROR' | grep -vF "$platform_warning")
if [ -n "$warnings" ]; then
    printf 'FAIL the shelf queue harness logged a warning\n'
    printf '%s\n' "$warnings"
    verdict=1
fi
if [ "$verdict" -ne 0 ]; then
    printf '%s\n' "$output"
    exit 1
fi
printf '%s\n' "$output" | grep -o 'SHELFQUEUE PASS.*'
printf 'SHELFQUEUE STATUS qs_exit=%s done=1\n' "$qs_status"
