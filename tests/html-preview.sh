#!/usr/bin/env bash
# The real backend and lazy preview surfaces render one local page under the HTML jail.
set -uo pipefail
. "$(dirname "$0")/../tools/flea-sandbox-guard"
. "$(dirname "$0")/qslog-gate.sh"
cd "$(dirname "$0")/.." || exit 1
for tool in qs qml6 bat magick dbus-run-session python3; do
    command -v "$tool" >/dev/null || { printf 'FAIL html-preview: %s is required\n' "$tool"; exit 1; }
done
python3 tests/html-corners.py --qt "$(command -v qs)" || exit 1
bin=${FLEA_BIN:-$PWD/target/debug/flea}
[ -x "$bin" ] || { printf 'FAIL html-preview: no backend %s\n' "$bin"; exit 1; }
test_root=$(mktemp -d "$FIXTURE_ROOT/flea-html-preview.XXXXXXXX") || exit 1
[ -n "$test_root" ] && [[ "$test_root" = /* ]] || exit 1
: > "$test_root/.flea-test-sandbox"
cleanup() { sandbox_remove "$test_root"; }
trap cleanup EXIT
mkdir -p "$test_root"/{config,fixture,home,state/flea,cache,runtime} || exit 1
chmod 700 "$test_root/runtime" || exit 1
ln -s "$(readlink -m ui/boot/Commons)" "$test_root/config/Commons" || exit 1
ln -s "$(readlink -m ui/boot/Ui)" "$test_root/config/Ui" || exit 1
ln -s "$test_root/config/flea/boot/fleatab.qml" "$test_root/config/fleatab.qml" || exit 1
cp -a ui "$test_root/config/flea" || exit 1
printf '{}\n' > "$test_root/state/flea/ui.json"
magick -size 32x32 xc:'#12ab34' "$test_root/fixture/local.png" || exit 1
magick -size 32x32 xc:'#3412ab' "$test_root/outside.png" || exit 1
magick -size 32x32 xc:'#ab1234' "$test_root/remote.png" || exit 1
ln -s ../outside.png "$test_root/fixture/escape.png" || exit 1
python3 tests/html-fixture.py "$test_root/fixture" || exit 1
cp "$test_root/fixture/notes.md" "$test_root/fixture/other.md" || exit 1
python3 tests/html-specimen.py "$test_root/specimen" || exit 1
magick -size 300x400 xc:'#45bc23' "$test_root/reload.png" || exit 1
magick -size 300x400 xc:'#2345bc' "$test_root/reload-blue.png" || exit 1
cp tests/html-reload-writer.py "$test_root/reload-writer.py" || exit 1
cp "$test_root/specimen/index.html" "$test_root/fixture/board.html" || exit 1
mkdir -p "$test_root/cache #?"
export HOME="$test_root/home" XDG_STATE_HOME="$test_root/state" XDG_CACHE_HOME="$test_root/cache #?"
export XDG_RUNTIME_DIR="$test_root/runtime" FLEA_BIN="$bin" FLEA_PATH="$test_root/fixture"
export HTML_UI="$test_root/config/flea" HTML_ROOT="$test_root" FLEA_REDUCED_MOTION=1
engine_status=0
python3 tests/html-engine.py "$bin" "$test_root" || engine_status=1
for harness in html-source-refusals html-auto-render html-preview html-reload; do
cp "tests/$harness.qml" "$test_root/config/shell.qml" || exit 1
log="$test_root/$harness.log"
env -u DISPLAY -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
    QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=generic QT_QUICK_BACKEND=software QT_FORCE_STDERR_LOGGING=1 \
    dbus-run-session -- timeout 180 qs -p "$test_root/config" > "$log" 2>&1
status=$?
[ -z "${FLEA_CI_SUITE_LOGS:-}" ] || cp "$log" "$FLEA_CI_SUITE_LOGS/$harness-ui.log"
grep -a 'HTML_PREVIEW \(PASS\|FAIL\|DONE\)' "$log"
qslog_crash "$harness" "$log" || exit 1
if [ "$status" -ne 0 ] || [ "$(grep -ac 'HTML_PREVIEW DONE' "$log")" -ne 1 ] \
    || grep -aqE 'HTML_PREVIEW FAIL|TypeError|ReferenceError|Unable to assign|Cannot assign|Binding loop detected' "$log"; then
    printf 'FAIL html-preview: UI exit %s\n' "$status"
    tail -25 "$log"
    exit 1
fi
done
# Texture fills need RHI; Linux offscreen OpenGL needs GLX, so a private X server supplies its display.
if command -v xvfb-run >/dev/null; then
corner_output="${FLEA_CI_SUITE_LOGS:-$test_root}/html-rhi"
mkdir -p "$corner_output" || exit 1
for harness in html-preview html-clip; do
cp "tests/$harness.qml" "$test_root/config/shell.qml" || exit 1
log="$test_root/$harness-rhi.log"
env -u DISPLAY -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u QT_QUICK_BACKEND \
    QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=generic QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=opengl \
    LIBGL_ALWAYS_SOFTWARE=1 TMPDIR="$test_root" QT_FORCE_STDERR_LOGGING=1 FLEA_CI_SUITE_LOGS="$corner_output" \
    xvfb-run -a --server-args="-screen 0 1280x1024x24 -nolisten tcp +extension GLX" dbus-run-session -- timeout 180 qs -p "$test_root/config" > "$log" 2>&1
status=$?
cp "$log" "$corner_output/$harness-rhi.log"
grep -a 'HTML_PREVIEW \(PASS\|FAIL\|DONE\)' "$log"
qslog_crash html-corners-rhi "$log" || exit 1
if [ "$status" -ne 0 ] || [ "$(grep -ac 'HTML_PREVIEW DONE' "$log")" -ne 1 ] \
    || grep -aqE 'HTML_PREVIEW FAIL|TypeError|ReferenceError|Unable to assign|Cannot assign|Binding loop detected' "$log"; then
    printf 'FAIL html-preview: RHI UI exit %s\n' "$status"
    tail -25 "$log"
    exit 1
fi
done
python3 tests/html-corners.py --log "$test_root/html-preview-rhi.log" "$corner_output" || exit 1
actual=$(magick "$corner_output/html-clip-ready.png" -alpha off -format '%[pixel:p{20,20}]' info:) || exit 1
[ "$actual" = 'srgb(35,69,188)' ] || { printf 'FAIL html-preview: clip lost the page texture: %s\n' "$actual"; exit 1; }
printf 'PASS html-preview: clip preserves the blue page texture\n'
for state in failed large; do
    alpha=$(magick "$corner_output/html-clip-$state.png" -format '%[fx:p{20,20}.a]' info:) || exit 1
    [ "$alpha" = 0 ] || { printf 'FAIL html-preview: %s retains hidden page alpha=%s\n' "$state" "$alpha"; exit 1; }
    printf 'PASS html-preview: %s leaves no stale page pixels\n' "$state"
done
else
    printf 'HTML_CORNER UNAVAILABLE: Qt software cannot fill the shape texture; offscreen RHI needs GLX and xvfb-run is absent. Native corner probes remain mandatory.\n'
fi
reload_output=${FLEA_CI_SUITE_LOGS:-$test_root}
for phase in before pending after; do
    actual=$(magick "$reload_output/html-reload-$phase.png" -alpha off -format '%[pixel:p{150,100}]' info:) || exit 1
    expected='srgb(69,188,35)'
    [ "$phase" != after ] || expected='srgb(35,69,188)'
    [ "$actual" = "$expected" ] || { printf 'FAIL html-preview: same-path %s pixels %s, want %s\n' "$phase" "$actual" "$expected"; exit 1; }
    printf 'PASS html-preview: same-path %s pixels %s\n' "$phase" "$actual"
done
[ "$engine_status" -eq 0 ] || { printf 'FAIL html-preview: backend assertions failed\n'; exit 1; }
printf 'html-preview: backend isolation and Quick Look/column passed\n'
