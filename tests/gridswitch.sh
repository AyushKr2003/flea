#!/usr/bin/env bash
# A switch to Grid builds only the viewport's tiles before its first frame and the cache rows after it, and no frame draws a half-built Grid, offscreen with the real backend.
set -u
. "$(dirname "$0")/../tools/flea-sandbox-guard"
cd "$(dirname "$0")/.." || exit 1
command -v qs >/dev/null || { echo 'FAIL gridswitch: qs is missing'; exit 1; }
root=$(mktemp -d "$FIXTURE_ROOT/gridswitch-XXXXXXXX") || exit 1
sandbox_require "$root" || exit 1
: > "$root/$SANDBOX_MARKER" || exit 1
trap 'sandbox_remove "$root"' EXIT
mkdir -p "$root/config" "$root/fixture" "$root/run/home" "$root/run/state/flea" "$root/run/cache" "$root/run/runtime" || exit 1
chmod 700 "$root/run/runtime" || exit 1
ln -s "$PWD/ui" "$root/config/flea" || exit 1
ln -s "$(readlink -f ui/boot/Commons)" "$root/config/Commons" || exit 1
ln -s "$(readlink -f ui/boot/Ui)" "$root/config/Ui" || exit 1
cp tests/gridswitch.qml "$root/config/shell.qml" || exit 1
# Two hundred files fill the Grid's viewport and its cache rows and leave rows to spare.
for i in $(seq -w 1 200); do printf 'row %s\n' "$i" > "$root/fixture/file-$i.txt"; done
printf '{"updates":{"autoCheck":false},"view":"list"}\n' > "$root/run/state/flea/ui.json" || exit 1
env -u DISPLAY -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
    HOME="$root/run/home" XDG_STATE_HOME="$root/run/state" XDG_CACHE_HOME="$root/run/cache" XDG_RUNTIME_DIR="$root/run/runtime" \
    FLEA_BIN="$PWD/target/debug/flea" FLEA_GS_DIR="$root/fixture" FLEA_GS_ENTRIES=200 \
    QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=generic QT_FORCE_STDERR_LOGGING=1 \
    timeout 60 qs -p "$root/config" > "$root/probe.log" 2>&1
status=$?
grep -a 'GRIDSWITCH' "$root/probe.log" | tail -n 40
failed=0
[ "$status" -eq 0 ] || { printf 'FAIL gridswitch: qs exit %s\n' "$status"; failed=1; }
# Sample input: " DEBUG qml: GRIDSWITCH DONE 12 checks, 0 failed"
[ "$(grep -ac 'GRIDSWITCH DONE .* checks, 0 failed' "$root/probe.log")" -eq 1 ] \
    || { echo 'FAIL gridswitch: no single "GRIDSWITCH DONE ... 0 failed" line'; failed=1; }
errors=$(grep -aE 'TypeError|ReferenceError|Binding loop' "$root/probe.log" | head -5)
[ -z "$errors" ] || { printf 'FAIL gridswitch: the probe log holds a TypeError, ReferenceError or binding loop line:\n%s\n' "$errors"; failed=1; }
[ "$failed" -eq 0 ] || exit 1
echo 'gridswitch: a switch to Grid builds the viewport first, the cache rows after the frame, and draws no half-built frame'
