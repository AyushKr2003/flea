//@ pragma ShellId flea-gridjump-test

import QtQuick
import Quickshell
import "flea" as Flea
import "flea/js/Filter.js" as Filter
import "flea/js/Marks.js" as Marks
import "flea/js/Selection.js" as Selection

// gridjump: a real ui/GridArea.qml on 2000 rows counts what a far jump and a held j sweep rebind and how many window asks the sweep sends beside a real ui/List.qml; counts only, no time.
ShellRoot {
    id: root

    readonly property int files: 2000
    readonly property int areaWidth: 2368
    readonly property int areaHeight: 1350
    readonly property int sweepSteps: 70
    property var failures: []
    property var script: []
    property var moves: ({})
    property var sweeps: ({})
    property int warmPolls: 0
    property int warmStable: 0
    property int warmLast: -1
    // Every tile the probe has met with the counters its change signals feed; mutated in place, so no binding reads them.
    readonly property var meta: ({ tiles: [], reuse: 0, redundant: 0 })

    function log(line) { console.log("GRIDJUMP " + line) }
    function check(name, ok, detail) { if (!ok) { root.failures.push(name); root.log("FAIL " + name + " " + detail) } }
    function rowAt(i) {
        var n = String(i)
        while (n.length < 5) n = "0" + n
        return { n: "g_" + n + ".txt", d: false, i: "text-plain", p: 420, s: 0, m: 1758835200, t: false, k: 0, v: 0 }
    }
    function rowsFrom(from, to) { var out = []; for (var i = from; i < to; i++) out.push(root.rowAt(i)); return out }

    Component {
        id: backendStub
        QtObject {
            id: be
            property var pane: null
            property var queue: []
            property int asks: 0
            property int replies: 0
            property real heldListing: 1
            // "sync" answers inside the call, a reply that beats the layout; "late" answers on a timer, after it.
            property string mode: "late"
            function thumb(rows, cacheOnly) {}
            function thumbcancel(rows) {}
            function dirsize(rows) {}
            function dirsizecancel() {}
            function window(start, count) {
                be.asks += 1
                be.queue.push({ start: start, count: count })
                if (be.mode === "sync") be.reply()
                else answer.start()
            }
            // A reply is a parse, every row a new object, and the two writes are PaneSwap's: held first, rows second.
            function reply() {
                var ask = be.queue.shift()
                if (ask === undefined) return
                var from = Math.max(0, Math.min(ask.start, be.pane.total))
                be.pane.held = from
                be.pane.rows = root.rowsFrom(from, Math.min(be.pane.total, from + ask.count))
                be.replies += 1
            }
            property Timer answer: Timer {
                interval: 1
                onTriggered: { be.reply(); if (be.queue.length > 0) answer.start() }
            }
        }
    }

    Component { id: swapStub; QtObject { property bool searchWarm: false } }

    Component {
        id: paneStub
        QtObject {
            id: p
            property var area: null
            property string viewMode: "grid"
            property string path: "/probe"
            property var rows: []
            property var shown: null
            readonly property int shownTotal: shown === null ? total : shown.length
            property int total: 0
            property int held: 0
            property int cursorIndex: 0
            property int cursorSeq: 0
            property int cursorStride: 1
            property int renamingIndex: -1
            property int renameRequest: 0
            property string renameError: ""
            property bool renamePending: false
            property int selectionVersion: 0
            property int selectionAnchor: 0
            property var selection: Selection.create()
            property bool paneFocused: true
            property bool dualMode: false
            property var clipboard: ({ paths: [], moving: false })
            property var thumbState: ({ file: {}, order: [] })
            property var dirSizeState: ({ file: {}, order: [] })
            property var kindNames: []
            property string searchMode: ""
            property string searchQuery: ""
            property string recentMode: ""
            property string filterQuery: ""
            property double inputAt: 0
            property bool filterTyping: false
            property var selectionBand: null
            property int previewIndex: -1
            property bool storageKnown: true
            property string storageClass: ""
            property bool listInFlight: false
            property string listingState: "ready"
            property string focusView: "grid"
            // ui/Pane.qml's own sizing from the area's height, in list rows.
            readonly property int visibleRows: Math.max(1, Math.ceil(root.areaHeight / Flea.Theme.fileRowHeight))
            readonly property int cacheRows: 4
            readonly property int firstSettleMs: 70
            readonly property int settleMs: 120
            readonly property int coalesceMs: 16
            readonly property int refetchMargin: 25
            readonly property int buffer: 150
            readonly property int windowSize: p.visibleRows + 2 * p.buffer
            property var backend: null
            property var sidebar: null
            property var listArea: null
            property var swap: null
            // What the delegates' bindings call, counted in an object no binding reads.
            readonly property var tally: ({ isSelected: 0 })
            function join(base, name) { return String(base) + "/" + String(name) }
            function rowFor(index) { var o = index - p.held; return (o >= 0 && o < p.rows.length) ? p.rows[o] : null }
            function isSelected(index) { p.tally.isSelected += 1; return p.selectionVersion >= 0 && p.selection.has(index) }
            function selectedIndices() { return [] }
            function selectionCount() { return 0 }
            function thumbFor(index) { return "" }
            function setCursor(index, context) { Filter.setCursor(p, index, context) }
            // ui/Pane.qml showRow: the grid keeps Contain, the list its own scroll-off.
            function showRow(view, context) {
                if (p.viewMode === "list") p.area.showCursor(view, context)
                else p.area.positionViewAtIndex(view, GridView.Contain)
                p.area.restartCoalesce()
            }
            function slowClickWasSole(index) { return false }
            function pressSlowClick() {}
            function cancelSlowClick() {}
            function armSlowClick() {}
            function commitRename(newName) {}
            function focusRequested() {}
            function open(path) {}
            function openFile(path) {}
            function renameEditor() { return null }
            // PaneSwap.land: the rows go in before the count, from the top of the listing, cursor and selection on row 0.
            function land() {
                p.listInFlight = true
                p.total = 0
                p.held = 0
                p.rows = []
                p.cursorIndex = 0
                p.selection.only(0, true)
                p.selectionVersion += 1
                p.rows = root.rowsFrom(0, Math.min(root.files, p.windowSize))
                p.total = root.files
                p.listInFlight = false
            }
        }
    }

    Component {
        id: menuStub
        QtObject {
            function close() {}
            function openBackground(point) {}
        }
    }

    property var gridBackend: backendStub.createObject(root)
    property var listBackend: backendStub.createObject(root)
    property var gridPane: paneStub.createObject(root, { backend: root.gridBackend, swap: swapStub.createObject(root), viewMode: "grid" })
    property var listPane: paneStub.createObject(root, { backend: root.listBackend, viewMode: "list", focusView: "list" })
    property var stubMenu: menuStub.createObject(root)

    FloatingWindow {
        implicitWidth: root.areaWidth
        implicitHeight: root.areaHeight
        color: "black"
        Flea.GridArea { id: grid; width: root.areaWidth; height: root.areaHeight; pane: root.gridPane; menu: root.stubMenu }
    }

    FloatingWindow {
        implicitWidth: root.areaWidth
        implicitHeight: root.areaHeight
        color: "black"
        Flea.List { id: list; width: root.areaWidth; height: root.areaHeight; pane: root.listPane; menu: root.stubMenu }
    }

    // Delegates and parked tiles alive: a tile created in an action moves this up, a reuse does not.
    function tiles() {
        var out = [], kids = grid.contentItem.children
        for (var i = 0; i < kids.length; i++) if (kids[i].listingIndex !== undefined) out.push(kids[i])
        return out
    }
    function adopt() {
        var all = root.tiles()
        for (var i = 0; i < all.length; i++) if (root.meta.tiles.every(function (t) { return t.tile !== all[i] })) root.watch(all[i])
    }
    // One function per tile, so each handler closes over its own tile and counters; the first value a tile is built with is not a change.
    function watch(tile) {
        var m = root.meta, mine = { tile: tile, rows: 0, idx: tile.listingIndex, drawn: tile.row !== null }
        m.tiles.push(mine)
        tile.rowChanged.connect(function () {
            mine.rows += 1
            // The same listing row as at the last change, already drawn: whatever this change was, it drew nothing new.
            if (tile.listingIndex === mine.idx && mine.drawn) m.redundant += 1
            mine.idx = tile.listingIndex
            mine.drawn = tile.row !== null
        })
        tile.pooledChanged.connect(function () { if (!tile.pooled) m.reuse += 1 })
    }
    function snap() {
        root.adopt()
        return { asks: root.gridBackend.asks, replies: root.gridBackend.replies, objects: root.tiles().length + grid.prebuild.parkedCount, reuse: root.meta.reuse,
                 redundant: root.meta.redundant, isSelected: root.gridPane.tally.isSelected, rows: root.meta.tiles.map(function (t) { return t.rows }) }
    }
    // A tile met only after the first snapshot counts from zero.
    function delta(a, b) {
        var d = { created: b.objects - a.objects, reused: b.reuse - a.reuse, asks: b.asks - a.asks, replies: b.replies - a.replies,
                  unchanged: b.redundant - a.redundant, isSelected: b.isSelected - a.isSelected, rebound: 0, max: 0, changes: 0 }
        for (var i = 0; i < b.rows.length; i++) {
            var n = b.rows[i] - (i < a.rows.length ? a.rows[i] : 0)
            if (n > 0) d.rebound += 1
            d.max = Math.max(d.max, n)
            d.changes += n
        }
        return d
    }
    function line(name, d) {
        return name + " created=" + d.created + " reused=" + d.reused + " windows=" + d.asks + " replies=" + d.replies + " tilesRebound=" + d.rebound
            + " maxRebindsPerTile=" + d.max + " rowChanges=" + d.changes + " unchangedRowRebinds=" + d.unchanged + " isSelectedCalls=" + d.isSelected
    }

    // The actions are ui/js/Focus.js act() and ui/js/Grid.js arrow(): one filter move or set, then the selection follows.
    function moveTo(pane, view) { Filter.setCursorView(pane, view); Marks.follow(pane) }
    function moveBy(pane, step) { Filter.moveCursor(pane, step); Marks.follow(pane) }

    Timer { id: tick; onTriggered: root.runNext() }
    function later(ms) { tick.interval = ms; tick.start() }
    function runNext() {
        if (root.script.length === 0) { root.finish(); return }
        root.script.shift().call(root)
    }
    // One measured grid action, then 450 ms for the layout, the replies and the thumb timers.
    function measure(name, action) {
        var a = root.snap()
        action()
        root.script.unshift(function () {
            var d = root.delta(a, root.snap())
            root.moves[name] = d
            root.log(root.line("grid " + name, d))
            root.runNext()
        })
        root.later(450)
    }
    // The pool is warm when the prebuild driver has parked as many tiles as it will and stopped for five polls.
    function warm() {
        root.warmPolls = 0
        root.warmStable = 0
        root.warmLast = -1
        root.script.unshift(root.pollWarm)
        root.later(150)
    }
    function pollWarm() {
        root.warmPolls += 1
        var parked = grid.prebuild.parkedCount
        root.warmStable = parked === root.warmLast ? root.warmStable + 1 : 0
        root.warmLast = parked
        if ((root.warmStable >= 5 && grid.prebuild.want === 0) || root.warmPolls >= 80) { root.runNext(); return }
        root.script.unshift(root.pollWarm)
        root.later(120)
    }
    // A held sweep at the key repeat's rate, then the replies still in flight.
    function sweep(name, pane, step, count, interval) {
        var s = { name: name, pane: pane, step: step, left: count, interval: interval, a: root.snap(), asks: pane.backend.asks }
        root.script.unshift(function () { root.sweepStep(s) })
        root.runNext()
    }
    function sweepStep(s) {
        if (s.left > 0) {
            s.left -= 1
            root.moveBy(s.pane, s.step)
            root.script.unshift(function () { root.sweepStep(s) })
            root.later(s.interval)
            return
        }
        root.script.unshift(function () {
            var out = root.delta(s.a, root.snap())
            out.asks = s.pane.backend.asks - s.asks
            root.sweeps[s.name] = out
            root.log("sweep " + s.name + " windows=" + out.asks + " cursor=" + s.pane.cursorIndex + " held=" + s.pane.held + " rows=" + s.pane.rows.length + (s.pane === root.gridPane ? " " + root.line("", out) : ""))
            root.runNext()
        })
        root.later(500)
    }

    // A tile whose row a window no longer reaches keeps it while the listing is the same, and reads nothing once the listing moved.
    function staleCheck() {
        var tile = root.tiles().filter(function (t) { return t.live && t.listingIndex === 5 })[0], pane = root.gridPane, be = root.gridBackend
        root.check("stale: a tile at index 5 draws its row", tile && tile.row && tile.row.n === "g_00005.txt", "")
        pane.held = 100
        pane.rows = root.rowsFrom(100, 200)
        root.check("stale: the same listing keeps a row the window left", tile.row !== null && tile.row.n === "g_00005.txt", "row=" + JSON.stringify(tile.row))
        be.heldListing = 2
        pane.rows = root.rowsFrom(100, 200)
        root.check("stale: a new listing leaves no row behind", tile.row === null, "row=" + JSON.stringify(tile.row))
        root.runNext()
    }

    function verdict() {
        ["G", "g", "End", "Home"].forEach(function (name) {
            var d = root.moves[name + ".sync"]
            root.check(name + ": a far jump creates no tile once the pool is warm", d.created === 0, "created=" + d.created)
            root.check(name + ": a far jump rebinds a tile at most once", d.max <= 1, "max=" + d.max)
            root.check(name + ": a far jump asks one window", d.asks === 1, "windows=" + d.asks)
        })
        var g = root.sweeps.grid70, ref = root.sweeps["list" + (root.sweepSteps * grid.columns)]
        root.check("the list reference asks windows", ref.asks > 0, "windows=" + ref.asks)
        root.check("the held sweep asks no more windows than the list over as many rows", g.asks <= ref.asks, "grid=" + g.asks + " list=" + ref.asks)
        root.check("no rows replacement redraws a row a tile already drew", g.unchanged === 0, "unchanged=" + g.unchanged)
        root.check("a held sweep rebinds a tile about once per reuse", g.changes <= g.reused + 2 * grid.columns, "changes=" + g.changes + " reused=" + g.reused)
        root.runNext()
    }

    function build() {
        var s = root.script, last = root.files - 1
        function step(fn) { s.push(fn) }
        function jump(name, view) { step(function () { root.measure(name, function () { root.moveTo(root.gridPane, view) }) }) }
        function mode(name) { step(function () { root.gridBackend.mode = name; root.runNext() }) }
        step(function () {
            root.gridPane.area = grid
            root.gridPane.listArea = grid
            root.gridPane.cursorStride = Qt.binding(function () { return grid.columns })
            root.gridBackend.pane = root.gridPane
            root.listPane.area = list
            root.listPane.listArea = list
            root.listBackend.pane = root.listPane
            root.gridPane.land()
            root.listPane.land()
            root.warm()
        })
        step(function () {
            root.log("geometry columns=" + grid.columns + " cellHeight=" + grid.cellHeight + " visibleTileRows=" + grid.visibleTileRows + " landingTiles=" + grid.landingTiles
                + " held=" + root.gridPane.held + " rows=" + root.gridPane.rows.length + " plan=" + JSON.stringify(grid.windowPlan) + " listRows=" + root.gridPane.windowSize)
            root.check("the grid lays out 18 columns", grid.columns === 18, "columns=" + grid.columns)
            grid.forceActiveFocus()
            root.runNext()
        })
        // One round trip to each end warms the pool; the measured set then runs with the backend late and again with it quick.
        jump("warm.G", last)
        jump("warm.g", 0)
        mode("late")
        jump("G", last)
        jump("g", 0)
        jump("End", last)
        jump("Home", 0)
        mode("sync")
        jump("G.sync", last)
        jump("g.sync", 0)
        jump("End.sync", last)
        jump("Home.sync", 0)
        mode("late")
        // The held sweep on a fresh landing, then the same keys in the list, and the list over as many rows as the grid crossed.
        step(function () { root.gridPane.land(); root.warm() })
        step(function () { root.sweep("grid70", root.gridPane, grid.columns, root.sweepSteps, 34) })
        step(function () { root.listPane.land(); root.later(800) })
        step(function () { root.sweep("list70", root.listPane, 1, root.sweepSteps, 34) })
        step(function () { root.listPane.land(); root.later(800) })
        step(function () { root.sweep("list" + (root.sweepSteps * grid.columns), root.listPane, 1, root.sweepSteps * grid.columns, 20) })
        step(function () { root.gridPane.land(); root.warm() })
        step(root.staleCheck)
        step(root.verdict)
    }

    function finish() {
        root.log("DONE failures=" + root.failures.length)
        Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }

    Timer { interval: 120000; running: true; onTriggered: { root.check("timeout", false, ""); root.finish() } }

    Component.onCompleted: {
        // Stock Omarchy's size: 125 px minimum cells, so a 2368 px grid lays out 18 columns.
        Flea.ViewState.setTextSize({ mode: 12 })
        root.build()
        root.later(700)
    }
}
