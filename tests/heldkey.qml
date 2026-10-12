//@ pragma ShellId flea-heldkey-test

import QtQuick
import Quickshell
import "flea" as Flea
import "flea/js/Focus.js" as Focus

// heldkey: a held j steps once per repeat through the real key dispatch and never after the release.
ShellRoot {
    id: root

    property string which: Quickshell.env("HELDKEY_VIEW") || "list"
    property int loadMs: parseInt(Quickshell.env("HELDKEY_LOAD") || "0", 10)
    property bool finished: false
    property var failures: []
    property var selectedSet: ({})

    function rowsFor(prefix, count) {
        var out = []
        for (var i = 0; i < count; i++)
            out.push({ n: prefix + root.pad(i), d: false, i: "text-x-generic", p: 420, s: 0, m: 1758835200, t: false, k: 0, v: 0 })
        return out
    }
    function pad(i) {
        var n = String(i)
        while (n.length < 4) n = "0" + n
        return n
    }
    property var parentRows: [{ n: "big", d: true, i: "folder", p: 493, s: 0, m: 1758835200, t: false, k: 0, v: 0 }]

    Component {
        id: backendStub
        QtObject {
            signal peeked(string path, bool hidden, int total, var rows, bool readFailed, int mode, bool hiddenLast, int first)
            property int dirDev: 0
            property string sortBy: "name"
            property bool sortDesc: false
            function peek(path, size, hidden) {}
            function thumb(rows, cacheOnly) {}
            function thumbcancel(rows) {}
            function dirsize(rows) {}
            function dirsizecancel() {}
            function window(start, count) {}
            function askMeta(index, text, media, archive) { return 0 }
        }
    }

    Component {
        id: paneStub
        QtObject {
            property string path: "/probe"
            property var rows: []
            property var shown: null
            readonly property int shownTotal: shown === null ? total : shown.length
            property int total: 0
            property int held: 0
            property int cursorIndex: 0
            property int cursorSeq: 0
            property int selectionAnchor: 0
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
            property bool filterTyping: false
            property string filterQuery: ""
            property string recentMode: ""
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
            property int cursorStride: 5
            property int visibleRows: 43
            property int cacheRows: 2
            property int firstSettleMs: 70
            property int settleMs: 120
            property int coalesceMs: 16
            property int refetchMargin: 25
            property int buffer: 150
            property int windowSize: 35
            property var backend: null
            property var sidebar: null
            property var shareBrowser: null
            property var preview: null
            property var menuActions: null
            property var collide: null
            property var keymapSheet: null
            property var settingsPanel: null
            property var statusBar: null
            property bool menuVisible: false
            property bool escapeUp: false
            property bool railAvailable: false
            property bool wrapAtEnds: false
            property int inputAt: 0
            property int rowsAt: 0
            property string keySequence: ""
            property string keySequenceIdentity: ""
            property int trashArmedAt: 0
            property var selection: ({ follows: function () { return false } })
            property var listArea: null
            function join(base, name) { return String(base) + "/" + String(name) }
            function rowFor(index) {
                var o = index - held
                return (o >= 0 && o < rows.length) ? rows[o] : null
            }
            function isSelected(index) { return selectionVersion >= 0 && root.selectedSet[index] === true }
            function selectedIndices() { return Object.keys(root.selectedSet).map(Number) }
            function selectionCount() { return Object.keys(root.selectedSet).length }
            function thumbFor(index) { var v = thumbState.file[index]; return typeof v === "string" ? v : "" }
            function setCursor(index, mode) {}
            function slowClickWasSole(index) { return false }
            function pressSlowClick() {}
            function cancelSlowClick() {}
            function armSlowClick() {}
            function commitRename(newName) {}
            function open(path) {}
            function openFile(path) {}
            function focusRequested() {}
            function renameEditor() { return null }
            function message(text, error) {}
            function showRow(view, context) { root.showRowTo(view, context) }
            function act(action) { Focus.act(action, root.stubPane) }
        }
    }
    Component {
        id: menuStub
        QtObject {
            function close() {}
            function openBackground(point) {}
        }
    }

    property var stubPane: paneStub.createObject(root, { backend: backendStub.createObject(root) })

    FloatingWindow {
        implicitWidth: 2300
        implicitHeight: 1300
        color: "black"

        Loader {
            id: viewLoader
            width: 2300
            height: 1290
            sourceComponent: root.which === "grid" ? gridView : root.which === "columns" ? columnsView : listView
        }
    }

    Component { id: listView; Flea.List { pane: root.stubPane; menu: menuStub.createObject(root) } }
    Component { id: gridView; Flea.GridArea { pane: root.stubPane; menu: menuStub.createObject(root) } }
    Component { id: columnsView; Flea.ColumnsArea { pane: root.stubPane; menu: menuStub.createObject(root) } }

    // The ListView or GridView that draws the pane's own listing: the view itself, or the columns view's active column.
    function listingView() {
        if (root.which !== "columns") return viewLoader.item
        var found = null
        function walk(o) {
            if (found || !o) return
            if (o.viewport !== undefined && o.pane === root.stubPane) { found = o.viewport; return }
            for (var i = 0; o.children && i < o.children.length; i++) walk(o.children[i])
        }
        walk(viewLoader.item)
        return found
    }
    // The pane's own showRow, through the real view: the cursor scrolls as it steps.
    function showRowTo(view, context) {
        if (root.which === "columns") {
            var col = viewLoader.item.activeColumn()
            if (col) col.showCursor(view, context)
        } else {
            root.listingView().positionViewAtIndex(view, root.which === "grid" ? GridView.Contain : ListView.Contain)
        }
        viewLoader.item.restartCoalesce()
    }
    function land(path, total, rows) {
        var p = root.stubPane
        p.listInFlight = true
        p.total = 0
        p.held = 0
        p.rows = []
        p.cursorIndex = 0
        p.renamingIndex = -1
        p.shown = null
        p.listingState = "loading"
        root.selectedSet = {}
        p.selectionVersion += 1
        p.rows = rows
        p.total = total
        p.path = path
        p.viewMode = root.which === "grid" ? "grid" : root.which === "columns" ? "columns" : "list"
        p.listingState = total === 0 ? "empty" : "ready"
        p.listInFlight = false
    }

    // One j press or repeat through the real dispatch, shaped as Qt delivers a held key.
    function fakeKey(repeat) {
        return { key: Qt.Key_J, text: "j", modifiers: Qt.NoModifier, isAutoRepeat: repeat, accepted: false }
    }
    function oneStep(repeat) {
        var p = root.stubPane, before = p.cursorIndex
        Focus.handleKey(root.fakeKey(repeat), p, null)
        return p.cursorIndex - before
    }
    // A busy frame of the nominal length, the load the queue drains against.
    function busy(ms) {
        var s = Date.now()
        while (Date.now() - s < ms) {}
    }

    property int sent: 0
    property int steps: 0
    property int worstGap: 0
    property int releaseCursor: -1
    property int stride: 1
    property int afterRows: 0

    // Press, then wall-clock repeats every 25 ms after 250 ms for 2 s, then the release marker in the same order.
    function run() {
        var p = root.stubPane
        root.stride = root.which === "grid" ? p.cursorStride : 1
        p.cursorIndex = 0
        root.showRowTo(0, 0)
        if (root.oneStep(false) !== root.stride) root.failures.push("the press did not take one step")
        var t0 = Date.now(), n = 0
        for (;;) {
            root.busy(root.loadMs)
            var el = Date.now() - t0
            var horizon = el < 2000 ? el : 2000
            while (250 + 25 * n <= horizon) {
                var due = 250 + 25 * n
                if (root.oneStep(true) !== root.stride) root.failures.push("repeat " + n + " did not take its step")
                else root.steps += 1
                root.sent += 1
                var gap = Date.now() - t0 - due
                if (gap > root.worstGap) root.worstGap = gap
                n += 1
            }
            if (el >= 2000) break
        }
        root.releaseCursor = p.cursorIndex
        if (root.releaseCursor !== root.stride * (root.sent + 1)) root.failures.push("the cursor is not on its sent row")
    }

    function finish() {
        if (root.finished) return
        root.finished = true
        console.log("HELDKEY " + root.which + " load=" + root.loadMs + " sent=" + root.sent + " steps=" + root.steps + " after=" + root.afterRows + " worstgap=" + root.worstGap)
        if (root.failures.length > 0) console.log("HELDKEY FAIL " + root.which + " load=" + root.loadMs + " " + root.failures.slice(0, 8).join("; "))
        else console.log("HELDKEY DONE " + root.which + " load=" + root.loadMs)
        Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }

    property int phase: 0
    property int settles: 0
    // One landing, one sweep, then settled turns: deferred work lands after the release and fails.
    Timer {
        interval: 200
        running: true
        repeat: true
        onTriggered: {
            if (root.phase === 0) {
                root.phase = 1
                root.land("/probe/a", 2000, root.rowsFor("a_", 2000))
            } else if (root.phase === 1) {
                root.phase = 2
                root.run()
            } else {
                if (root.stubPane.cursorIndex !== root.releaseCursor) {
                    root.afterRows = (root.stubPane.cursorIndex - root.releaseCursor) / root.stride
                    root.failures.push("the cursor moved after the release")
                }
                root.settles += 1
                if (root.settles >= 3) root.finish()
            }
        }
    }

    Timer {
        interval: 30000
        running: true
        onTriggered: { root.failures.push("timeout in phase " + root.phase); root.finish() }
    }
}
