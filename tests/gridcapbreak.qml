//@ pragma ShellId flea-gridcapbreak-test

import QtQuick
import Quickshell
import "flea" as Flea
import "flea/js/GridGeometry.js" as GridGeometry
import "flea/js/Match.js" as Match

// The Grid caption state names the break Flea drew, so a query can straddle it: the long fixture name at text size 14 under a 1320 px window, one tile per sidebar stop.
ShellRoot {
    id: root

    readonly property string fixtureName: "grid-caption-that-wraps.txt"
    readonly property var fileRow: ({ n: root.fixtureName, i: "text-x-generic", p: 0, d: false, s: 1, m: 0, t: false, v: 0 })
    // The tile widths a 1320 px window gives the grid beside each sidebar stop (ui/js/Places.js WIDTH_STOPS), the cell maths GridArea runs.
    readonly property var paneWidths: [1320 - 160, 1320 - 192, 1320 - 224, 1320 - 256]

    function cellW(pane) {
        var th = Flea.Theme, columns = GridGeometry.columnsFor(pane, th.grid.minCellWidth, Flea.ViewState.thumbnailPixels, th.spacing.rowPaddingX, th.spacing.gap, th.spacing.rowPaddingX)
        return GridGeometry.cellWidthFor(pane, columns, th.spacing.gap, th.spacing.rowPaddingX)
    }

    property var tiles: []
    QtObject {
        id: stubPane
        property var backend: null
        function visibleItemFor(i) { return root.tiles[i] || null }
    }
    QtObject { id: windowStub; function centreOf(item) { return "" } function rectOf(item) { return "" } }
    Flea.Ipc { id: ipc; pane: stubPane; fleaWindow: windowStub }

    Column {
        Repeater {
            id: reps
            model: root.paneWidths
            Flea.GridTile { required property int modelData; width: root.cellW(modelData); height: 200; row: root.fileRow }
        }
    }
    FontMetrics { id: face; font.family: Flea.Theme.font.family; font.pixelSize: Flea.Theme.font.bodySmall }

    property int phase: 0
    property var failures: []
    property var queries: []

    function check(cond, label) {
        if (!cond) root.failures.push(label)
    }

    // The wash item a tile builds under its markQuery, found by the boxes it carries.
    function washOf(tile) {
        var stack = [tile]
        while (stack.length > 0) {
            var o = stack.pop()
            if (o.boxes !== undefined) return o
            for (var i = 0; i < o.children.length; i++) stack.push(o.children[i])
        }
        return null
    }

    // Why a tile's state does not name the drawn break, "" when it does: lines, letters kept, widths fitting the caption.
    function verdict(state, cap) {
        if (state.wrapAt === undefined || state.broken === undefined) return "state has no wrapAt or broken"
        if (state.lines !== 2 || state.broken !== true) return "Qt draws " + state.lines + " lines, broken=" + state.broken
        var shown = String(state.name).split("\n").join("")
        if (shown !== root.fixtureName) return "the caption drops letters: " + JSON.stringify(state.name)
        if (!(state.wrapAt > 0 && state.wrapAt < shown.length)) return "wrapAt " + state.wrapAt + " is no inner index"
        var a = shown.substring(0, state.wrapAt), b = shown.substring(state.wrapAt)
        if (String(state.name) !== a + "\n" + b) return "wrapAt " + state.wrapAt + " is not the break of " + JSON.stringify(state.name)
        // Line 1 and line 2 each fit the caption, so Qt had no reason to wrap again where Flea did not.
        if (face.advanceWidth(a) > cap.width || face.advanceWidth(b) > cap.width) return "a line is wider than the caption " + cap.width
        if (state.textHeight > state.slotHeight) return "the text overflows its slot"
        return ""
    }

    function measure() {
        for (var i = 0; i < reps.count; i++) {
            var tile = reps.itemAt(i)
            root.tiles[i] = tile
        }
        for (i = 0; i < reps.count; i++) {
            tile = reps.itemAt(i)
            var state = JSON.parse(ipc.seam.gridCaptionState(i))
            var why = root.verdict(state, tile.captionItem)
            root.check(why === "", "tile " + i + " width " + tile.width + ": " + why)
            // The old field shape, no break named: the verdict must refuse it.
            var old = { name: state.name, lines: state.lines, truncated: state.truncated, textHeight: state.textHeight, slotHeight: state.slotHeight, bottom: state.bottom, tileHeight: state.tileHeight }
            root.check(root.verdict(old, tile.captionItem) !== "", "tile " + i + " the old field shape passed the verdict")
            if (why !== "") continue
            var shown = String(state.name).split("\n").join("")
            var query = shown.substring(state.wrapAt - 2, state.wrapAt + 1)
            root.check(Match.run(shown, query).start === state.wrapAt - 2, "tile " + i + " query " + query + " is not the letters either side of the break")
            root.queries[i] = query
            tile.markQuery = query
        }
    }

    // The wash a straddling query draws: one box on each drawn line, the first ending where line 1 does.
    function washed() {
        for (var i = 0; i < reps.count; i++) {
            var tile = reps.itemAt(i), wash = root.washOf(tile)
            var boxes = wash ? wash.boxes : []
            root.check(boxes.length === 2, "tile " + i + " query " + root.queries[i] + " draws " + boxes.length + " wash boxes, want one per line")
            if (boxes.length !== 2) continue
            var lh = Flea.Theme.grid.captionLineHeight
            root.check(boxes[0].y === 0 && boxes[1].y === lh, "tile " + i + " boxes sit on lines at y " + boxes[0].y + " and " + boxes[1].y)
            root.check(boxes[0].width > 0 && boxes[1].width > 0, "tile " + i + " a wash box has no width")
            var state = JSON.parse(ipc.seam.gridCaptionState(i)), cap = tile.captionItem
            var line0 = String(state.name).split("\n")[0]
            root.check(Math.abs(boxes[0].x + boxes[0].width - (cap.width + face.advanceWidth(line0)) / 2) < 1, "tile " + i + " the first box does not end at the end of line 1")
            root.check(Math.abs(boxes[1].x - (cap.width - face.advanceWidth(String(state.name).split("\n")[1])) / 2) < 1, "tile " + i + " the second box does not start at the start of line 2")
        }
    }

    Timer {
        interval: 700; running: true; repeat: true
        onTriggered: {
            if (root.phase === 0) Flea.ViewState.setTextSize({ mode: 14 })
            else if (root.phase === 2) root.measure()
            else if (root.phase === 4) root.washed()
            else if (root.phase === 5) {
                running = false
                if (root.failures.length === 0)
                    console.log("GRIDCAPBREAK PASS base=14 window=1320 tiles=" + reps.count + " widths=" + root.paneWidths.map(root.cellW).join(",") + " queries=" + root.queries.join(","))
                for (var f = 0; f < root.failures.length; f++)
                    console.log("GRIDCAPBREAK FAIL " + root.failures[f])
                Quickshell.execDetached(["kill", String(Quickshell.processId)])
            }
            root.phase++
        }
    }
}
