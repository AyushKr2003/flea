#!/usr/bin/env bash
# Exercise the real rail drop receiver and a device-blind negative mutant offscreen.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
repo=$PWD
. "$repo/tools/flea-sandbox-guard"
FIXTURE_ROOT="$repo/.superpowers/raildrop"
sandbox_root_ok
mkdir -p "$SANDBOX_ROOT" || exit 1
probe=$(mktemp -d "$SANDBOX_ROOT/probe.XXXXXXXX") || exit 1
: > "$probe/$SANDBOX_MARKER" || exit 1
cleanup() { sandbox_remove "$probe"; }
trap cleanup EXIT
mkdir -p "$probe"/{config,home,state,cache,runtime,undo,fixture/source,fixture/favorite,fixture/usb} || exit 1
chmod 700 "$probe/runtime" "$probe/undo"
for name in a b c; do printf '%s incoming\n' "$name" > "$probe/fixture/source/$name.txt"; done
printf 'occupied\n' > "$probe/fixture/favorite/c.txt"
ln -s "$repo/ui" "$probe/config/flea"
ln -s "$(readlink -f ui/boot/Commons)" "$probe/config/Commons"
ln -s "$(readlink -f ui/boot/Ui)" "$probe/config/Ui"
cp tests/raildrop.qml "$probe/config/shell.qml"
# The caller may name the build under test, as tests/ui-captures-drops.sh does.
bin=${FLEA_BIN:-$repo/target/debug/flea}
run_probe() {
    env -u DISPLAY -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
        HOME="$probe/home" XDG_STATE_HOME="$probe/state" XDG_CACHE_HOME="$probe/cache" XDG_RUNTIME_DIR="$probe/runtime" \
        FLEA_UNDO_DIR="$probe/undo" FLEA_BIN="$bin" RAILDROP_FIXTURE="$probe/fixture" \
        QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=generic QT_QUICK_BACKEND=software QT_FORCE_STDERR_LOGGING=1 \
        timeout 45 dbus-run-session -- qs -p "$probe/config" > "$1" 2>&1
}
run_probe "$probe/healthy.log"
status=$?
warnings=$(grep -E 'TypeError|ReferenceError|Binding loop|ERROR|WARN' "$probe/healthy.log" | grep -vF 'This plugin does not support setting window masks' || true)
# Sample input: "  INFO qml: RAILDROP DONE checks=63 failed=0" proves the full fixture flow ran.
if { [ "$status" -ne 0 ] && [ "$status" -ne 143 ]; } || ! grep -q 'RAILDROP DONE checks=[1-9][0-9]* failed=0$' "$probe/healthy.log" \
    || grep -q 'RAILDROP FAIL' "$probe/healthy.log" || [ -n "$warnings" ]; then
    cat "$probe/healthy.log"
    printf 'FAIL raildrop healthy probe exit=%s\n' "$status"
    exit 1
fi
grep 'RAILDROP ' "$probe/healthy.log"
cmp -s "$probe/fixture/favorite/c.txt" <(printf 'occupied\n') || { echo 'FAIL raildrop collision changed the old file'; exit 1; }
for name in a b c; do cmp -s "$probe/fixture/source/$name.txt" <(printf '%s incoming\n' "$name") || exit 1; done
# The mutant ignores the matched destination device, so the same-device favorite wrongly copies.
cp -a ui "$probe/mutant-ui"
/usr/bin/python3 - "$probe/mutant-ui/js/RailDrop.js" <<'PY'
from pathlib import Path
import sys
# Sample input: the matched destination arm "held && held.path === path ? held.dev : 0".
path = Path(sys.argv[1])
body = path.read_text()
needle = "held && held.path === path ? held.dev : 0"
assert body.count(needle) == 1, "raildrop mutant seam moved"
path.write_text(body.replace(needle, "0"))
PY
[[ -n "$probe" && "$probe" == /* && -f "$probe/$SANDBOX_MARKER" ]] || exit 1
rm -- "$probe/config/flea"
ln -s "$probe/mutant-ui" "$probe/config/flea"
run_probe "$probe/mutant.log"
status=$?
if { [ "$status" -eq 0 ] || [ "$status" -eq 143 ]; } && grep -q 'RAILDROP FAIL source presence follows the chosen verb' "$probe/mutant.log" \
    && grep -q 'RAILDROP DONE checks=[1-9][0-9]* failed=[1-9][0-9]*$' "$probe/mutant.log"; then
    printf 'raildrop: healthy file drops, collision card and undo passed; device-blind mutant rejected\n'
else
    cat "$probe/mutant.log"
    printf 'FAIL raildrop negative mutant did not reach the wrong-source assertion, exit=%s\n' "$status"
    exit 1
fi
