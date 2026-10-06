//@ pragma ShellId flea-columnsfilter-test

import QtQuick
import Quickshell
import "flea" as Flea
import "flea/js/Filter.js" as Filter
import "flea/js/Focus.js" as Focus
import "flea/js/Nav.js" as Nav

// U3: the "/" filter in Columns. A real ColumnsArea, a real GridArea and the List strip
// itself over one stub pane: "/" narrows the active column through the pane's own shown
// list, the strip stands with the List recipe's sentence, the parent column keeps its
// peeked rows, Esc restores, and a navigation forgets the filter the way List does.
ShellRoot {
    id: root

    property var failures: []
    property int stage: 0
    property string parentBefore: ""

    function buildRows() {
        return [
            { n: "Apps", d: true, i: "folder", p: 493, s: 0, m: 1, t: false, k: 0 },
            { n: "Maps", d: true, i: "folder", p: 493, s: 0, m: 2, t: false, k: 0 },
            { n: "apricot.txt", d: false, i: "text-x-generic", p: 420, s: 3, m: 3, t: false, k: 0 },
            { n: "caption.png", d: false, i: "text-x-generic", p: 420, s: 4, m: 4, t: false, k: 0 },
            { n: "gap.md", d: false, i: "text-x-generic", p: 420, s: 5, m: 5, t: false, k: 0 },
            { n: "napkin.txt", d: false, i: "text-x-generic", p: 420, s: 6, m: 6, t: false, k: 0 },
            { n: "paper.pdf", d: false, i: "text-x-generic", p: 420, s: 7, m: 7, t: false, k: 0 },
            { n: "snapshot.jpg", d: false, i: "text-x-generic", p: 420, s: 8, m: 8, t: false, k: 0 },
            { n: "xylophone.txt", d: false, i: "text-x-generic", p: 420, s: 9, m: 9, t: false, k: 0 },
            { n: "zebra.md", d: false, i: "text-x-generic", p: 420, s: 10, m: 10, t: false, k: 0 },
            { n: "note.txt", d: false, i: "text-x-generic", p: 420, s: 11, m: 11, t: false, k: 0 },
            { n: "readme.txt", d: false, i: "text-x-generic", p: 420, s: 12, m: 12, t: false, k: 0 }
        ]
    }

    function buildParentRows() {
        return [
            { n: "studio", d: true, i: "folder", p: 493, s: 0, m: 1, t: false, k: 0 },
            { n: "field", d: true, i: "folder", p: 493, s: 0, m: 2, t: false, k: 0 },
            { n: "notes.txt", d: false, i: "text-x-generic", p: 420, s: 1, m: 3, t: false, k: 0 }
        ]
    }

    Component {
        id: backendStub
        QtObject {
            signal peeked(string path, bool hidden, int total, var rows, bool readFailed, int mode, bool hiddenLast, int first)
            signal metaResult(var message)
            property int dirDev: 0
            function peek(path, size, hidden) {}
            function askMeta(index, wantLines, wantMedia, wantArchive) { return 0 }
            function thumb(rows, cacheOnly) {}
            function thumbcancel(rows) {}
            function dirsize(rows) {}
            function dirsizecancel() {}
            function window(start, count) {}
        }
    }

    Component {
        id: paneStub
        QtObject {
            property string path: "/probe/studio"
            property string listingPath: "/probe/studio"
            property string viewMode: "columns"
            property string focusView: "list"
            property var rows: []
            property var shown: null
            property int shownTotal: 12
            property int total: 12
            property int held: 0
            property int cursorIndex: 4
            property int cursorSeq: 0
            property int renamingIndex: -1
            property var renameRequest: null
            property string renameError: ""
            property bool renamePending: false
            property bool paneFocused: true
            property bool dualMode: false
            property string filterQuery: ""
            property bool filterTyping: false
            property string searchMode: ""
            property string searchQuery: ""
            property string recentMode: ""
            property var clipboard: ({ paths: [], moving: false })
            property var picked: ({})
            property var selection: null
            property int selectionVersion: 0
            property var thumbState: ({ file: {}, order: [] })
            property var dirSizeState: ({ file: {}, order: [] })
            property var kindNames: ["text-x-generic"]
            property bool showHidden: false
            property bool storageKnown: true
            property string storageClass: "local"
            property bool listInFlight: false
            property string listingState: "ready"
            property var trash: ({ opened: false })
            property var selectionBand: null
            property var sidebar: null
            property int previewIndex: -1
            property int trashArmedAt: 0
            property var pendingSort: null
            property var pendingBackground: []
            property string stateMessage: ""
            property int lockedMode: 0
            property string dropPath: ""
            property bool dragHolding: false
            property int visibleRows: 8
            property int firstSettleMs: 70
            property int settleMs: 120
            property int coalesceMs: 16
            property int refetchMargin: 25
            property int buffer: 150
            property int windowSize: 35
            property var backend: null
            property var statusBar: null
            property var listArea: ({ primeSettle: function () {} })
            function join(base, name) { return String(base) + "/" + String(name) }
            function rowFor(index) { var o = index - held; return (o >= 0 && o < rows.length) ? rows[o] : null }
            function isSelected(index) { return picked[index] === true }
            function selectedIndices() { var out = []; for (var k in picked) out.push(Number(k)); return out }
            function selectionCount() { return selectedIndices().length }
            function clearSelection() { picked = {}; selectionVersion += 1 }
            function thumbFor(index) { return "" }
            function showRow(view, context) {}
            function cancelSlowClick() {}
            function open(path) {}
            function openFile(path) {}
            function focusRequested() {}
            function refresh() {
                shown = Filter.shown(rows, held, filterQuery)
                shownTotal = shown === null ? total : shown.length
            }
            function typeQuery(text) {
                Filter.start(root.stubPane)
                for (var i = 0; i < text.length; i++) {
                    Filter.typed(root.stubPane, text.charAt(i))
                    root.stubPane.refresh()
                }
                Filter.commit(root.stubPane)
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

    Component {
        id: statusStub
        QtObject { property var activities: [] }
    }

    property var stubBackend: backendStub.createObject(root)
    property var stubStatus: statusStub.createObject(root)
    property var stubPane: paneStub.createObject(root, { backend: root.stubBackend, rows: root.buildRows(), statusBar: root.stubStatus })

    Component.onCompleted: {
        // Filter.prune's only pane call, closing over the stub the way filterfixture.js does.
        root.stubPane.selection = { toggle: function (i) { var p = root.stubPane.picked; if (p[i]) delete p[i]; else p[i] = true } }
    }

    FloatingWindow {
        implicitWidth: 1500
        implicitHeight: 700
        color: Flea.Theme.color.background

        Flea.FilterStrip {
            id: strip
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            pane: root.stubPane
        }

        Flea.ColumnsArea {
            id: area
            anchors.top: strip.bottom
            anchors.left: parent.left
            anchors.right: parent.horizontalCenter
            anchors.rightMargin: -200
            anchors.bottom: parent.bottom
            pane: root.stubPane
            menu: menuStub.createObject(root)
        }

        Flea.GridArea {
            id: grid
            anchors.top: strip.bottom
            anchors.left: area.right
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            pane: root.stubPane
            menu: menuStub.createObject(root)
        }
    }

    Timer { interval: 800; running: true; repeat: false; onTriggered: root.measureRest() }
    Timer { id: filterTimer; interval: 600; repeat: false; onTriggered: root.measureFiltered() }
    Timer { id: restoredTimer; interval: 600; repeat: false; onTriggered: root.measureRestored() }
    Timer { id: navTimer; interval: 600; repeat: false; onTriggered: root.measureNav() }

    function fail(text) { root.failures.push(text) }
    function activeCount() { return area.activeColumn().viewport.count }
    function parentNames() { return area.peekNames("/probe") }

    function answerParentPeek() {
        var rows = root.buildParentRows()
        root.stubBackend.peeked("/probe", false, rows.length, rows, false, 0, false, root.stubPane.windowSize)
    }

    // At rest both views list the whole window and the List strip itself stands down.
    function measureRest() {
        var slash = Focus.lookup({ key: Qt.Key_Slash, text: "/", modifiers: Qt.NoModifier }, root.stubPane)
        if (slash !== "filter")
            root.fail("rest routes / to " + slash + ", want filter")
        // "a" alone in Columns opens the network dialog: keys.toml's [[text]] char="a"
        // row is a real listing binding, so the dropped "/" left "a" exactly where it belongs.
        var aKey = Focus.lookup({ key: Qt.Key_A, text: "a", modifiers: Qt.NoModifier }, root.stubPane)
        if (aKey !== "addNetwork")
            root.fail("rest routes a to " + aKey + ", want addNetwork")
        if (root.activeCount() !== 12)
            root.fail("rest lists " + root.activeCount() + " active rows, want 12")
        if (grid.count !== 12)
            root.fail("rest lists " + grid.count + " grid tiles, want 12")
        if (strip.up !== false)
            root.fail("rest holds the strip up with no query")
        if (area.showParent !== true)
            root.fail("rest draws no parent column to hold still")
        if (root.failures.length > 0) { root.report(); return }
        root.answerParentPeek()
        root.parentBefore = root.parentNames()
        if (root.parentBefore === "")
            root.fail("rest answers no parent peek to hold still")
        root.stubPane.picked = { 2: true, 9: true }
        root.stubPane.typeQuery("ap")
        root.stage = 1
        filterTimer.start()
    }

    // Filtered: the active column and the grid narrow to the matches, the strip carries
    // the List recipe's sentence, the parent column keeps its rows, and the hidden
    // selection member drops out.
    function measureFiltered() {
        if (root.stubPane.filterQuery !== "ap")
            root.fail("filter holds query " + root.stubPane.filterQuery + ", want ap")
        if (root.stubPane.shownTotal !== 8)
            root.fail("filter keeps " + root.stubPane.shownTotal + " rows, want 8")
        if (root.activeCount() !== 8)
            root.fail("filter lists " + root.activeCount() + " active rows, want 8")
        if (grid.count !== 8)
            root.fail("filter lists " + grid.count + " grid tiles, want 8")
        var first = area.itemAtIndex(0)
        if (first === null || first.row === null || first.row.n !== "Apps")
            root.fail("filter draws no Apps delegate first")
        if (strip.up !== true || strip.height <= 0)
            root.fail("filter leaves the List strip down")
        if (Filter.summary(root.stubPane.shown, 12, 12) !== "8 of 12 shown")
            root.fail("filter sentences " + Filter.summary(root.stubPane.shown, 12, 12))
        if (root.parentNames() !== root.parentBefore)
            root.fail("filter moved the parent column")
        if (root.stubPane.cursorIndex !== 4)
            root.fail("filter moved a cursor it still shows")
        if (JSON.stringify(root.stubPane.selectedIndices()) !== "[2]")
            root.fail("filter keeps selection " + JSON.stringify(root.stubPane.selectedIndices()) + ", want [2]")
        if (root.failures.length > 0) { root.report(); return }
        Filter.close(root.stubPane)
        root.stubPane.refresh()
        root.stage = 2
        restoredTimer.start()
    }

    // Esc restores both views and stands the strip down, as in List.
    function measureRestored() {
        if (root.stubPane.filterQuery !== "")
            root.fail("esc keeps query " + root.stubPane.filterQuery)
        if (root.activeCount() !== 12)
            root.fail("esc lists " + root.activeCount() + " active rows, want 12")
        if (grid.count !== 12)
            root.fail("esc lists " + grid.count + " grid tiles, want 12")
        if (strip.up !== false)
            root.fail("esc leaves the strip up")
        if (root.failures.length > 0) { root.report(); return }
        root.stubPane.typeQuery("ap")
        if (root.activeCount() !== 8) {
            root.fail("re-filter lists " + root.activeCount() + " active rows, want 8")
            root.report()
            return
        }
        // A navigation forgets the filter the way List does; the rows below stand in
        // for the re-list landing right behind it.
        Nav.forget(root.stubPane)
        if (root.stubPane.filterQuery !== "")
            root.fail("a navigation keeps query " + root.stubPane.filterQuery)
        root.stubPane.rows = root.buildRows()
        root.stubPane.total = 12
        root.stubPane.listingState = "ready"
        root.stubPane.refresh()
        root.stage = 3
        navTimer.start()
    }

    // After the navigation both views list the whole window again.
    function measureNav() {
        if (root.activeCount() !== 12)
            root.fail("navigated lists " + root.activeCount() + " active rows, want 12")
        if (grid.count !== 12)
            root.fail("navigated lists " + grid.count + " grid tiles, want 12")
        if (strip.up !== false)
            root.fail("navigated leaves the strip up")
        if (root.parentNames() !== root.parentBefore)
            root.fail("navigated moved the parent column")
        if (root.failures.length > 0) { root.report(); return }
        console.log("COLUMNSFILTER PASS active=8-of-12 grid=8-of-12 strip=list esc=restored nav=forgotten parent=kept")
        Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }

    function report() {
        for (var f = 0; f < root.failures.length; f++)
            console.log("COLUMNSFILTER FAIL " + root.failures[f])
        Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }
}
