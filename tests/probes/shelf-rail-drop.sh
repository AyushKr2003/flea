#!/bin/bash
# Shelf rail inbound drop probe (issue 255): a file dragged onto the Edge rail is lost when it is
# released after the 120 ms dwell has opened the card, because the card's Overlay dismissal surface
# maps above the rail with a full-screen mask and no DropArea under the pointer.
#
# Own quickshell instance, own config dir, own state dir: never the live shell, never the operator's
# pile. Real shelf files only (ShelfRail, ShelfService, Model.js); the dismissal surface stands in
# for KeyboardPanel, which cannot be hosted outside the live shell (plugin Panel base type, injected
# bar and settings, shell Ui/Commons config root).
#
# Modes: product (default) refuses unless the shipped tree carries the fix, then runs subtract;
# subtract runs the fixed mask (full screen minus the rail strip); full runs the v0.3.8 mask and
# reproduces the report, so it FAILs by design. Edge: --edge=right|left|bottom (default right).
#
# Minipc: FLEA_BIN=/path/to/flea ./tests/probes/shelf-rail-drop.sh --mode=product
# A quiet session: the real pointer is driven and whatever sits under it takes the press.
set -u
out() { printf 'SHELFRAIL %s\n' "$*"; }
refuse() { out "FAIL $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || refuse "missing $1"; }
need qs; need hyprctl; need ydotool; need python3
[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || refuse "no Hyprland session"
flea_bin="${FLEA_BIN:-$(command -v flea || true)}"
[ -n "$flea_bin" ] || refuse "no flea binary (set FLEA_BIN)"
[ -x "$flea_bin" ] || refuse "flea binary is not executable: $flea_bin"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
mode=product; edge=right
for arg in "$@"; do
  case "$arg" in
    --mode=product|--mode=subtract|--mode=full) mode="${arg#--mode=}" ;;
    --edge=right|--edge=left|--edge=bottom) edge="${arg#--edge=}" ;;
    *) refuse "unknown argument $arg" ;;
  esac
done
[ -d /usr/share/omarchy/shell/Commons ] || refuse "no omarchy shell Commons (this probe runs on an Omarchy box)"
# The shipped composition, so product is red on v0.3.8 and green after the fix.
if [ "$mode" = product ]; then
  grep -q "Intersection.Subtract" "$repo/shelf/Panel.qml" || refuse "shelf/Panel.qml carries no mask subtract (tree predates the fix)"
  grep -q "railCut" "$repo/shelf/Panel.qml" || refuse "shelf/Panel.qml names no rail cut (tree predates the fix)"
  grep -q "function railStrip" "$repo/shelf/Model.js" || refuse "shelf/Model.js has no railStrip (tree predates the fix)"
  mode=subtract
fi
[ -f "$repo/tests/lib/hypr-dispatch.sh" ] || refuse "no typed Hyprland helper"
. "$repo/tests/lib/hypr-dispatch.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/shelfrail.XXXXXXXX") || refuse "mktemp failed"
touch "$work/.flea-test-sandbox"
qs_pid=""
cleanup() {
  ydotool click 0x80 >/dev/null 2>&1 || true
  [ -n "$qs_pid" ] && kill "$qs_pid" 2>/dev/null || true
  [ -f "$work/.flea-test-sandbox" ] && case "$work" in /*/shelfrail.????????) rm -rf -- "$work" ;; esac
}
trap cleanup EXIT

mkdir -p "$work/src" "$work/state/flea" "$work/cfg/qs"
printf '{"shelf":{"enabled":true,"bar":false,"rail":"%s","screenshots":false,"recordings":false,"recent":0}}' "$edge" > "$work/state/flea/ui.json"
echo "drop me" > "$work/src/dropme.txt"
ln -s /usr/share/omarchy/shell/Commons "$work/cfg/qs/Commons" || refuse "cannot link shell Commons"
ln -s "$repo/shelf" "$work/cfg/shelf" || refuse "cannot link shelf tree"

# Real rail and service; only the dismissal surface is a stand-in, with the mask the mode names.
# The strip comes from the shipped Model.railStrip over the real rail item, the call Panel.qml makes.
cat > "$work/cfg/harness.qml" <<EOF
import QtQuick
import Quickshell
import Quickshell.Wayland
import "shelf/" as ShelfFiles
import "shelf/Model.js" as Model
ShellRoot {
  id: root
  property string mode: "$mode"
  property string work: "$work"
  property string fleaBin: "$flea_bin"
  ShelfFiles.ShelfService {
    id: service
    settings: ({ fleaCommand: root.fleaBin })
  }
  ShelfFiles.ShelfRail {
    id: rail
    edge: service.railEdge
    dwellMs: service.railDwellMs
    held: 0
    onDropped: function (paths) { service.addAll(paths) }
    onDwelled: {
      card.open = true
      Quickshell.execDetached(["sh", "-c", "printf 'open\\n' >> '" + root.work + "/card-opened'"])
    }
  }
  // Drag source: a held press carries the sandbox file as a copy offer.
  PanelWindow {
    id: source
    WlrLayershell.namespace: "flea-shelfrail-probe-source"
    WlrLayershell.layer: WlrLayer.Top
    anchors { top: true; left: true }
    width: 900; height: 500
    color: "#202020"
    Rectangle {
      id: handle
      x: 100; y: 100; width: 120; height: 60
      color: "#404040"
      Drag.mimeData: ({ "text/uri-list": "file://$work/src/dropme.txt" })
      Drag.supportedActions: Qt.CopyAction
      MouseArea {
        anchors.fill: parent
        onPressed: handle.Drag.active = true
      }
      Timer { interval: 30000; running: true; onTriggered: handle.Drag.active = false }
    }
  }
  // The card stand-in: full-screen Overlay above the rail, mask per mode, no DropArea by design.
  PanelWindow {
    id: card
    property bool open: false
    visible: open
    WlrLayershell.namespace: "flea-shelfrail-probe-card"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    property var cut: Model.railStrip(rail.edge, card.width, card.height, rail.implicitWidth, rail.implicitHeight)
    mask: Region {
      width: card.width
      height: card.height
      Region {
        x: card.cut.x
        y: card.cut.y
        width: root.mode === "subtract" ? card.cut.width : 0
        height: root.mode === "subtract" ? card.cut.height : 0
        intersection: Intersection.Subtract
      }
    }
    Rectangle {
      anchors.centerIn: parent
      width: 380; height: 200
      color: "#303030"
      MouseArea { anchors.fill: parent }
    }
  }
}
EOF

export XDG_STATE_HOME="$work/state"
setsid qs -p "$work/cfg/harness.qml" >"$work/qs.log" 2>&1 &
qs_pid=$!
# Layer entry geometry for a namespace: monitor, x, y, w, h (one line, space separated).
layer_geom() {
  hyprctl layers -j 2>/dev/null | python3 -c '
import json, sys
# Sample input: {"DP-1":{"levels":{"2":[{"namespace":"n","x":0,"y":0,"w":4,"h":100}]}}}.
want = sys.argv[1]
d = json.load(sys.stdin)
found = [ (mon, n) for mon, entry in d.items() for lv in [entry.get("levels", {})] for ns in lv.values() for n in (ns if isinstance(ns, list) else []) if isinstance(n, dict) and n.get("namespace") == want ]
if len(found) != 1:
    raise SystemExit(1)
mon, n = found[0]
print(mon, n.get("x", 0), n.get("y", 0), n.get("w", 0), n.get("h", 0))
' "$1"
}
up=""
for _ in $(seq 1 40); do
  layer_geom flea-shelf-rail >/dev/null 2>&1 && up=1 && break
  sleep 0.25
done
[ -n "$up" ] || refuse "probe rail surface never mapped (see $work/qs.log)"
# The rail and the source must share one scale-1 monitor, or the pointer math is unsound.
mon_geom() {
  hyprctl monitors -j 2>/dev/null | python3 -c '
import json, sys
# Sample input: [{"name":"DP-1","x":0,"y":0,"scale":1.0}].
ms = json.load(sys.stdin)
m = [x for x in ms if x.get("name") == sys.argv[1]]
if len(m) != 1:
    raise SystemExit(1)
print(m[0]["x"], m[0]["y"], m[0]["scale"])
' "$1"
}
read -r rail_mon rail_x rail_y rail_w rail_h <<< "$(layer_geom flea-shelf-rail || refuse "probe rail vanished")"
src_geom=$(layer_geom flea-shelfrail-probe-source) || refuse "probe source never mapped"
read -r src_mon src_x src_y src_w src_h <<< "$src_geom"
[ "$rail_mon" = "$src_mon" ] || refuse "rail on $rail_mon but source on $src_mon, one monitor per run"
read -r mon_x mon_y mon_scale <<< "$(mon_geom "$rail_mon" || refuse "no geometry for monitor $rail_mon")"
[ "$mon_scale" = "1.0" ] || [ "$mon_scale" = "1" ] || refuse "monitor $rail_mon is at scale $mon_scale, this probe needs 1"
# Handle centre and rail strip centre, in global pointer coordinates.
hx=$((mon_x + src_x + 160)); hy=$((mon_y + src_y + 130))
dx=$((mon_x + rail_x + rail_w / 2)); dy=$((mon_y + rail_y + rail_h / 2))
move_to() {
  local tx="$1" ty="$2" i cursor cx cy
  for i in $(seq 1 16); do
    cursor=$(hyprctl cursorpos) || refuse "cursorpos read failed"
    [[ "$cursor" =~ ^[[:space:]]*(-?[0-9]+),[[:space:]]+(-?[0-9]+)[[:space:]]*$ ]] || refuse "invalid cursor: $cursor"
    cx=${BASH_REMATCH[1]}; cy=${BASH_REMATCH[2]}
    if (( tx - cx <= 4 && tx - cx >= -4 && ty - cy <= 4 && ty - cy >= -4 )); then return 0; fi
    ydotool mousemove -x "$(((tx - cx) / 2))" -y "$(((ty - cy) / 2))" >/dev/null 2>&1 || refuse "pointer motion failed"
    sleep 0.05
  done
  refuse "pointer did not reach $tx,$ty"
}
move_to "$hx" "$hy"
ydotool click 0x40 >/dev/null 2>&1 || refuse "pointer press failed"
sleep 0.3
move_to "$dx" "$dy"
# Past the 120 ms dwell: the card must be open before the release, which is the bug condition.
opened=""
for _ in $(seq 1 50); do
  [ -f "$work/card-opened" ] && opened=1 && break
  sleep 0.1
done
[ -n "$opened" ] || refuse "card never opened past the dwell, so the release proves nothing"
sleep 0.5
ydotool click 0x80 >/dev/null 2>&1 || refuse "pointer release failed"
landed=""
for _ in $(seq 1 30); do
  if [ -f "$work/state/omarchy/flea-shelf/shelf.json" ] \
    && python3 -c 'import json,sys; d = json.load(open(sys.argv[1])); sys.exit(0 if any(i.get("path") == sys.argv[2] for i in d.get("items", [])) else 1)' \
      "$work/state/omarchy/flea-shelf/shelf.json" "$work/src/dropme.txt" 2>/dev/null; then
    landed=1; break
  fi
  sleep 0.5
done
if [ "$mode" = "full" ]; then
  [ -z "$landed" ] || refuse "full mask took the drop, so this run does not reproduce the report"
  out "FAIL drop lost after the card opened (v0.3.8 mask reproduced)"
  exit 1
fi
[ -n "$landed" ] || refuse "drop lost with the strip cut out (see $work/qs.log)"
out "PASS drop landed after the card opened"
