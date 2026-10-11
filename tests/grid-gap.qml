//@ pragma ShellId flea-grid-gap-test

import QtQuick
import Quickshell
import "flea" as Flea
import "flea/js/GridGeometry.js" as GridGeometry

// The first tile's frame stood 1 px from both edge lines; the live view is read at three widths.
ShellRoot {
    id: root

    // The pane GridArea reads at startup; functions are inert because nothing is pressed here.
    Component {
        id: paneStub
        QtObject {
            signal filterQueryChanged
            signal pathChanged
            property int shownTotal: 12
            property var shown: null
            property int total: 12
            property int held: 0
            property var rows: []
            property int cursorIndex: 0
            property int renamingIndex: -1
            property string renameError: ""
            property bool renamePending: false
            property bool listInFlight: false
            property string listingState: "ready"
            property bool visible: true
            property int previewIndex: -1
            property int coalesceMs: 16
            property int settleMs: 120
            property int refetchMargin: 25
            property int buffer: 150
            property int windowSize: 200
            property var thumbState: ({ file: {}, order: [] })
            property var dirSizeState: ({ file: {}, order: [] })
            property var selectionBand: null
            property var backend: ({
                thumb: function (rows) {}, thumbcancel: function (rows) {},
                dirsize: function (rows) {}, dirsizecancel: function () {}, window: function (start, count) {}
            })
            function rowFor(index) {
                return ({ n: "tile-" + index + ".txt", i: "text-x-generic", p: 0, d: false, s: 1, m: 0, t: false, v: 0 })
            }
            function isSelected(index) { return false }
            function commitRename(name) {}
            function setCursor(index) {}
            function focusRequested() {}
        }
    }

    // GridArea closes the menu on every scroll, so the stub answers close and nothing else.
    Component {
        id: menuStub
        QtObject {
            function close() {}
        }
    }

    Column {
        Flea.GridArea { id: narrow; width: 500; height: 320; pane: paneStub.createObject(root); menu: menuStub.createObject(root) }
        Flea.GridArea { id: middle; width: 800; height: 320; pane: paneStub.createObject(root); menu: menuStub.createObject(root) }
        Flea.GridArea { id: wide; width: 1200; height: 320; pane: paneStub.createObject(root); menu: menuStub.createObject(root) }
    }

    // Delegates are built on the polish pass, so each read waits one turn like mount-listing.qml.
    Timer {
        interval: 800
        running: true
        repeat: false
        onTriggered: root.measure()
    }
    // The last row builds only after the reveal scrolls to it, so its read waits one more turn.
    Timer {
        id: bottomTimer
        interval: 800
        running: false
        repeat: false
        onTriggered: root.measureBottom()
    }
    property var failures: []

    function measure() {
        root.failures = []
        var failures = root.failures
        var gap = Flea.Theme.spacing.gap
        var hairline = Flea.Theme.spacing.hairline
        var minCell = Flea.Theme.grid.minCellWidth
        var thumbPx = Flea.ViewState.thumbnailPixels
        var padX = Flea.Theme.spacing.rowPaddingX
        var grids = [narrow, middle, wide]
        for (var g = 0; g < grids.length; g++) {
            var grid = grids[g]
            var at = "at width " + grid.width
            var expColumns = GridGeometry.columnsFor(grid.width, minCell, thumbPx, padX, gap, padX)
            var expCell = GridGeometry.cellWidthFor(grid.width, expColumns, gap, padX)
            if (grid.leftMargin !== gap)
                failures.push("leftMargin " + grid.leftMargin + " " + at)
            if (grid.topMargin !== gap)
                failures.push("topMargin " + grid.topMargin + " " + at)
            if (grid.bottomMargin !== gap)
                failures.push("bottomMargin " + grid.bottomMargin + " " + at)
            if (grid.columns !== expColumns)
                failures.push("columns " + grid.columns + " != " + expColumns + " " + at)
            if (grid.cellWidth !== expCell)
                failures.push("cellWidth " + grid.cellWidth + " != " + expCell + " " + at)
            var first = grid.itemAtIndex(0)
            if (first === null) {
                failures.push("no delegate at index 0 " + at)
                continue
            }
            // View coordinates, so the content origin convention cannot smuggle the margin back.
            var pt = first.mapToItem(grid, 0, 0)
            if (pt.x + hairline < gap)
                failures.push("first frame x " + (pt.x + hairline) + " inside the gap " + at)
            if (pt.y + hairline < gap)
                failures.push("first frame y " + (pt.y + hairline) + " inside the gap " + at)
            // The scroll lane stays clear: the last tile of the first row ends short of it.
            var last = grid.itemAtIndex(expColumns - 1)
            if (last === null) {
                failures.push("no delegate at index " + (expColumns - 1) + " " + at)
            } else {
                var end = last.mapToItem(grid, last.width, 0)
                if (end.x > grid.width - padX + 1)
                    failures.push("last tile ends at " + end.x + ", the lane starts at " + (grid.width - padX) + " " + at)
            }
        }
        // A cursor move to the last row scrolls to the end through the real reveal, then the bottom reads one turn later.
        for (var s = 0; s < grids.length; s++) {
            grids[s].positionViewAtBeginning()
            grids[s].pane.cursorIndex = grids[s].count - 1
        }
        bottomTimer.start()
    }

    function measureBottom() {
        var failures = root.failures
        var gap = Flea.Theme.spacing.gap
        var hairline = Flea.Theme.spacing.hairline
        var padX = Flea.Theme.spacing.rowPaddingX
        var grids = [narrow, middle, wide]
        for (var g = 0; g < grids.length; g++) {
            var grid = grids[g]
            var at = "at width " + grid.width
            var last = grid.itemAtIndex(grid.count - 1)
            if (last === null) {
                failures.push("no delegate at last index " + (grid.count - 1) + " " + at)
                continue
            }
            // View coordinates, so the frame bottom plus its hairline is the tile bottom here.
            var end = last.mapToItem(grid, 0, 0)
            var frameBottom = end.y + last.height - hairline
            if (frameBottom + hairline > grid.height - gap)
                failures.push("last tile bottom " + (frameBottom + hairline) + " past " + (grid.height - gap) + " " + at)
        }
        // Ctrl+wheel through the real zoomWheel: Qt 6.12's notch (pixels 15 beside angle 120, no phase) is one whole step.
        Flea.ViewState.changeSetting("preview.thumbSize", "medium")
        narrow.zoomTravel = 0
        narrow.zoomWheel({ phase: Qt.NoScrollPhase, pixelDelta: { x: 0, y: 15 }, angleDelta: { x: 0, y: 120 }, modifiers: Qt.ControlModifier })
        if (narrow.zoomTravel !== 0 || Flea.ViewState.thumbnailSize !== "large")
            failures.push("a Qt 6.12 notch took medium to " + Flea.ViewState.thumbnailSize + " with travel " + narrow.zoomTravel + ", want large")
        narrow.zoomWheel({ phase: Qt.ScrollUpdate, pixelDelta: { x: 0, y: 24 }, angleDelta: { x: 0, y: 120 }, modifiers: Qt.ControlModifier })
        if (Math.abs(narrow.zoomTravel - 24 / narrow.touchpadStep) > 1e-9)
            failures.push("a 24 px touchpad stroke left zoom travel " + narrow.zoomTravel + ", want " + 24 / narrow.touchpadStep)
        if (failures.length === 0)
            console.log("GRID_GAP PASS widths=500,800,1200 gap=" + gap + " lane=" + padX + " columns=" + narrow.columns + "," + middle.columns + "," + wide.columns)
        for (var f = 0; f < failures.length; f++)
            console.log("GRID_GAP FAIL " + failures[f])
        Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }
}
