//@ pragma ShellId flea-gridbare-test

import QtQuick
import QtTest
import Quickshell
import "flea" as Flea
import "flea/js/Selection.js" as Selection

// A real Grid in a real window, driven by pointer events: a press, click, double click, right click or drag lifts a tile
// only from its icon box or painted caption, and the rest of the cell starts a band and answers as the listing's own ground.
ShellRoot {
    id: root

    property var failures: []
    property int gestures: 0
    readonly property int rowCount: 40
    // One short name and one long enough to wrap in GridNames, so the painted caption box is measured at two widths.
    readonly property string shortName: "a.md"
    readonly property string longName: "screenshot-2026-08-30-final-review-for-gm-after-the-bench-v3.png"
    readonly property int shortIndex: 5
    readonly property int longIndex: 6
    // A tile with a column on each side, so a press at its right edge stays inside the viewport.
    readonly property int plainIndex: 7

    function buildRows() {
        var rows = []
        for (var i = 0; i < root.rowCount; i++) {
            var n = i === root.shortIndex ? root.shortName : i === root.longIndex ? root.longName : "item" + (i < 10 ? "0" + i : i) + ".txt"
            rows.push({ n: n, d: false, i: "text-x-generic", p: 420, s: 13, m: 1758835200, t: false, k: 0, v: 0 })
        }
        return rows
    }

    Component {
        id: backendStub
        QtObject {
            property int heldListing: 1
            property int dirDev: 1
            function peek(path, size, hidden) {}
            function thumb(rows, cacheOnly) {}
            function thumbcancel(rows) {}
            function dirsize(rows) {}
            function dirsizecancel() {}
            function window(start, count) {}
            function send(message) {}
        }
    }

    Component {
        id: paneStub
        QtObject {
            property string path: "/probe"
            property var rows: []
            property var shown: null
            property int shownTotal: 40
            property int total: 40
            property int held: 0
            property int cursorIndex: 0
            property int renamingIndex: -1
            property string renameError: ""
            property bool renamePending: false
            property var renameRequest: null
            property bool paneFocused: true
            property bool dualMode: false
            property bool singleClick: false
            property var clipboard: null
            property var thumbState: ({ file: {}, order: [] })
            property var dirSizeState: ({ file: {}, order: [] })
            property string searchMode: ""
            property string searchQuery: ""
            property string filterQuery: ""
            property bool filterTyping: false
            property var swap: ({ searchWarm: false, answeredQuery: "" })
            property var selectionBand: null
            property var sidebar: null
            property int previewIndex: -1
            property bool storageKnown: true
            property string storageClass: ""
            property bool listInFlight: false
            property string listingState: "ready"
            property var statusBar: null
            property int firstSettleMs: 70
            property int settleMs: 120
            property int coalesceMs: 16
            property int refetchMargin: 25
            property int buffer: 150
            property int windowSize: 35
            property var backend: null
            property var pathsPending: null
            property var clipPending: null
            property bool awaitingPaths: false
            property bool dragHolding: false
            property var selection: Selection.create()
            property int selectionVersion: 0
            property int selectionAnchor: -1
            property string focusView: "grid"
            property var listArea: null
            signal focusRequested()
            // What the product's handlers did, read back by the probe.
            property var selectedOnly: []
            property var toggled: []
            property int opens: 0
            property int tileMenus: 0
            property int slowClicks: 0
            function join(base, name) { return String(base) + "/" + String(name) }
            function rowFor(index) { var o = index - held; return (o >= 0 && o < rows.length) ? rows[o] : null }
            function isSelected(index) { selectionVersion; return selection.has(index) }
            function selectedIndices() {
                var picked = []
                for (var i = 0; i < total; i++) if (selection.has(i)) picked.push(i)
                return picked
            }
            function clearSelection() { selection.clear(); selectionVersion++ }
            function selectOnly(index, keep) { selectedOnly.push(index); selection.only(index, keep === true); selectionVersion++ }
            function toggleSelectAt(index) { toggled.push(index); selection.toggle(index); selectionVersion++ }
            function extendSelectionTo(index) {}
            function setCursor(index, context) {}
            function commitOpenRename() {}
            function act(verb) { if (verb === "open") opens += 1 }
            function slowClickWasSole(index) { return false }
            function armSlowClick(index, modifiers, dragging, wasSole) { slowClicks += 1 }
            function pressSlowClick() {}
            function cancelSlowClick() {}
            function message(text, alert) {}
            function commitRename(newName) {}
        }
    }

    Component {
        id: menuStub
        QtObject {
            property int backgrounds: 0
            property int tiles: 0
            function close() {}
            function openBackground(point) { backgrounds += 1 }
            function openAt(point) { tiles += 1 }
        }
    }

    property var stubBackend: backendStub.createObject(root)
    property var stubMenu: menuStub.createObject(root)
    property var stubPane: paneStub.createObject(root, { backend: root.stubBackend, rows: root.buildRows() })

    FloatingWindow {
        implicitWidth: 900
        implicitHeight: 500
        color: Flea.Theme.color.background

        Flea.GridArea {
            id: grid
            width: 700
            height: 300
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            pane: root.stubPane
            menu: root.stubMenu
        }

        TestEvent { id: driver }
    }

    // List and Columns keep SelectionBand's own row test: a press on a row is refused, one on the ground below the rows owns the band.
    FloatingWindow {
        implicitWidth: 300
        implicitHeight: 200
        color: Flea.Theme.color.background

        ListView {
            id: plainList
            width: 300
            height: 200
            model: 3
            delegate: Item { width: 300; height: 20 }
            Flea.SelectionBand { id: plainBand; parent: plainList; pane: root.stubPane; flickable: plainList }
        }
    }

    Timer { interval: 900; running: true; repeat: false; onTriggered: root.run() }

    function fail(text) { root.failures.push(text) }
    function expect(label, got, want) {
        if (got !== want) root.fail(label + ": got " + got + ", want " + want)
    }

    function tile(index) { return grid.itemAtIndex(index) }
    function at(index, x, y) { return root.tile(index).mapToItem(grid, x, y) }

    // The lift's DragHandler, found through the RowDrag a tile holds.
    function liftOf(index) {
        var kids = root.tile(index).children
        for (var k = 0; k < kids.length; k++) {
            if (kids[k].session === undefined) continue
            for (var d = 0; d < kids[k].data.length; d++)
                if (kids[k].data[d].centroid !== undefined) return kids[k].data[d]
        }
        return null
    }

    function press(index, x, y, button) { var p = root.at(index, x, y); driver.mousePress(grid, p.x, p.y, button, Qt.NoModifier, 1) }
    function release(index, x, y, button) { var p = root.at(index, x, y); driver.mouseRelease(grid, p.x, p.y, button, Qt.NoModifier, 1) }
    function drag(index, x, y, dx, dy) {
        var p = root.at(index, x, y)
        driver.mouseMove(grid, p.x + dx / 2, p.y + dy / 2, 1, Qt.LeftButton, Qt.NoModifier)
        driver.mouseMove(grid, p.x + dx, p.y + dy, 1, Qt.LeftButton, Qt.NoModifier)
    }
    function doubleClick(index, x, y) { var p = root.at(index, x, y); driver.mouseDoubleClickSequence(grid, p.x, p.y, Qt.LeftButton, Qt.NoModifier, 1) }
    function click(index, x, y, button) { root.press(index, x, y, button); root.release(index, x, y, button) }

    function reset() {
        var pane = root.stubPane
        pane.selection = Selection.create()
        pane.selectionVersion++
        pane.selectedOnly = []
        pane.toggled = []
        pane.opens = 0
        pane.pathsPending = null
        root.stubMenu.backgrounds = 0
        root.stubMenu.tiles = 0
    }

    // One point of one tile: onTile says whether the tile owns it, and every gesture must agree.
    function probe(label, index, x, y, onTile, bandOpen) {
        var pane = root.stubPane, menu = root.stubMenu, lift = root.liftOf(index)
        var seen = root.at(index, x, y)
        root.expect(label + " lies in the viewport", seen.y >= 0 && seen.y + 30 < grid.height && seen.x >= 0 && seen.x + 40 < grid.width, true)
        root.gestures += 4

        root.reset()
        root.click(index, x, y, Qt.LeftButton)
        root.expect(label + " click selects the tile", pane.selectedOnly.length > 0, onTile)
        root.expect(label + " click leaves no band owner", pane.selectionBand, null)

        // The platform's synthetic double click reaches the tile as two taps, so the open itself is the native case's.
        root.reset()
        root.doubleClick(index, x, y)
        root.expect(label + " double click selects the tile", pane.selectedOnly.length > 0, onTile)
        root.expect(label + " double click on bare ground opens nothing", onTile ? 0 : pane.opens, 0)

        root.reset()
        root.click(index, x, y, Qt.RightButton)
        root.expect(label + " right click raises the tile menu", menu.tiles, onTile ? 1 : 0)
        root.expect(label + " right click raises the background menu", menu.backgrounds, onTile ? 0 : 1)

        root.reset()
        root.press(index, x, y, Qt.LeftButton)
        root.expect(label + " press makes the band the owner", pane.selectionBand !== null, !onTile && bandOpen)
        root.drag(index, x, y, 40, 30)
        root.expect(label + " drag lifts the tile", lift.active, onTile)
        root.expect(label + " drag sweeps a band", pane.selectionBand !== null && pane.selectionBand.bandActive, !onTile && bandOpen)
        driver.mouseRelease(grid, root.at(index, x, y).x + 40, root.at(index, x, y).y + 30, Qt.LeftButton, Qt.NoModifier, 1)
        root.expect(label + " release frees the band", pane.selectionBand, null)
    }

    function run() {
        root.stubPane.listArea = grid
        var short = root.tile(root.shortIndex), long = root.tile(root.longIndex), plain = root.tile(root.plainIndex)
        if (!short || !long || !plain || grid.count !== root.rowCount) {
            root.fail("the grid built " + grid.count + " rows and no tiles 5, 6 and 7")
            root.report()
            return
        }
        var points = []
        // A margin of a plain tile: its left edge, its right edge, its top edge and the gap between icon and caption.
        var icon = plain.thumbItem, label = plain.captionItem
        var iconBox = icon.mapToItem(plain, 0, 0)
        var labelBox = label.mapToItem(plain, 0, 0)
        points.push(["plain icon centre", root.plainIndex, iconBox.x + icon.width / 2, iconBox.y + icon.height / 2, true])
        points.push(["plain icon top left corner", root.plainIndex, iconBox.x + 1, iconBox.y + 1, true])
        points.push(["plain left edge", root.plainIndex, 2, iconBox.y + icon.height / 2, false])
        points.push(["plain right edge", root.plainIndex, plain.width - 3, iconBox.y + icon.height / 2, false])
        points.push(["plain top edge", root.plainIndex, plain.width / 2, 2, false])
        points.push(["plain beside the icon", root.plainIndex, iconBox.x - 3, iconBox.y + icon.height / 2, false])
        points.push(["plain between icon and caption", root.plainIndex, plain.width / 2, (iconBox.y + icon.height + labelBox.y) / 2, false])
        var names = [[short, root.shortIndex, "short caption"], [long, root.longIndex, "wrapped caption"]]
        for (var n = 0; n < names.length; n++) {
            var t = names[n][0], index = names[n][1], name = names[n][2]
            var text = t.captionItem, box = text.mapToItem(t, 0, 0)
            var painted = Math.min(text.width, text.contentWidth)
            var left = box.x + (text.width - painted) / 2
            var top = box.y + Math.min(text.height, text.contentHeight)
            points.push([name + " paints " + Math.round(painted) + " of " + Math.round(text.width) + " px", index, left + painted / 2, box.y + 3, true])
            points.push([name + " first painted pixel", index, left + 1, box.y + 3, true])
            points.push([name + " left of the painted text", index, left - 3, box.y + 3, false])
            points.push([name + " right of the painted text", index, left + painted + 2, box.y + 3, false])
            if (top < box.y + text.height)
                points.push([name + " below the painted lines", index, left + painted / 2, top + 2, false])
        }
        root.expect("the caption widths differ", Math.round(short.captionItem.contentWidth) < Math.round(long.captionItem.contentWidth), true)
        for (var p = 0; p < points.length; p++)
            root.probe(points[p][0], points[p][1], points[p][2], points[p][3], points[p][4], true)
        // While a listing loads the band stays out, and the tile's own handlers still answer only on the tile.
        root.stubPane.listingState = "loading"
        for (p = 0; p < points.length; p++)
            root.probe("loading " + points[p][0], points[p][1], points[p][2], points[p][3], points[p][4], false)
        root.stubPane.listingState = "ready"

        // A band from the margin between two middle tiles sweeps four tiles, as the native case does.
        var c = grid.columns
        root.expect("the grid has middle columns", c >= 4, true)
        var a = root.tile(c + 1), b = root.tile(2 * c + 2)
        var start = a.mapToItem(grid, a.width - 3, a.height / 2)
        var stop = b.mapToItem(grid, b.width / 2, b.height / 2)
        var four = [c + 1, c + 2, 2 * c + 1, 2 * c + 2].join(",")
        root.reset()
        driver.mousePress(grid, start.x, start.y, Qt.LeftButton, Qt.NoModifier, 1)
        driver.mouseMove(grid, (start.x + stop.x) / 2, (start.y + stop.y) / 2, 1, Qt.LeftButton, Qt.NoModifier)
        driver.mouseMove(grid, stop.x, stop.y, 1, Qt.LeftButton, Qt.NoModifier)
        root.expect("a band from a margin selects four tiles", root.stubPane.selectedIndices().join(","), four)
        driver.mouseRelease(grid, stop.x, stop.y, Qt.LeftButton, Qt.NoModifier, 1)
        root.expect("the band keeps four tiles on release", root.stubPane.selectedIndices().join(","), four)
        root.reset()
        root.stubPane.selectionBand = null
        root.expect("a list row is not the band's", plainBand.rowAt(10, 10) >= 0, true)
        root.expect("the ground below the list rows is the band's", plainBand.rowAt(10, 150), -1)
        root.report()
    }

    function report() {
        for (var f = 0; f < root.failures.length; f++)
            console.log("GRIDBARE FAIL " + root.failures[f])
        if (root.failures.length === 0)
            console.log("GRIDBARE PASS gestures=" + root.gestures + " icon=hit caption=short,wrapped margin=band")
        Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }
}
