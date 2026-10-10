#!/bin/bash
# A column move under the preview hold changes the preview in the first frame after the key frame, and
# the release frame is the last one the move draws. Before, the change waited for the picture's own
# completion signal, so a frame went by with only the layer's repaint in it, and the layer went one
# swap after the release, which drew one frame more. Threaded render loop, the one Flea runs on, so
# the layer's signals cross threads as they do there. Offscreen software rendering starts a frame the
# moment one is asked for, so the grab's own second repaint is one more held frame here; a display
# paced by its compositor folds it into the change's frame. A second leg runs the basic loop, which
# syncs and renders inside one call: there the change must still wait until the frame is done. Offscreen,
# so it needs no display and no lock. PREVIEW_HOLDFRAMES_UI points it at another ui tree.
set -u
cd "$(dirname "$0")/.." || exit 1

pass=0
fail=0
ok()  { printf 'ok   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*"; fail=$((fail+1)); }

command -v qs >/dev/null || { echo "preview-holdframes.sh: qs is not installed"; exit 1; }

. "$PWD/tools/flea-sandbox-guard"
sandbox_forbidden /tmp && sandbox_refuse "preview-holdframes: /tmp is inside a forbidden test target"
hf_root=$(mktemp -d /tmp/flea-preview-holdframes.XXXXXXXX) || exit 1
FIXTURE_ROOT=$hf_root
sandbox_root_ok
hf_root=$SANDBOX_ROOT
readonly hf_root
printf 'Flea preview holdframes sandbox\n' > "$hf_root/$SANDBOX_MARKER" || exit 1
hf_work="$hf_root/work"
readonly hf_work
cleanup() {
    local result=$?
    trap - EXIT
    sandbox_remove "$hf_work"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
sandbox_scratch "$hf_work"
mkdir -p "$hf_work"/{config,home,runtime,tmp} "$hf_work"/out-{threaded,basic} || exit 1
chmod 700 "$hf_work/runtime" || exit 1
ln -s "$PWD/tests/preview-holdframes.qml" "$hf_work/config/shell.qml" || exit 1
ln -s /usr/share/omarchy/shell/Commons "$hf_work/config/Commons" || exit 1
ln -s /usr/share/omarchy/shell/Ui "$hf_work/config/Ui" || exit 1

ui=${PREVIEW_HOLDFRAMES_UI:-$PWD/ui}
# A zero update interval lets a queued repaint start the next frame at once, as a vsync-paced window does.
# The harness ends itself with a kill, so the subshell keeps bash's "Terminated" notice out of the report.
run_leg() {
    local loop=$1
    log="$hf_root/holdframes-$loop.log"
    out="$hf_work/out-$loop"
    ( env -u DISPLAY -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
        HOME="$hf_work/home" XDG_RUNTIME_DIR="$hf_work/runtime" TMPDIR="$hf_work/tmp" \
        XDG_CONFIG_HOME="$hf_work/home/.config" XDG_STATE_HOME="$hf_work/home/.local/state" \
        XDG_CACHE_HOME="$hf_work/home/.cache" \
        QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=generic QT_QUICK_BACKEND=software QSG_RENDER_LOOP="$loop" \
        QT_QPA_UPDATE_IDLE_TIME=0 QT_FORCE_STDERR_LOGGING=1 \
        PREVIEW_HOLDFRAMES_UI="$ui" PREVIEW_HOLDFRAMES_OUT="$out" \
        timeout 90 qs -p "$hf_work/config" > "$log" 2>&1; exit $? ) 2>/dev/null
    status=$?
    warnings=$(grep -aE 'TypeError|ReferenceError|Cannot|is not a type|failed to load|crashed' "$log" || true)
    done=$(grep -a 'HOLDFRAMES DONE' "$log" | tail -1)
    if grep -q 'HOLDFRAMES FAIL' "$log" || [ -z "$done" ] || ! grep -q 'HOLDFRAMES GRAB' "$log" || [ -n "$warnings" ]; then
        bad "the $loop leg did not finish cleanly (qs exit $status)"
        cat "$log"
        return 1
    fi
    printf '  %s: %s\n' "$loop" "${done#*HOLDFRAMES }"
}
field() { printf '%s' "$done" | sed -n "s/.* $1=\([0-9]*\).*/\1/p"; }

# Sample input: '... KEY 5 capture=1 held=3 free=1 whole=1'; keys 1 and 2 warm up and are not judged.
judge_keys() { grep -a 'HOLDFRAMES KEY' "$log" | awk -v want="$1" '{ for (i = 1; i <= NF; i++) { split($i, kv, "=")
    v[kv[1]] = kv[2]; if ($i == "KEY") k = $(i+1) } if (k > 2 && v[want] != 1) n++ } END { print n + 0 }'; }

# Both legs: every release frame whole, every hold landed, and the settled window shows the last preview.
judge_common() {
    local loop=$1
    if [ "$(field broken)" = 0 ]; then ok "$loop: every release frame drew the new preview whole, with the layer let go";
    else bad "$loop: $(field broken) release frame(s) were not whole"; fi
    if [ "$(field holds)" = 14 ] && [ "$(field fallbacks)" = 0 ] && [ "$(field mid)" = 0 ]; then
        ok "$loop: 14 holds, none fell back, no half-built frame"
    else bad "$loop: holds=$(field holds) fallbacks=$(field fallbacks) mid=$(field mid), want 14, 0 and 0"; fi
    # The settled window: a P6 PPM; the bottom-left of the preview is the last preview's ground, #2a3a4a.
    px=$(python3 -c '
import sys
d = open(sys.argv[1], "rb").read()
parts = d.split(maxsplit=4)
w = int(parts[1]); body = parts[4]
o = (875 * w + 325) * 3
print("%02x%02x%02x" % tuple(body[o:o + 3]))' "$out/settled.ppm" 2>/dev/null)
    if [ "$px" = 2a3a4a ]; then ok "$loop: the settled window shows the last preview";
    else bad "$loop: the settled window shows #${px:-nothing} where the last preview's ground #2a3a4a belongs"; fi
}

if run_leg threaded; then
    grep -a 'HOLDFRAMES KEY' "$log" | sed 's/.*HOLDFRAMES /    /'
    late=$(judge_keys capture)
    if [ "$late" -eq 0 ]; then ok "threaded: every judged key changed the preview in the first frame after the key frame";
    else bad "threaded: $late judged key(s) drew a frame with only the picture's repaint before the change"; fi
    extra=$(judge_keys free)
    if [ "$extra" -eq 0 ]; then ok "threaded: every judged key drew one frame after the release and no more";
    else bad "threaded: $extra judged key(s) drew a frame after the release frame"; fi
    judge_common threaded
fi

if run_leg basic; then
    if [ "$(field inframe)" = 0 ]; then ok "basic: no change ran between a frame's sync and its render";
    else bad "basic: $(field inframe) change(s) ran between a frame's sync and its render"; fi
    judge_common basic
fi

printf 'preview-holdframes: %s check(s), %s failed\n' "$((pass + fail))" "$fail"
[ "$fail" -eq 0 ]
