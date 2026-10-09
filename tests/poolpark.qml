//@ pragma ShellId flea-poolpark-test

import QtQuick
import Quickshell
import "flea" as Flea

// poolpark: a real list, grid or columns view over a stub pane enters a folder, goes back and enters another, in the
// swap's own order. The second Enter must build no delegate, and every row it reuses must show the new folder's row,
// cursor and selection with nothing left of the old one; a parked delegate must read nothing while the listing changes.
ShellRoot {
    id: root

    property string which: Quickshell.env("POOLPARK_VIEW") || "list"
    property bool finished: false
    property var failures: []
    // Plain JS state: a counted property would be read by the very bindings that bump it, a binding loop.
    property var counts: ({ rowFor: 0, readPast: 0 })
    property int landTotal: 0
    property var selectedSet: ({})
    // View positions the offscreen pointer hovers in a fresh build; a reused delegate may hover only these.
    property var pointerAt: null

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
            property int renamingIndex: -1
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
            property var selectionBand: null
            property int previewIndex: -1
            property bool storageKnown: true
            property string storageClass: ""
            property bool listInFlight: false
            property string listingState: "ready"
            property string pendingSelect: ""
            property bool pendingMenu: false
            property string focusView: root.which
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
            property var listArea: null
            function join(base, name) { return String(base) + "/" + String(name) }
            function rowFor(index) {
                root.counts.rowFor += 1
                // Only a delegate's read counts: the columns view's own cursor readers are not parked rows.
                if (index >= root.landTotal && /(List|GridArea|ColumnPane)\.qml/.test(new Error().stack.split("\n")[1]))
                    root.counts.readPast += 1
                var o = index - held
                return (o >= 0 && o < rows.length) ? rows[o] : null
            }
            function isSelected(index) { return selectionVersion >= 0 && root.selectedSet[index] === true }
            function selectedIndices() { return Object.keys(root.selectedSet).map(Number) }
            function selectionCount() { return Object.keys(root.selectedSet).length }
            function thumbFor(index) { return "" }
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
    function delegates(view) {
        var out = []
        var kids = view.contentItem.children
        for (var i = 0; i < kids.length; i++)
            if (kids[i].listingIndex !== undefined) out.push(kids[i])
        return out
    }

    // Nav.forget then PaneSwap.land, in their order: count to 0, rows, then the new count; reads past it are counted.
    function land(path, total, rows) {
        var p = root.stubPane
        root.landTotal = total
        root.counts.readPast = 0
        p.listInFlight = true
        p.total = 0
        p.held = 0
        p.rows = []
        p.kindNames = []
        p.cursorIndex = 0
        p.renamingIndex = -1
        p.shown = null
        p.listingState = "loading"
        root.selectedSet = {}
        p.selectionVersion += 1
        p.rows = rows
        p.total = total
        p.path = path
        p.listingState = total === 0 ? "empty" : "ready"
        p.listInFlight = false
        if (root.counts.readPast > 0)
            root.failures.push(path + ": parked delegates read " + root.counts.readPast + " rows past the new count " + total)
    }

    // Every drawn delegate shows prefix's row (the parent's, for null) for its listing index, with this cursor and selection and nothing else.
    function check(label, prefix) {
        var view = root.listingView(), drawn = 0
        var all = root.delegates(view)
        for (var i = 0; i < all.length; i++) {
            var d = all[i]
            if (d.live === false) {
                // A parked delegate keeps what it drew, so parking re-runs nothing, but holds no live state.
                if (d.selected || d.cursor || d.renaming || d.hovered)
                    root.failures.push(label + ": a parked delegate is still lit, " + (d.row ? d.row.n : "no row"))
                continue
            }
            if (d.listingIndex < 0) continue
            drawn += 1
            var want = prefix === null ? root.parentRows[d.listingIndex].n : prefix + root.pad(d.listingIndex)
            var bad = []
            if (!d.row || d.row.n !== want) bad.push("row " + (d.row ? d.row.n : "null"))
            if (d.cursor !== (d.listingIndex === root.stubPane.cursorIndex)) bad.push("cursor " + d.cursor)
            if (d.selected !== (root.selectedSet[d.listingIndex] === true)) bad.push("selected " + d.selected)
            if (d.renaming) bad.push("renaming")
            if (root.pointerAt === null) root.pointerAt = {}
            if (label === "enter a" && d.hovered) root.pointerAt[d.index] = true
            // Qt hovers a row under a still pointer at the next frame, so only a hover elsewhere is stale.
            if (d.hovered && root.pointerAt[d.index] !== true) bad.push("hovered")
            if (d.thumb !== "") bad.push("thumb " + d.thumb)
            if (bad.length > 0) root.failures.push(label + ": delegate for " + want + " shows " + bad.join(", "))
        }
        if (drawn === 0) root.failures.push(label + ": no delegate drawn")
    }

    function built(label, before) {
        var after = root.delegates(root.listingView()), n = 0
        for (var i = 0; i < after.length; i++)
            if (before.indexOf(after[i]) < 0) n += 1
        console.log("POOLPARK " + root.which + " " + label + " built=" + n + " alive=" + after.length)
        if (n > 0) root.failures.push(label + " built " + n + " delegates, the pool should have held them")
    }

    property int step: 0
    property var before: []

    function finish() {
        if (root.finished) return
        root.finished = true
        if (root.failures.length > 0) console.log("POOLPARK FAIL " + root.which + " " + root.failures.slice(0, 8).join("; "))
        else console.log("POOLPARK DONE " + root.which)
        Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }

    // One step a tick, so each landing's polish and cache buffer settle before the next.
    Timer {
        interval: 120
        running: true
        repeat: true
        onTriggered: {
            var p = root.stubPane
            if (root.step === 0) {
                root.land("/probe", 1, root.parentRows)
            } else if (root.step === 1) {
                root.land("/probe/a", 1000, root.rowsFor("a_", 343))
                p.cursorIndex = 5
                root.selectedSet = { 3: true, 7: true }
                p.selectionVersion += 1
            } else if (root.step === 2) {
                root.check("enter a", "a_")
                root.land("/probe", 1, root.parentRows)
                root.check("back", null)
            } else if (root.step === 3) {
                root.before = root.delegates(root.listingView())
                root.land("/probe/b", 1000, root.rowsFor("b_", 343))
                root.built("enter b", root.before)
                root.check("enter b in its turn", "b_")
            } else if (root.step === 4) {
                root.built("enter b settled", root.before)
                root.check("enter b settled", "b_")
                p.cursorIndex = 3
                root.selectedSet = { 2: true }
                p.selectionVersion += 1
                root.check("enter b moved", "b_")
            } else if (root.step === 5) {
                // A filter narrows the listing, parking the tail, then clears and takes it back.
                var list = []
                for (var f = 0; f < 100; f++) list.push(f * 3)
                p.shown = list
                root.check("filter", "b_")
            } else if (root.step === 6) {
                root.before = root.delegates(root.listingView())
                p.shown = null
                root.built("filter cleared", root.before)
                root.check("filter cleared", "b_")
            } else {
                root.finish()
                return
            }
            root.step += 1
        }
    }

    Timer {
        interval: 30000
        running: true
        onTriggered: { root.failures.push("timeout at step " + root.step); root.finish() }
    }
}
