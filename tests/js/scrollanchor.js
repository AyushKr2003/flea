.import "../../ui/js/Selection.js" as Selection
.import "../../ui/js/Filter.js" as Filter
.import "../../ui/js/Marks.js" as Marks
.import "../../ui/js/Ops.js" as Ops

// Issue #286: a selection made across rows scrolled out of view must act on
// every selected row. 500 rows, a held window of 60, anchor at row 5,
// Shift+click at row 400 after the window moved: copy's path list must hold
// all 396 paths in order. Same for a Ctrl+click set spanning two windows.
// The pane fake mirrors ui/Pane.qml: rowFor answers null outside
// [held, held + rows.length), and the wheel pulls the cursor onto the
// viewport through Filter.clampCursor, the way ui/List.qml:207-210 does.
function pane() {
    var p = {
        rows: [], held: 0, total: 500, cursorIndex: 0, cursorSeq: 0,
        shown: null, shownTotal: 500, filterQuery: "", selectionAnchor: 0,
        selectionVersion: 0, path: "/d", listInFlight: false,
        clipPending: null, clipQueue: [], clipSequence: 0, pathsPending: null,
        clipboard: null, clipboardState: null
    }
    p.selection = Selection.create()
    p.selectedIndices = function () { return p.selection.indices() }
    moveWindow(p, 0)
    p.rowFor = function (index) {
        var offset = index - p.held
        return offset < 0 || offset >= p.rows.length ? null : p.rows[offset]
    }
    p.join = function (a, b) { return a + "/" + b }
    p.showRow = function () {}
    p.message = function () {}
    p.backend = {
        heldListing: 1,
        asked: [],
        askPaths: function (rows) { p.backend.asked.push(rows.slice()) },
        send: function () {}
    }
    return p
}

// A window move lands new rows; the selection stands, as ui/PaneSwap.qml does.
function moveWindow(p, start) {
    p.held = start
    p.rows = []
    for (var i = start; i < start + 60; i++) p.rows.push({ n: "f" + i + ".txt", d: false })
}

// ui/Pane.qml selectOnly: a plain click latches the anchor at the clicked row.
function click(p, i) {
    Filter.setCursor(p, i, 0)
    p.selection.only(p.cursorIndex)
    p.selectionAnchor = p.cursorIndex
    p.selectionVersion++
}

// Copy through the real key path and resolve every asked row the way the
// backend's paths answer does, in listing order.
function copyResolved(p) {
    Ops.clip(p, false)
    var asked = p.backend.asked
    var rows = asked.length > 0 ? asked[asked.length - 1] : []
    var list = []
    for (var i = 0; i < rows.length; i++) list.push("/d/f" + rows[i] + ".txt")
    Ops.pathsResolved(p, list)
    return rows
}

function run(check) {
    // The reported gesture: click row 5, wheel the anchor out of view, Shift+click 400.
    var p = pane()
    click(p, 5)
    moveWindow(p, 340)
    Filter.clampCursor(p, 370, 399)
    check("the wheel pulls the cursor onto the viewport", p.cursorIndex, 370)
    Marks.extendToRow(p, 400)
    check("Shift+click across the scrolled window keeps the clicked anchor", p.selectionAnchor, 5)
    var rows = copyResolved(p)
    check("copy asks for every row between anchor and click", rows.length, 396)
    check("copy starts at the anchor row", p.clipboard.paths[0], "/d/f5.txt")
    check("copy ends at the clicked row", p.clipboard.paths[p.clipboard.paths.length - 1], "/d/f400.txt")
    var ordered = true
    for (var i = 0; i < p.clipboard.paths.length; i++) {
        if (p.clipboard.paths[i] !== "/d/f" + (5 + i) + ".txt") { ordered = false; break }
    }
    check("copy holds all 396 paths in order", ordered && p.clipboard.paths.length === 396, true)

    // Shift+J after the same scroll keeps the anchor too, not the pulled cursor.
    var k = pane()
    click(k, 5)
    moveWindow(k, 340)
    Filter.clampCursor(k, 370, 399)
    Marks.extend(k, 1)
    check("Shift+J after a scroll ranges from the anchor", k.selectedIndices().length, 367)

    // A lone row restored without its anchor (ui/js/Tabs.js restoreSelection) still ranges from that row.
    var t = pane()
    click(t, 40)
    t.selection.only(5)
    Filter.setCursor(t, 5, 0)
    Marks.extend(t, 1)
    check("Shift+J from a restored lone row ranges from that row", t.selectedIndices().join(","), "5,6")

    // Ctrl+clicks are window-independent: one mark per click, anchor at each click.
    var c = pane()
    click(c, 5)
    moveWindow(c, 340)
    Filter.clampCursor(c, 370, 399)
    Marks.toggleRow(c, 400)
    check("Ctrl+clicks spanning two windows keep both marks", c.selectedIndices().join(","), "5,400")
    var crows = copyResolved(c)
    check("copy asks for every Ctrl+click mark", crows.join(","), "5,400")
    check("copy resolves both marks in order",
          c.clipboard.paths.join(","), "/d/f5.txt,/d/f400.txt")
}
