pragma Singleton
import QtQuick

// #259: the modifier transitions this window saw during a drag. Marker and lift name the drag; each key is 1 held, 0 released, -1 unseen.
QtObject {
    id: root
    readonly property string liftMime: "application/x-flea-lift"
    property int lifts: 0
    property string marker: ""
    property string lift: ""
    property int ctrl: -1
    property int shift: -1
    property bool leaving: false

    // Every drag this window starts carries its own lift number, so two drags of the same rows are never one drag here.
    function stamped(mime) {
        var out = {}
        for (var key in mime) out[key] = mime[key]
        lifts += 1
        out[liftMime] = String(lifts)
        return out
    }

    // Another drag resets the pair; the same drag keeps what was seen, and an own lift keeps it across gaps between targets.
    function enter(seen, lifted) {
        var number = lifted || ""
        leaving = false
        if (marker !== seen || lift !== number) {
            marker = seen
            lift = number
            ctrl = -1
            shift = -1
        }
    }

    // A drag with no lift number, another app's or an older Flea's, cannot be told from the next one, so a leave
    // no entrance follows in the same turn ends it; Qt delivers a move between two targets as exited then entered.
    function leave() {
        if (lift !== "") return
        leaving = true
        Qt.callLater(root.settle)
    }

    function settle() {
        if (leaving) clear()
    }

    // A drop consumes the drag; taps before any drag never arm tracking because it gates on a marker.
    function clear() {
        leaving = false
        marker = ""
        lift = ""
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
