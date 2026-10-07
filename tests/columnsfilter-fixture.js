.pragma library

// The columnsfilter fixture: matches interleave with non-matches in name order, so
// every step from a kept row must skip a hidden row. Query "ap" keeps rows 0, 2, 4,
// 6, 8 and 10: 6 of the 12 below.
function buildRows() {
    return [
        { n: "Apps", d: true, i: "folder", p: 493, s: 0, m: 1, t: false, k: 0 },
        { n: "Clips", d: true, i: "folder", p: 493, s: 0, m: 2, t: false, k: 0 },
        { n: "Maps", d: true, i: "folder", p: 493, s: 0, m: 2, t: false, k: 0 },
        { n: "balsam.txt", d: false, i: "text-x-generic", p: 420, s: 3, m: 3, t: false, k: 0 },
        { n: "caption.png", d: false, i: "text-x-generic", p: 420, s: 4, m: 4, t: false, k: 0 },
        { n: "drift.txt", d: false, i: "text-x-generic", p: 420, s: 5, m: 5, t: false, k: 0 },
        { n: "gap.md", d: false, i: "text-x-generic", p: 420, s: 6, m: 6, t: false, k: 0 },
        { n: "hold.txt", d: false, i: "text-x-generic", p: 420, s: 7, m: 7, t: false, k: 0 },
        { n: "napkin.txt", d: false, i: "text-x-generic", p: 420, s: 8, m: 8, t: false, k: 0 },
        { n: "orbit.md", d: false, i: "text-x-generic", p: 420, s: 9, m: 9, t: false, k: 0 },
        { n: "paper.pdf", d: false, i: "text-x-generic", p: 420, s: 10, m: 10, t: false, k: 0 },
        { n: "quince.txt", d: false, i: "text-x-generic", p: 420, s: 11, m: 11, t: false, k: 0 }
    ]
}

function buildParentRows() {
    return [
        { n: "studio", d: true, i: "folder", p: 493, s: 0, m: 1, t: false, k: 0 },
        { n: "field", d: true, i: "folder", p: 493, s: 0, m: 2, t: false, k: 0 },
        { n: "notes.txt", d: false, i: "text-x-generic", p: 420, s: 1, m: 3, t: false, k: 0 }
    ]
}

// A search result is a path: base name "report-final.md", folder "docs".
function searchRow() { return { n: "docs/report-final.md", d: false, i: "text-x-generic", p: 420, s: 1, m: 1, t: false, k: 0 } }

// Columns rows take List's match mark: a "/" row marks its plain name and a search row also splits name and folder.
// Read by item and model value, never by shown text. The pane flips to a search for one turn and back.
function searchPane(query) { return { searchMode: "files", filterQuery: "", swap: { answeredQuery: query } } }

// The folder takes List's cellInk (ui/Row.qml) and the clip mark follows the drawn label, on a marking search row.
function inkFailures(probe, theme) {
    var out = []
    var fg = theme.color.foreground
    var folder = probe.folderItem()
    probe.hovered = false
    if (String(folder.color) !== String(Qt.darker(fg, 1.4))) out.push("rest folder ink " + folder.color + ", want List's darker foreground")
    probe.cursor = true
    if (!Qt.colorEqual(folder.color, fg)) out.push("cursor folder ink " + folder.color + ", want foreground")
    probe.cursor = false
    probe.clipMark = "scissors"
    var label = probe.nameItem()
    var end = label.mapToItem(probe, 0, 0).x + Math.min(label.implicitWidth, label.width) + theme.spacing.gap
    if (Math.abs(probe.clipX() - end) > 0.01) out.push("marking row clip mark at " + probe.clipX() + ", want " + end + " after the visible label")
    probe.clipMark = ""
    return out
}

function markFailures(slashRow, searchRowItem, pane, theme) {
    var out = inkFailures(searchRowItem, theme)
    var mark = slashRow.nameItem()
    if (!slashRow.marking || slashRow.bMode) out.push("slash row marking " + slashRow.marking + " bMode " + slashRow.bMode + ", want true false")
    if (mark.matchStart !== 0 || mark.matchLength !== 2) out.push("slash run " + mark.matchStart + "," + mark.matchLength + ", want 0,2")
    if (slashRow.folderItem().text !== "") out.push("slash row folder " + slashRow.folderItem().text + ", want none")
    var hit = searchRowItem.nameItem()
    if (!searchRowItem.bMode) out.push("search row bMode false, want true")
    if (hit.matchStart !== 7 || hit.matchLength !== 5) out.push("search run " + hit.matchStart + "," + hit.matchLength + ", want 7,5 on the base name")
    if (searchRowItem.folderItem().text !== "docs") out.push("search folder " + searchRowItem.folderItem().text + ", want docs")
    pane.searchMode = "files"
    pane.swap.answeredQuery = "ap"
    if (!slashRow.bMode || slashRow.markQuery !== "ap") out.push("pane search gives bMode " + slashRow.bMode + " query " + slashRow.markQuery + ", want true ap from the answered query")
    pane.searchMode = ""
    pane.swap.answeredQuery = ""
    if (slashRow.bMode) out.push("leaving the search leaves bMode on")
    return out
}

// QML helpers live here to hold tests/columnsfilter.qml under its 400 cap.
function activeCount(area) { return area.activeColumn().viewport.count }
function parentNames(area) { return area.peekNames("/probe") }
function preview(area) { return area.previewColumn }
function stamps(ipc) { return JSON.parse(ipc.seam.filterStamps()) }
function shownHas(pane, row) { return pane.shown !== null && pane.shown.indexOf(row) >= 0 }
function answerParentPeek(backend, windowSize) {
    var rows = buildParentRows()
    backend.peeked("/probe", false, rows.length, rows, false, 0, false, windowSize)
}
