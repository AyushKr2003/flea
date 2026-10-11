//@ pragma ShellId flea-gridprebuild-test

import QtQuick
import Quickshell
import QtTest
import "flea" as Flea

// gridprebuild: a 1-row grid prebuilds parked tiles with no parent, a 1000-row
// landing builds none in its turn, nothing runs after it, back builds nothing,
// hide drains all, and a key holds the driver off for 16 ms.
ShellRoot {
    id: root

    property var failures: []
    property int stage: 0
    property bool finished: false
    property var bigCache: []
    property var parentRows: [{ n: "big", d: true, i: "folder", p: 493, s: 0, m: 1758835200, t: false, k: 0, v: 0 }]
    property int warmTarget: 0; property int landTotalBefore: 0
    property int parkedBefore: 0; property int liveBefore: 0
    property double landAt: 0; property double keyAt0: 0
    property double keyAt8: 0; property double tickBefore0: 0
    property double tickBefore8: 0; property int pollCount: 0
    property int stableCount: 0; property int lastParked: -1; property int fStep: 0

    function pad(i) { var n = String(i); while (n.length < 4) n = "0" + n; return n }
    function buildBig() {
        var out = []
        for (var i = 0; i < 1000; i++) out.push({ n: "g_" + root.pad(i) + ".txt", d: false, i: "text-plain", p: 420, s: 0, m: 1758835200, t: false, k: 0, v: 0 })
        return out
    }

    Component {
        id: backendStub
        QtObject {
            function thumb(rows, cacheOnly) {}
            function thumbcancel(rows) {}
            function dirsize(rows) {}
            function dirsizecancel() {}
            function window(start, count) {}
        }
    }

    Component {
        id: swapStub
        QtObject { property bool searchWarm: false }
    }

    Component {
        id: paneStub
        QtObject {
            property string path: "/probe"
            property var rows: []
            property var shown: null
            readonly property int shownTotal: shown === null ? total : shown.length
            property int total: 0; property int held: 0
            property int cursorIndex: 0; property int renamingIndex: -1
            property int renameRequest: 0; property string renameError: ""
            property bool renamePending: false; property int selectionVersion: 0
            property bool paneFocused: true; property bool dualMode: false
            property bool showHidden: false; property var trash: ({ opened: false })
            property var clipboard: ({ paths: [], moving: false })
            property var thumbState: ({ file: {}, order: [] })
            property var dirSizeState: ({ file: {}, order: [] })
            property var kindNames: []
            property string searchMode: ""; property string searchQuery: ""
            property string recentMode: ""; property string filterQuery: ""
            property string viewMode: "grid"; property int cursorStride: 17
            property int inputAt: 0; property int rowsAt: 0
            property string keySequence: ""; property string keySequenceIdentity: ""
            property int trashArmedAt: 0
            function renameEditor() { return null }
            property bool filterTyping: false; property var selectionBand: null
            property int previewIndex: -1; property bool storageKnown: true
            property string storageClass: ""; property bool listInFlight: false
            property string listingState: "ready"; property string pendingSelect: ""
            property bool pendingMenu: false; property string focusView: "grid"
            property int visibleRows: 43; property int cacheRows: 2
            property int firstSettleMs: 70; property int settleMs: 120
            property int coalesceMs: 16; property int refetchMargin: 25
            property int buffer: 150; property int windowSize: 35
            property var backend: null; property var sidebar: null
            property var listArea: null; property var swap: null
            function join(base, name) { return String(base) + "/" + String(name) }
            function rowFor(index) { var o = index - held; return (o >= 0 && o < rows.length) ? rows[o] : null }
            function isSelected(index) { return false }
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

    Component {
        id: menuStub
        QtObject {
            function close() {}
            function openBackground(point) {}
        }
    }

    property var stubBackend: backendStub.createObject(root)
    property var stubSwap: swapStub.createObject(root)
    property var stubPane: paneStub.createObject(root, { backend: root.stubBackend, swap: root.stubSwap })

    FloatingWindow {
        implicitWidth: 2536
        implicitHeight: 1381
        color: "black"
        Flea.GridArea {
            id: grid
            width: 2536
            height: 1381
            pane: root.stubPane
            menu: menuStub.createObject(root)
        }
        TestEvent { id: driver }
    }

    function fail(text) { root.failures.push(text) }

    function delegates() {
        var out = []
        var kids = grid.contentItem.children
        for (var i = 0; i < kids.length; i++)
            if (kids[i].listingIndex !== undefined) out.push(kids[i])
        return out
    }
    function liveCount() {
        var n = 0, all = root.delegates()
        for (var i = 0; i < all.length; i++) if (all[i].live) n++
        return n
    }
    function parked() {
        if (typeof grid.parkedCount === "undefined") return -1
        return grid.parkedCount
    }
    function persisted() {
        if (!grid.model || !grid.model.persistedItems) return -1
        return grid.model.persistedItems.count
    }
    function totalDelegates() { return root.liveCount() + root.parked() }
    function hasPrebuild() { return typeof grid.prebuildLastTickAt !== "undefined" }

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

    // Case a: one row settled, driver idle, parked equals warm minus one.
    function checkA() {
        root.warmTarget = grid.model.warmRows
        var parked = root.parked()
        console.log("GRIDPREBUILD a warmRows=" + root.warmTarget + " count=" + grid.count + " parked=" + parked + " persisted=" + root.persisted())
        if (typeof grid.parkedCount === "undefined") {
            root.fail("a: no parkedCount on this GridArea, want the prebuild counter")
            return
        }
        if (parked !== root.warmTarget - 1)
            root.fail("a: parked=" + parked + " want warmRows-1=" + (root.warmTarget - 1))
        var all = root.delegates()
        for (var i = 0; i < all.length; i++) {
            if (all[i].prebuilt === true && all[i].parent !== null && all[i].parent !== undefined)
                root.fail("a: a prebuilt tile is parented")
        }
        // What index reads past the shown group, logged before relying on it.
        var probe = [], k = grid.count, end = Math.min(grid.count + 3, root.warmTarget)
        for (; k < end; k++) { var it = grid.itemAtIndex(k); probe.push(k + ":" + (it ? it.index + "/" + it.pooled + "/" + it.prebuilt + "/" + (it.parent === null) : "null")) }
        console.log("GRIDPREBUILD a indexProbe " + probe.join(" "))
        var tile0 = grid.itemAtIndex(0)
        if (!tile0) {
            root.fail("a: no tile at index 0")
            return
        }
        var local = grid.contentItem.mapFromItem(tile0, tile0.width / 2, tile0.height / 2)
        var hit = grid.contentItem.childAt(local.x, local.y)
        console.log("GRIDPREBUILD a hit0=" + (hit === tile0 ? 1 : 0))
        if (hit !== tile0)
            root.fail("a: childAt on tile 0 missed")
    }

    // Case b: the landing turn itself builds nothing and draws whole.
    function checkB() {
        var all = root.delegates()
        var built = root.totalDelegates() - (root.liveBefore + root.parkedBefore)
        console.log("GRIDPREBUILD b built=" + built + " alive=" + all.length + " count=" + grid.count)
        if (built !== 0)
            root.fail("b: landing built " + built + " delegates in its turn, want 0")
        var cols = grid.columns, first = 0
        var rows = Math.ceil(grid.height / grid.cellHeightPx)
        var last = Math.min(grid.count - 1, (rows + 1) * cols - 1)
        var bad = 0
        for (var i = first; i <= last; i++) {
            var it = grid.itemAtIndex(i)
            if (!it || !it.live || it.parent !== grid.contentItem || !it.row
                    || it.row.n !== root.bigCache[i].n || !it.captionItem || it.captionItem.text.length === 0) {
                bad++
                if (bad <= 3) console.log("GRIDPREBUILD b bad i=" + i + (it ? " live=" + it.live + " row=" + (it.row ? it.row.n : "null") : " null"))
            }
        }
        console.log("GRIDPREBUILD b wholeBad=" + bad + "/" + (last - first + 1))
        if (bad !== 0)
            root.fail("b: " + bad + " viewport tiles not whole in the landing turn")
        if (root.stubPane.cursorIndex !== 0 || grid.currentIndex !== 0)
            root.fail("b: cursor not on row 0 (pane=" + root.stubPane.cursorIndex + " view=" + grid.currentIndex + ")")
    }

    Timer { id: stageTimer; interval: 120; repeat: false; onTriggered: root.advance() }
    Timer { id: pollTimer; interval: 120; repeat: true; onTriggered: root.poll() }
    Timer { id: watchTimer; interval: 50; repeat: true; onTriggered: root.watch() }
    Timer { id: fTimer; interval: 10; repeat: false; onTriggered: root.stepF() }

    function advance() {
        if (root.stage === 0) {
            root.bigCache = root.buildBig()
            root.land("/probe", 1, root.parentRows)
            root.stage = 1
            root.lastParked = -1
            root.stableCount = 0
            root.pollCount = 0
            pollTimer.start()
        }
    }

    // Poll until the driver idles: parked stable for 5 polls or 60 tries.
    function poll() {
        root.pollCount++
        var parked = root.parked()
        if (parked === root.lastParked) root.stableCount++
        else { root.stableCount = 0; root.lastParked = parked }
        if (root.stableCount >= 5 || root.pollCount >= 60) {
            pollTimer.stop()
            root.checkA()
            // Snapshot then land 1000 rows in this same turn for case b, even red.
            root.liveBefore = root.liveCount()
            root.parkedBefore = root.parked()
            root.land("/probe/big", 1000, root.bigCache)
            root.landAt = Date.now()
            root.checkB()
            root.landTotalBefore = root.totalDelegates()
            root.stage = 3
            watchTimer.start()
        }
    }

    property int watchTicks: 0; property double watchTickMark: 0
    // Case c: 300 ms after the landing turn, nothing created and no tick ran.
    function watch() {
        root.watchTicks++
        if (root.hasPrebuild()) {
            if (root.watchTicks === 1) root.watchTickMark = grid.prebuildLastTickAt
            else if (grid.prebuildLastTickAt !== root.watchTickMark)
                root.fail("c: a prebuild tick ran " + (Date.now() - root.landAt) + " ms after the landing turn")
        }
        if (root.watchTicks * 50 >= 300) {
            watchTimer.stop()
            var now = root.totalDelegates()
            console.log("GRIDPREBUILD c totalBefore=" + root.landTotalBefore + " totalAfter=" + now)
            if (now !== root.landTotalBefore)
                root.fail("c: " + (now - root.landTotalBefore) + " delegates created in the 300 ms after the landing turn")
            // Case d: back to one row builds nothing, total within one screenful.
            var lb = root.liveCount(), pb = root.parked()
            root.land("/probe", 1, root.parentRows)
            var built = root.totalDelegates() - (lb + pb)
            var total = root.totalDelegates()
            console.log("GRIDPREBUILD d built=" + built + " total=" + total + " warmRows=" + grid.model.warmRows)
            if (built !== 0)
                root.fail("d: back built " + built + " delegates, want 0")
            if (total > grid.model.warmRows + 1)
                root.fail("d: total=" + total + " past warmRows+1=" + (grid.model.warmRows + 1))
            // Case e: hiding leaves no persisted and no parked.
            grid.visible = false
            stageTimer.interval = 400
            stageTimer.start()
            root.stage = 5
        }
    }

    // An unbound key crosses Keys.onPressed (which holds the driver) and the key
    // router without moving rows; inputAt changing proves the key arrived.
    function sendKey() {
        grid.forceActiveFocus()
        var before = root.stubPane.inputAt
        driver.keyClick(Qt.Key_F1, Qt.NoModifier, 10)
        return root.stubPane.inputAt !== before
    }
    function stepF() {
        if (root.fStep === 0) {
            // First trial: key at once into the fresh prebuild.
            root.keyAt0 = Date.now()
            root.tickBefore0 = root.hasPrebuild() ? grid.prebuildLastTickAt : 0
            if (!root.sendKey()) root.fail("f: the 0 ms key never reached the grid")
            root.stubPane.cursorIndex = 0
            grid.currentIndex = grid.cursorView
            console.log("GRIDPREBUILD f key0=" + root.keyAt0 + " tickBefore=" + root.tickBefore0)
            root.fStep = 1
            fTimer.interval = 25
            fTimer.start()
        } else if (root.fStep === 1) {
            var tickAfter0 = root.hasPrebuild() ? grid.prebuildLastTickAt : 0
            console.log("GRIDPREBUILD f key0=" + root.keyAt0 + " tickAfter=" + tickAfter0)
            if (!root.hasPrebuild())
                root.fail("f: no prebuild timer on this GridArea, want no tick within 16 ms after a key")
            else if (tickAfter0 !== root.tickBefore0 && tickAfter0 - root.keyAt0 < 16)
                root.fail("f: a tick ran within 16 ms after the 0 ms key")
            if (root.failures.length > 0) { root.report(); return }
            // Second trial: 8 ms into the restarted prebuild, key again.
            root.fStep = 2
            fTimer.interval = 8
            fTimer.start()
        } else if (root.fStep === 2) {
            root.keyAt8 = Date.now()
            root.tickBefore8 = root.hasPrebuild() ? grid.prebuildLastTickAt : 0
            if (!root.sendKey()) root.fail("f: the 8 ms key never reached the grid")
            root.stubPane.cursorIndex = 0
            grid.currentIndex = grid.cursorView
            console.log("GRIDPREBUILD f key8=" + root.keyAt8 + " tickBefore=" + root.tickBefore8)
            root.fStep = 3
            fTimer.interval = 25
            fTimer.start()
        } else if (root.fStep === 3) {
            var tickAfter = root.hasPrebuild() ? grid.prebuildLastTickAt : 0
            console.log("GRIDPREBUILD f key8=" + root.keyAt8 + " tickAfter=" + tickAfter)
            if (tickAfter !== root.tickBefore8 && tickAfter - root.keyAt8 < 16)
                root.fail("f: a tick ran within 16 ms after the 8 ms key")
            root.report()
        }
    }

    function report() {
        if (root.finished) return
        root.finished = true
        if (root.failures.length > 0) {
            for (var i = 0; i < Math.min(8, root.failures.length); i++)
                console.log("GRIDPREBUILD FAIL " + root.failures[i])
        } else {
            console.log("GRIDPREBUILD DONE warmRows=" + root.warmTarget)
        }
        Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }

    // Stage timer continuation for e and f setup.
    Connections {
        target: stageTimer
        function onTriggered() {
            if (root.stage === 5) {
                var persisted = root.persisted(), parked = root.parked()
                console.log("GRIDPREBUILD e persisted=" + persisted + " parked=" + parked)
                if (persisted !== 0)
                    root.fail("e: hiding left " + persisted + " persisted delegates, want 0")
                if (parked !== 0)
                    root.fail("e: hiding left " + parked + " parked, want 0")
                // Case f: show one row, let the prebuild start, then key at once.
                grid.visible = true
                root.land("/probe", 1, root.parentRows)
                root.stage = 6
                root.fStep = 0
                stageTimer.interval = 250
                stageTimer.start()
            } else if (root.stage === 6 && root.fStep === 0) {
                root.stepF()
            }
        }
    }

    Timer {
        interval: 30000
        running: true
        onTriggered: { root.fail("timeout at stage " + root.stage); root.report() }
    }

    Component.onCompleted: {
        Flea.ViewState.setTextSize({ mode: 14 })
        stageTimer.interval = 600
        stageTimer.start()
    }
}
