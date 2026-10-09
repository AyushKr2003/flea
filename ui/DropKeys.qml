pragma Singleton
import QtQuick

// #259: the modifier transitions this window saw while a drag hovered it. The marker names the hovered drag; each is 1 held, 0 released, -1 unseen.
QtObject {
    id: root
    property string marker: ""
    property int ctrl: -1
    property int shift: -1
    property bool leaving: false

    // A new drag resets the pair; moving between two targets here keeps what was seen.
    function enter(seen) {
        leaving = false
        if (marker !== seen) {
            marker = seen
            ctrl = -1
            shift = -1
        }
    }

    // Qt delivers a move between two targets as exited then entered, so only a leave no entrance follows ends the hover.
    function leave() {
        leaving = true
        Qt.callLater(root.settle)
    }

    function settle() {
        if (leaving) clear()
    }

    // A drop or a leave consumes the drag; stray taps never arm tracking because it gates on a marker.
    function clear() {
        leaving = false
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
