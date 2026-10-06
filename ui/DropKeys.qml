pragma Singleton
import QtQuick

// #259: the modifier transitions this window saw while a drag hovered it. The marker names the hovered drag; each is 1 held, 0 released, -1 unseen.
QtObject {
    id: root
    property string marker: ""
    property int ctrl: -1
    property int shift: -1

    // A new drag resets the pair; re-entering the same drag keeps what was seen.
    function enter(seen) {
        if (marker !== seen) {
            marker = seen
            ctrl = -1
            shift = -1
        }
    }

    // A drop consumes the drag; stray taps never arm tracking because it gates on a marker.
    function clear() {
        marker = ""
        ctrl = -1
        shift = -1
    }

    // The pane funnels its press and release here; the lift bits stay the baseline, so a key held since the lift still counts.
    function track(event, pressed) {
        if (marker === "") return
        if (event.key === Qt.Key_Control) ctrl = pressed ? 1 : 0
        else if (event.key === Qt.Key_Shift) shift = pressed ? 1 : 0
    }
}
