//@ pragma ShellId flea-flingframe-test

import QtQuick
import Quickshell
import "flea" as Flea

// flingframe: a fling scrolls List, Grid and Columns by a few rows a frame, and each frame is counted (delegates built, rebound, texts changed, row reads, backend asks), never timed.
ShellRoot {
    id: root

    property var failures: []
    property bool finished: false
    property var kinds: ["list", "grid", "columns"]
    property int kindAt: -1
    property string phase: "idle"
    property double phaseAt: 0
    property double deadline: 0
    // Rows a frame (tile rows in Grid) the fling moves by, and the frames it runs.
    property var speeds: [1, 3, 6]
    property int speedAt: 0
    property var starts: ["top", "mid"]
    property int startAt: 0
    property var costs: []
    property int trial: 0
    property var wheelBefore: null
    property int frameAt: 0
    readonly property int frames: 20
    property var before: null
    property var samples: []
    property var tallyBefore: null
    property var summary: ({})
    property string kind: "list"

    function pad(i) { var n = String(i); while (n.length < 5) n = "0" + n; return n }
    function rowsFor(count) {
        var out = []
        for (var i = 0; i < count; i++)
            out.push({ n: "f_" + root.pad(i) + ".txt", d: false, i: "text-plain", p: 420, s: i * 7, m: 1758835200 + i * 60, t: false, k: 0, v: 0 })
        return out
    }
    property var bigRows: root.rowsFor(3000)

    Component {
        id: backendStub
        QtObject {
            id: stub
            signal peeked(string path, bool hidden, int total, var rows, bool readFailed, int mode, bool hiddenLast, int first, int dev, bool writable, string by, bool desc)
            property int dirDev: 0
            property string sortBy: "name"
            property bool sortDesc: false
            function peek(path, size, hidden) {
                var p = String(path)
                Qt.callLater(function () { var rows = root.rowsFor(6); stub.peeked(p, false, rows.length, rows, false, 0, false, 35, 0, true, "", false) })
            }
            function thumb(rows, cacheOnly) { root.tally.thumb += 1 }
            function thumbcancel(rows) { root.tally.thumbcancel += 1 }
            function dirsize(rows) { root.tally.dirsize += 1 }
            function dirsizecancel() { root.tally.dirsizecancel += 1 }
            function window(start, count) { root.tally.window += 1 }
            function askMeta(index, text, media, archive) { root.tally.askMeta += 1; return 0 }
        }
    }

    Component { id: swapStub; QtObject { property bool searchWarm: false } }

    Component {
        id: paneStub
        QtObject {
            id: pane
            property string path: "/probe"
            property var rows: []
            property var shown: null
            readonly property int shownTotal: shown === null ? total : shown.length
            property int total: 0
            property int held: 0
            property int cursorIndex: 0
            property int renamingIndex: -1
            property int renameRequest: 0
            property string renameError: ""
            property bool renamePending: false
            property int selectionVersion: 0
            property bool paneFocused: true
            property bool dualMode: false
            property bool showHidden: false
            property var trash: ({ opened: false })
            property var clipboard: ({ paths: [], moving: false })
            property var thumbState: ({ file: {}, order: [] })
            property var dirSizeState: ({ file: {}, order: [] })
            property var kindNames: []
            property string searchMode: ""
            property string searchQuery: ""
            property string recentMode: ""
            property string filterQuery: ""
            property bool filterTyping: false
            property var selectionBand: null
            property int previewIndex: -1
            property bool storageKnown: true
            property string storageClass: ""
            property bool listInFlight: false
            property string listingState: "ready"
            property string pendingSelect: ""
            property bool pendingMenu: false
            property string focusView: "list"
            property string viewMode: "list"
            property int cursorStride: 17
            property double inputAt: 0
            property int rowsAt: 0
            property string keySequence: ""
            property string keySequenceIdentity: ""
            property int trashArmedAt: 0
            property int visibleRows: 43
            property int cacheRows: 4
            property int firstSettleMs: 70
            property int settleMs: 120
            property int coalesceMs: 16
            property int refetchMargin: 25
            property int buffer: 150
            property int windowSize: 35
            property var backend: null
            property var sidebar: null
            property var listArea: null
            property var swap: null
            onCursorIndexChanged: root.tally.cursor += 1
            function renameEditor() { return null }
            function join(base, name) { return String(base) + "/" + String(name) }
            function rowFor(index) { root.tally.rowFor += 1; var o = index - held; return (o >= 0 && o < rows.length) ? rows[o] : null }
            function isSelected(index) { root.tally.isSelected += 1; return false }
            function selectedIndices() { return [] }
            function selectionCount() { return 0 }
            function thumbFor(index) { return "" }
            function setCursor(index, mode) { cursorIndex = index }
            function slowClickWasSole(index) { return false }
            function pressSlowClick() {}
            function cancelSlowClick() {}
            function armSlowClick() {}
            function commitRename(newName) {}
            function open(path) {}
            function openFile(path) {}
            function focusRequested() {}
        }
    }
    Component { id: menuStub; QtObject { function close() {} function openBackground(point) {} } }

    property var tally: ({ rowFor: 0, isSelected: 0, thumb: 0, thumbcancel: 0, dirsize: 0, dirsizecancel: 0, window: 0, askMeta: 0, cursor: 0, clamped: 0 })
    property var stubBackend: backendStub.createObject(root)
    property var stubPane: paneStub.createObject(root, { backend: root.stubBackend, swap: swapStub.createObject(root) })

    FloatingWindow {
        implicitWidth: 2536
        implicitHeight: 1389
        color: "black"
        Loader { id: viewLoader; width: 2536; height: 1381 }
    }
    Component { id: listView; Flea.List { width: 2536; height: 1381; pane: root.stubPane; menu: menuStub.createObject(root) } }
    Component { id: gridView; Flea.GridArea { width: 2536; height: 1381; pane: root.stubPane; menu: menuStub.createObject(root) } }
    Component { id: columnsView; Flea.ColumnsArea { width: 2536; height: 1381; pane: root.stubPane; menu: menuStub.createObject(root) } }

    // The flickable that scrolls and the object that owns its prebuild driver.
    function view() {
        var top = viewLoader.item
        if (!top) return null
        return root.kind === "columns" ? top.activeColumn().viewport : top
    }
    function driver() {
        var top = viewLoader.item
        if (!top) return null
        return root.kind === "columns" ? top.activeColumn().prebuild : top.prebuild
    }
    function delegates() {
        var out = [], v = root.view()
        if (!v || !v.contentItem) return out
        var kids = v.contentItem.children
        for (var i = 0; i < kids.length; i++)
            if (kids[i].listingIndex !== undefined) out.push(kids[i])
        return out
    }
    // Every string a delegate draws, in tree order, so a text that moved is a layout the frame paid.
    function textsOf(item, out) {
        if (typeof item.text === "string") out.push(item.text)
        var kids = item.children
        for (var i = 0; kids !== undefined && i < kids.length; i++) root.textsOf(kids[i], out)
        return out
    }
    function snap() {
        var d = root.driver(), all = root.delegates(), at = new Map()
        for (var i = 0; i < all.length; i++)
            at.set(all[i], { index: all[i].listingIndex, live: all[i].live === true, texts: root.textsOf(all[i], []).join("|") })
        return { created: d.createdCount, destroyed: d.destroyedCount, delegates: all.length, at: at, tally: Object.assign({}, root.tally) }
    }
    function diff(a, b) {
        var rebound = 0, texts = 0, entered = 0
        b.at.forEach(function (now, cell) {
            var was = a.at.get(cell)
            if (!was) return
            if (now.live && (now.index !== was.index || !was.live)) rebound += 1
            if (now.live && now.texts !== was.texts) texts += 1
            if (now.live && !was.live) entered += 1
        })
        var t = {}
        for (var k in b.tally) t[k] = b.tally[k] - a.tally[k]
        return { created: b.created - a.created, destroyed: b.destroyed - a.destroyed, rebound: rebound, texts: texts, tally: t }
    }

    function land(path, total, rows) {
        var p = root.stubPane
        p.listInFlight = true
        p.total = 0
        p.held = 0
        p.rows = []
        p.cursorIndex = 0
        p.listingState = "loading"
        p.rows = rows
        p.total = total
        p.path = path
        p.listingState = "ready"
        p.listInFlight = false
    }

    function go(next) { root.phase = next; root.phaseAt = Date.now() }
    function elapsed() { return Date.now() - root.phaseAt }
    function stepPx() {
        var v = root.view()
        var h = root.kind === "grid" ? v.cellHeight : Flea.Theme.fileRowHeight
        return root.speeds[root.speedAt] * h
    }

    function mean(list, pick) { var sum = 0; for (var i = 0; i < list.length; i++) sum += pick(list[i]); return sum / list.length }
    // A fling frame does the work of the rows entering and nothing else: no backend ask, no build once the pool is full, no read or rebind of a row that stayed.
    function report() {
        var s = root.samples, n = s.length, rows = root.speeds[root.speedAt], start = root.starts[root.startAt]
        var per = rows * (root.kind === "grid" ? root.view().columns : 1)
        var m = { created: root.mean(s, function (x) { return x.created }), destroyed: root.mean(s, function (x) { return x.destroyed }),
                  rebound: root.mean(s, function (x) { return x.rebound }), texts: root.mean(s, function (x) { return x.texts }) }
        var keys = ["rowFor", "isSelected", "thumb", "thumbcancel", "dirsize", "dirsizecancel", "window", "askMeta", "cursor", "clamped"]
        for (var k = 0; k < keys.length; k++) m[keys[k]] = root.mean(s, function (x) { return x.tally[keys[k]] })
        var cs = root.costs.slice().sort(function (a, b) { return a - b; }), csum = 0
        for (var c = 0; c < cs.length; c++) csum += cs[c]
        var line = "FLINGFRAME " + root.kind + " " + start + " rows=" + rows + " frames=" + n
        for (var name in m) line += " " + name + "=" + m[name].toFixed(2)
        console.log(line + " writeMs=" + (csum / cs.length).toFixed(2) + "/" + cs[cs.length - 1])
        var tag = root.kind + " " + start + " rows=" + rows + ": "
        var asks = m.thumb + m.thumbcancel + m.dirsize + m.dirsizecancel + m.window + m.askMeta
        if (asks > 0) root.failures.push(tag + asks.toFixed(2) + " backend asks a frame, want 0")
        if (start === "mid" && m.created > 0) root.failures.push(tag + m.created.toFixed(2) + " delegates built a frame, want 0")
        if (m.rebound > per + 0.5) root.failures.push(tag + m.rebound.toFixed(2) + " rows rebound a frame, want at most " + per)
        // A row built or rebound is a row entering; a read past that is a row that stayed.
        var entering = m.rebound + m.created
        if (m.texts > entering + 0.5) root.failures.push(tag + m.texts.toFixed(2) + " rows changed text a frame, entering " + entering.toFixed(2))
        if (m.rowFor > 2 * entering + 0.5) root.failures.push(tag + m.rowFor.toFixed(2) + " row reads a frame, entering " + entering.toFixed(2))
        if (m.isSelected > entering + 0.5) root.failures.push(tag + m.isSelected.toFixed(2) + " selection reads a frame, entering " + entering.toFixed(2))
        if (m.cursor > 1.01 || m.clamped > 1.01) root.failures.push(tag + "cursor moved " + m.cursor.toFixed(2) + " and clamped " + m.clamped.toFixed(2) + " a frame, want at most 1")
    }

    function finish() {
        if (root.finished) return
        root.finished = true
        if (root.failures.length > 0) console.log("FLINGFRAME FAIL " + root.failures.slice(0, 8).join("; "))
        else console.log("FLINGFRAME DONE")
        Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }

    function nextKind() {
        root.kindAt += 1
        if (root.kindAt >= root.kinds.length) { root.finish(); return }
        root.kind = root.kinds[root.kindAt]
        root.stubPane.focusView = root.kind
        root.stubPane.viewMode = root.kind
        root.speedAt = 0
        root.startAt = 0
        viewLoader.sourceComponent = root.kind === "list" ? listView : root.kind === "grid" ? gridView : columnsView
        root.deadline = Date.now() + 8000
        root.go("mount")
    }

    Timer {
        interval: 16
        running: true
        repeat: true
        onTriggered: {
            if (root.finished) return
            var v = root.view(), d = root.driver()
            if (root.phase === "idle") {
                root.nextKind()
            } else if (root.phase === "mount") {
                if (!v || !d) return
                if (root.elapsed() < 300) return
                root.land("/probe", 3000, root.bigRows)
                if (typeof v.cursorClamped === "function" || v.cursorClamped !== undefined)
                    v.cursorClamped.connect(function (first, last) {
                        root.tally.clamped += 1
                        var p = root.stubPane
                        var to = Math.max(first, Math.min(last, p.cursorIndex))
                        if (to !== p.cursorIndex) p.cursorIndex = to
                    })
                root.deadline = Date.now() + 8000
                root.go("fill")
            } else if (root.phase === "fill") {
                // The pool is full once the driver wants nothing, and the first landing's hold has ended.
                if (root.elapsed() < d.holdMs + 300) return
                if (d.want > 0 && Date.now() < root.deadline) return
                console.log("FLINGFRAME " + root.kind + " pool delegates=" + root.delegates().length + " parked=" + d.parkedCount + " want=" + d.want + " created=" + d.createdCount + " cols=" + (v.columns !== undefined ? v.columns : 1))
                root.go("rewind")
            } else if (root.phase === "rewind") {
                var h = root.kind === "grid" ? v.cellHeight : Flea.Theme.fileRowHeight
                v.contentY = v.originY - v.topMargin + (root.starts[root.startAt] === "mid" ? (root.kind === "grid" ? 40 : 400) * h : 0)
                root.samples = []
                root.costs = []
                root.frameAt = 0
                if (root.elapsed() < 400) return
                root.before = root.snap()
                root.go("fling")
            } else if (root.phase === "fling") {
                // One frame: read what the last write cost, then write the next step.
                var now = root.snap()
                if (root.frameAt > 0) root.samples.push(root.diff(root.before, now))
                root.before = now
                if (root.frameAt >= root.frames) {
                    root.report()
                    root.speedAt += 1
                    if (root.speedAt >= root.speeds.length) {
                        root.speedAt = 0
                        root.startAt += 1
                        if (root.startAt >= root.starts.length) { root.trial = 0; root.costs = []; root.go("wheelrewind"); return }
                    }
                    root.go("rewind")
                    return
                }
                root.frameAt += 1
                var t0 = Date.now()
                v.contentY = v.contentY + root.stepPx()
                v.forceLayout()
                root.costs.push(Date.now() - t0)
            } else if (root.phase === "wheelrewind") {
                // A fresh stroke from rest in the middle: its Begin and first two updates through the real wheel handler, then the layout.
                var hh = root.kind === "grid" ? v.cellHeight : Flea.Theme.fileRowHeight
                v.contentY = v.originY - v.topMargin + (root.kind === "grid" ? 40 : 400) * hh
                if (root.elapsed() < 200) return
                root.wheelBefore = root.snap()
                var hand = null, kids = v.children
                for (var w = 0; w < kids.length; w++) if (kids[w].objectName === "fleaScroll") hand = kids[w]
                if (!hand) { root.failures.push("wheel: no handler in " + root.kind); root.go("done"); return }
                var y0 = v.contentY, t1 = Date.now()
                hand.handleWheel({ phase: Qt.ScrollBegin, pixelDelta: Qt.point(0, 0), angleDelta: Qt.point(0, 0), modifiers: 0, accepted: false })
                var took = hand.handleWheel({ phase: Qt.ScrollUpdate, pixelDelta: Qt.point(0, -20), angleDelta: Qt.point(0, 0), modifiers: 0, accepted: false })
                hand.handleWheel({ phase: Qt.ScrollUpdate, pixelDelta: Qt.point(0, -20), angleDelta: Qt.point(0, 0), modifiers: 0, accepted: false })
                v.forceLayout()
                root.costs.push(Date.now() - t1)
                var moved = root.diff(root.wheelBefore, root.snap())
                if (root.trial === 0) console.log("FLINGFRAME " + root.kind + " wheel first stroke accepted=" + took + " moved=" + (v.contentY - y0) + "px rebound=" + moved.rebound + " created=" + moved.created + " cursor=" + moved.tally.cursor + " asks=" + (moved.tally.thumb + moved.tally.thumbcancel + moved.tally.window))
                if (v.contentY === y0) root.failures.push("wheel: the handler moved " + root.kind + " by 0 px")
                root.trial += 1
                if (root.trial >= 20) {
                    var wc = root.costs.slice(), ws = 0, wm = 0
                    for (var x = 0; x < wc.length; x++) { ws += wc[x]; wm = Math.max(wm, wc[x]) }
                    console.log("FLINGFRAME " + root.kind + " wheel trials=" + wc.length + " beginPlusTwoUpdatesMs=" + (ws / wc.length).toFixed(2) + "/" + wm)
                    root.go("done")
                    return
                }
                root.go("wheelrewind")
            } else if (root.phase === "done") {
                viewLoader.sourceComponent = undefined
                root.nextKind()
            }
        }
    }

    Timer {
        interval: 110000
        running: true
        onTriggered: { root.failures.push("timeout in " + root.kind + " phase " + root.phase); root.finish() }
    }
    Component.onCompleted: Flea.ViewState.setTextSize({ mode: 14 })
}
