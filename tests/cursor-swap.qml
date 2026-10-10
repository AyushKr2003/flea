//@ pragma ShellId flea-cursor-swap-test

import QtQuick
import Quickshell
import "flea" as Flea
import "flea/js/BackReturn.js" as BackReturn
import "flea/js/Nav.js" as Nav

// tests/cursor-swap.sh's harness: Back and Forward land through the real ui/PaneSwap.qml hold() and rows turn.
ShellRoot {
    id: shell

    property var failures: []
    property int ticks: 0
    property int phase: 0

    function log(line) { console.log("CURSORSWAP " + line) }
    function quit() { Quickshell.execDetached(["kill", String(Quickshell.processId)]) }
    function check(name, cond, detail) {
        if (cond) {
            shell.log("PASS " + name)
            return
        }
        shell.failures.push(name)
        shell.log("FAIL " + name + " got " + detail)
    }
    // What the pane draws after a backend-driven turn: cursor, held window, rows held, count, path and state.
    function sig() {
        return [stubPane.cursorIndex, stubPane.held, stubPane.rows.length, stubPane.total, stubPane.path,
                stubPane.listingState].join("|")
    }
    // Each phase records the drawn state after every turn; a correct Back draws the old state until one landing.
    function states(name, sigs, landed) {
        var want = [sigs[0], sigs[0], sigs[0], landed].join(" > ")
        shell.check(name, sigs.join(" > ") === want, sigs.join(" > ") + " want " + want)
    }
    // A held Back into /big owing name at index; the first window from 0 lacks the name.
    function windowedBack(name, index) {
        stubPane.listInFlight = true
        stubPane.listedSeen = false
        stubPane.listingPath = "/big"
        stubBackend.sent = []
        var sigs = [shell.sig()]
        var held = swap.hold({ restore: BackReturn.makeEntry("/big", name, index) })
        if (!held) Nav.forget(stubPane)
        sigs[0] = shell.sig()
        swap.takeListed(2000, 0.1, 0.2, "/big", null)
        swap.takeRows(0, shell.windowRows("w", 0, 64), [], 2)
        sigs.push(shell.sig())
        return sigs
    }
    // The located reply, then the window it asked for with the name at its head; a tree without takeLocated still draws.
    function locatedWindow(sigs, path, index, start, head) {
        if (typeof BackReturn.takeLocated === "function")
            BackReturn.takeLocated(stubPane, { directory: "/big", path: path, index: index })
        sigs.push(shell.sig())
        var rows = shell.windowRows("w", start, 64)
        if (head) rows[0] = { n: head }
        swap.takeRows(start, rows, [], 2)
        sigs.push(shell.sig())
    }
    function sentShape() {
        return stubBackend.sent.map(function (m) { return m.c + ":" + (m.path || m.start) }).join(",")
    }
    function windowRows(prefix, start, count) {
        var out = []
        for (var i = 0; i < count; i++) out.push({ n: prefix + (start + i) })
        return out
    }

    Item {
        Item {
            id: stubBackend
            property real heldListing: 0
            property var sent: []
            function send(m) { sent.push(m) }
            function window(start, count) { sent.push({ c: "window", start: start, count: count }) }
        }

        Item {
            id: stubWire
            property var anchor: null
            function locateRetry() {}
            function openRenameOnArrival() {}
        }

        Item {
            id: stubPane
            property string path: ""
            property string listingPath: ""
            property int total: 0
            property int held: 0
            property var rows: []
            property var kindNames: []
            property int cursorIndex: 0
            property int windowSize: 64
            property string listingState: "ready"
            property string stateMessage: ""
            property int lockedMode: 0
            property bool listInFlight: false
            property bool listedSeen: false
            property string searchMode: ""
            property var thumbState: ({})
            property var dirSizeState: ({})
            property int reloadChanged: -1
            property int reloadFrom: -1
            property var preferenceAnchor: null
            property var tabs: null
            property string pendingSelect: ""
            property string pendingBackground: ""
            property var pendingBackgroundAt: null
            property bool dualMode: true
            property string filterQuery: ""
            property bool filterTyping: false
            property int trashArmedAt: 0
            property var pendingSort: null
            property int renamingIndex: -1
            property var backend: stubBackend
            property var swap: null
            property var listArea: null
            function rowFor(i) { var o = i - held; return o >= 0 && o < rows.length ? rows[o] : null }
            function join(base, name) { return base === "/" ? "/" + name : base + "/" + name }
            function setCursor(i) { cursorIndex = Math.max(0, Math.min(total - 1, i)) }
            function opened(path) {}
            function message(text, isError) {}
            function clearSelection() {}
            function selectionCount() { return 0 }
            function applyPendingSelect() { Nav.applyPendingSelect(stubPane); Nav.applyPendingBackground(stubPane) }
        }

        Item {
            id: stubArea
            function restartSettle() {}
            function primeSettle() {}
        }
    }

    FloatingWindow {
        implicitWidth: 640
        implicitHeight: 480
        color: "#303030"

        Flea.PaneSwap {
            id: swap
            pane: stubPane
            wire: stubWire
        }
    }

    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: shell.advance()
    }

    Component.onCompleted: { stubPane.swap = swap; stubPane.listArea = stubArea }

    // One phase a tick; a phase that throws fails by name and the next still runs.
    function advance() {
        shell.ticks += 1
        if (shell.ticks < 2 || shell.phase > 4) return
        try {
            shell.runPhase(shell.phase)
        } catch (e) {
            shell.check("phase-" + shell.phase + "-ran", false, String(e))
        }
        shell.phase += 1
        if (shell.phase > 4) {
            shell.log("DONE failures=" + shell.failures.length)
            shell.quit()
        }
    }

    // Every phase drives the real hold() and the real rows turn; the cursor assertions name them.
    function runPhase(phase) {
        if (phase === 0) {
            stubPane.path = ""
            stubPane.total = 0
            stubPane.held = 0
            stubPane.rows = []
            stubPane.cursorIndex = 0
            stubBackend.sent = []
            stubBackend.heldListing = 0
            stubPane.listInFlight = true
            stubPane.listedSeen = false
            stubPane.listingPath = "/d"
            var held = swap.hold({ restore: BackReturn.makeEntry("/d", "m", 2) })
            shell.check("real-hold-arms-the-travel-restore", held === true && swap.restore !== null,
                "held=" + held + " restore=" + JSON.stringify(swap.restore))
            swap.takeListed(3, 0.1, 0.2, "/d", null)
            swap.takeRows(0, [{ n: "a" }, { n: "b" }, { n: "m" }], [], 1)
            shell.check("real-rows-turn-lands-the-name", stubPane.cursorIndex === 2
                && (stubPane.rowFor(2) || {}).n === "m", "cursor=" + stubPane.cursorIndex)
            shell.check("real-rows-turn-drops-the-restore", swap.restore === null,
                "restore=" + JSON.stringify(swap.restore))
        } else if (phase === 1) {
            // The name sits outside the first window: the old listing stays drawn until the located window lands.
            var far = shell.windowedBack("report", 800)
            shell.locatedWindow(far, "/big/report", 1201, 1201, "report")
            shell.check("held-back-asks-locate-then-the-window", shell.sentShape() === "locate:/big/report,window:1201",
                shell.sentShape())
            shell.states("held-back-outside-the-window-lands-once", far, "1201|1201|64|2000|/big|ready")
            shell.check("the-landing-drops-the-restore", swap.restore === null && swap.parked === null,
                JSON.stringify(swap.restore))
        } else if (phase === 2) {
            // R0: the saved index sits inside the first window but the name moved out, so that row is another file.
            var inside = shell.windowedBack("report", 10)
            shell.locatedWindow(inside, "/big/report", 900, 900, "report")
            shell.states("r0-saved-index-inside-the-window-lights-no-stale-row", inside, "900|900|64|2000|/big|ready")
        } else if (phase === 3) {
            // The name is gone: the miss fetches the clamped index's window, which lands that index.
            var gone = shell.windowedBack("gone", 810)
            shell.locatedWindow(gone, "/big/gone", -1, 810, "")
            shell.check("a-miss-fetches-the-saved-index-window", shell.sentShape() === "locate:/big/gone,window:810",
                shell.sentShape())
            shell.states("a-miss-lands-the-clamped-index-once", gone, "810|810|64|2000|/big|ready")
            // An unheld Back, out of a loading pane, keeps its listed line: loading until the one landing.
            stubPane.listingState = "loading"
            var unheld = shell.windowedBack("report", 10)
            shell.locatedWindow(unheld, "/big/report", 1500, 1500, "report")
            shell.states("unheld-back-draws-loading-until-one-landing", unheld, "1500|1500|64|2000|/big|ready")
            // A refused located window (a stuck mount) lands the parked first window at the top and ends the listing.
            var refused = shell.windowedBack("report", 900)
            BackReturn.takeLocated(stubPane, { directory: "/big", path: "/big/report", index: 1300 })
            var parked = swap.landParked()
            shell.check("a-refused-window-lands-the-parked-rows-and-ends-the-listing", parked
                && shell.sig() === "0|0|64|2000|/big|ready" && !stubPane.listInFlight && swap.restore === null,
                parked + " " + shell.sig() + " inFlight=" + stubPane.listInFlight)
        } else if (phase === 4) {
            // A re-read of the open directory fails: the path is already the listed one.
            stubPane.path = "/d"
            stubPane.listInFlight = true
            stubPane.listedSeen = false
            stubPane.listingPath = "/d"
            stubBackend.sent = []
            swap.hold({ restore: BackReturn.makeEntry("/d", "far", 3) })
            swap.takeListed(3, 0.1, 0.2, "/d", null)
            // The failed listing ends the way ui/js/Swap.js failListing does: drop, then the flight ends.
            swap.drop()
            stubPane.listInFlight = false
            shell.check("real-failure-path-drops-the-armed-entry", swap.restore === null,
                "restore=" + JSON.stringify(swap.restore))
            // Late lines from the failed listing still arrive: without the drop they would land the name.
            swap.takeListed(3, 0.1, 0.2, "/d", null)
            swap.takeRows(0, [{ n: "b" }, { n: "x" }, { n: "far" }], [], 3)
            shell.check("rows-after-a-failure-land-at-the-top-though-far-sits-at-2", stubPane.cursorIndex === 0,
                "cursor=" + stubPane.cursorIndex)
        }
    }
}
