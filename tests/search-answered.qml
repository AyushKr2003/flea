//@ pragma ShellId flea-search-answered-test

import QtQuick
import Quickshell
import "flea" as Flea
import "flea/js/Search.js" as Search
import "flea/js/Match.js" as Match

// A key struck in a live search changes only the strip: every row keeps drawing the query it answered until the next answer lands.
ShellRoot {
    id: root

    readonly property string fixture: Quickshell.env("ANSWERED_DIR")
    readonly property int tickMs: 20
    readonly property int giveUpMs: 8000
    readonly property int sampled: 10
    // Each op strikes with no event loop between the key and the snapshots, so the held frame is the one a key frame draws.
    readonly property var ops: [
        { open: true }, { start: true }, { strike: "n" }, { strike: "o" }, { strike: "r" }, { back: true }, { settle: 300 }
    ]
    property int at: 0
    property var awaiting: null
    property double stamp: Date.now()
    property int checks: 0
    property int failures: 0
    property var pane: null
    property var keys: null
    property int gen: 0
    property string query: ""
    property bool ticking: false

    function check(label, actual, expected) {
        root.checks += 1
        var ok = JSON.stringify(actual) === JSON.stringify(expected)
        if (!ok) root.failures += 1
        console.log("SEARCHANSWERED " + (ok ? "PASS " : "FAIL ") + label + " got=" + JSON.stringify(actual) + " expected=" + JSON.stringify(expected))
    }
    function finish() {
        console.log("SEARCHANSWERED DONE checks=" + root.checks + " failed=" + root.failures)
        Qt.exit(root.failures > 0 ? 1 : 0)
    }
    // What each drawn row of the first window shows: its name, location and mark, and which layout it is in.
    function frame() {
        var out = []
        for (var i = 0; i < root.sampled; i++) {
            var item = root.pane.visibleItemFor(i)
            out.push(item && item.visible && item.row
                ? { n: item.row.n, name: item.displayName, where: item.locationText, run: item.nameRun, searching: item.searching } : null)
        }
        return out
    }
    function drawn(frame) { return frame.filter(function (cell) { return cell !== null }).length }
    // The newest sent gen answered and its walk over.
    function answered() { return root.pane.searchGen === root.gen && !root.pane.searchRunning && root.pane.searchSettledAt >= root.pane.searchKeyAt }
    function landed() { return !root.pane.listInFlight && root.pane.searchMode.length === 0 && root.pane.total > 0 && root.drawn(root.frame()) > 0 }

    FloatingWindow {
        id: win
        implicitWidth: 1400
        implicitHeight: 800
        color: Flea.Theme.color.background
    }
    Flea.Backend { id: realBackend }
    Component {
        id: paneComponent
        Flea.Pane {
            width: 1400
            height: 800
            backend: realBackend
        }
    }

    Timer {
        interval: root.tickMs
        running: true
        repeat: true
        onTriggered: {
            if (root.ticking) return
            root.ticking = true
            try { root.tick() } finally { root.ticking = false }
        }
    }

    function tick() {
        if (Date.now() - root.stamp > root.giveUpMs) {
            root.check("probe completes", "timeout at op " + root.at + " " + JSON.stringify(root.ops[root.at - 1]), "complete")
            root.finish()
            return
        }
        if (root.awaiting !== null && !root.awaiting()) return
        root.awaiting = null
        if (root.at >= root.ops.length) {
            root.finish()
            return
        }
        root.stamp = Date.now()
        root.run(root.ops[root.at])
        root.at += 1
    }

    // One key in the same JS turn as its two snapshots: nothing arrives from the backend between them.
    function strike(character, label) {
        var before = root.frame()
        root.gen += 1
        if (character === "BS") Search.shrink(root.pane)
        else Search.extend(root.pane, character)
        root.query = root.pane.searchQuery
        var held = root.frame()
        root.check(label + " the key frame draws the answered rows", root.drawn(before) > 0 && JSON.stringify(held) === JSON.stringify(before), true)
        root.check(label + " the strip echoes the key", root.pane.searchQuery, root.query)
        var sent = root.gen
        var query = root.query
        // The answer lands with its rows and marks in one sample: no drawn row names a file that does not hold the new query.
        root.awaiting = function () {
            if (!root.answered()) return false
            var stamps = Search.stamps(root.pane)
            console.log("SEARCHANSWERED STAMPS " + label + " keyToFirstRows=" + (stamps.firstRowsAt - stamps.keyAt) + "ms keyToSettled=" + (stamps.settledAt - stamps.keyAt) + "ms")
            var now = root.frame()
            root.check(label + " rows and marks both answer the new query", now.every(function (cell) {
                return cell === null || (cell.searching && JSON.stringify(cell.run) === JSON.stringify(Match.run(cell.name, query)))
            }), true)
            return true
        }
    }

    function run(op) {
        if (op.open) {
            Flea.ViewState.changeKey("view", "list")
            root.pane = paneComponent.createObject(win.contentItem)
            root.keys = Qt.createQmlObject("import QtTest; TestEvent {}", root.pane.listArea)
            root.pane.open(root.fixture)
            root.awaiting = function () { return root.landed() }
        } else if (op.start) {
            root.pane.listArea.forceActiveFocus()
            root.keys.keyClickChar("f", Qt.NoModifier, -1)
            root.awaiting = function () { return root.pane.searchMode === "typing" }
        } else if (op.strike !== undefined) {
            // The first character meets the folder's own listing: its layout and marks stay until the first answer.
            var listing = root.query.length === 0
            if (listing) root.check("the folder lists before the first key", root.frame().every(function (cell) { return cell === null || !cell.searching }), true)
            root.strike(op.strike, "key " + (root.query.length + 1) + (listing ? " from the listing" : ""))
        } else if (op.back) {
            root.strike("BS", "backspace")
        } else if (op.settle !== undefined) {
            // Rows still building at exit warn as items in creation at engine destruction.
            var until = Date.now() + op.settle
            root.awaiting = function () { return Date.now() >= until }
        }
    }
}
