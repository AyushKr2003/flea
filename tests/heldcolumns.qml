//@ pragma ShellId flea-heldcolumns-test
import QtQuick
import Quickshell
import "flea" as Flea
import "flea/js/Startup.js" as Startup
import "flea/js/Swap.js" as Swap

// A Columns pane whose first listing is held reads loading, then waiting after the wait, then lands whole; the native case needs this and its shots wait on it.
ShellRoot {
    id: root
    readonly property string fixture: Quickshell.env("HELD_DIR") || ""
    readonly property int limit: Number(Quickshell.env("HELD_LIMIT") || "0")
    property int checks: 0
    property int failures: 0
    property var pane: null
    property double t0: 0
    // The first sample time of each state, in ms after the open.
    property var seen: ({})
    property string loadingAt1500: ""
    property string last: ""

    function check(name, actual, expected) {
        checks += 1
        if (actual !== expected) {
            failures += 1
            console.log("HELDCOLUMNS FAIL " + name + " got=" + actual + " expected=" + expected)
        } else console.log("HELDCOLUMNS ok " + name)
    }
    function finish() {
        ticker.stop()
        var s = root.seen
        check("limit " + limit + ": the pane opens in loading", s.loading !== undefined && s.loading < 500, true)
        check("limit " + limit + ": loading stands past the " + Swap.HOLD_MS + " ms hold-off", root.loadingAt1500, "loading")
        check("limit " + limit + ": the wait speaks at " + Startup.LISTING_WAIT_MS + " ms", s.waiting >= Startup.LISTING_WAIT_MS - 100 && s.waiting < Startup.LISTING_WAIT_MS + 2000, true)
        check("limit " + limit + ": the held rows land after the wait", s.ready > s.waiting, true)
        check("limit " + limit + ": the landed pane stands on the folder, whole", pane.path + "|" + pane.total + "|" + pane.stateMessage + "|" + pane.viewMode, fixture + "|2||columns")
        check("limit " + limit + ": the stored limit is the one asked for", Flea.ViewState.state.columnsLimit, limit)
        console.log("HELDCOLUMNS DONE " + checks + " checks, " + failures + " failed")
        Qt.quit()
    }

    FloatingWindow {
        implicitWidth: 1200
        implicitHeight: 800
        Flea.Backend { id: be }
        Component { id: pc; Flea.Pane { width: 1200; height: 800; backend: be } }
        Item { id: holder; anchors.fill: parent }
        Component.onCompleted: { root.pane = pc.createObject(holder); root.pane.open(root.fixture); root.t0 = Date.now() }
    }
    Timer {
        id: ticker
        interval: 25
        running: true
        repeat: true
        onTriggered: {
            if (!root.pane) return
            var now = Date.now() - root.t0
            var state = root.pane.listingState
            if (root.seen[state] === undefined) root.seen[state] = now
            if (root.loadingAt1500 === "" && now >= 1500) root.loadingAt1500 = state
            if (state === "ready" || now > 20000) root.finish()
        }
    }
}
