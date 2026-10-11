.import "flea/js/TextSize.js" as TextSize
.import "flea/js/Tap.js" as Tap
.import "sidebar-flows-rail.js" as RailPress

// One rail row per trailing shape, each with the board's rule for where its label ends (see railBoardEdges).
var RAIL_BOARD = [
    { name: "a share's square", want: "slot", label: "Archive", path: "", group: "network", kind: "share", uri: "smb://example.com/data", mounted: false, glyph: "server" },
    { name: "an eject mark", want: "slot", label: "NAS", path: "", group: "network", kind: "share", uri: "smb://example.com/data", mounted: true, glyph: "server" },
    { name: "a phone's square", want: "slot", label: "SAMSUNG Android", path: "", group: "device", kind: "phone", uri: "mtp://x", size: null, mounted: false, glyph: "smartphone" },
    { name: "a mounted phone's mark", want: "slot", label: "SAMSUNG Android", path: "", group: "device", kind: "phone", uri: "mtp://x", size: null, mounted: true, glyph: "smartphone" },
    { name: "a volume with no size", want: "slot", label: "QEMU HARDDISK", path: "", group: "device", kind: "volume", device: "/dev/sdb1", mounted: false, removable: false, size: null, glyph: "drive" },
    { name: "a drive size and a square", want: "number", label: "QEMU HARDDISK", path: "", group: "device", kind: "volume", device: "/dev/sdb1", mounted: false, removable: false, size: 1000398934016, glyph: "drive" },
    { name: "a drive size and an eject mark", want: "number", label: "128GB", path: "/run/media/gm/128GB", group: "device", kind: "volume", device: "/dev/sda1", mounted: true, removable: true, size: 116100000000, glyph: "drive" },
    { name: "the system disk's size", want: "number", label: "minipc", path: "/", group: "device", kind: "disk", device: "/dev/nvme0n1", mounted: true, removable: false, size: 239000000000, glyph: "drive" },
    { name: "the Trash count", want: "count", label: "Trash", path: "trash:///", group: "trash", kind: "trash", glyph: "trash", count: 3 },
    { name: "a system disk with no size", want: "none", label: "minipc", path: "/", group: "device", kind: "disk", device: "/dev/nvme0n1", mounted: true, removable: false, size: null, glyph: "drive" },
    { name: "a Dropbox row", want: "none", label: "Dropbox", path: "/home/gm/Dropbox", group: "network", kind: "dropbox", glyph: "cloud" },
    { name: "a favourite", want: "none", label: "Home", path: "/home", group: "favorite", kind: "favorite", glyph: "house" }
]

// RailEject.html and RailDetails.html: the label ends one gap before its number, else its slot; the Trash count has no slot.
function railBoardEdges(row, want, pad, gap, slot, mark) {
    var edge = row.width - pad
    if (want === "slot") edge -= slot + gap
    else if (want === "number") edge -= slot + gap + row.detailItem.width + gap
    else if (want === "count") edge -= row.detailItem.width + gap
    return { left: pad + mark + gap, right: edge }
}

// The name of the first board row still missing, short of its width, or short of the detail its kind draws; "" when none.
function railBoardWaiting(rows, width) {
    for (var i = 0; i < RAIL_BOARD.length; i++) {
        var row = rows.itemAt(i), want = RAIL_BOARD[i].want
        if (!row || row.width !== width || ((want === "number" || want === "count") && row.detail.length === 0)) return RAIL_BOARD[i].name
    }
    return ""
}

// Additional real-UI proofs share the hunt's fixture, driver and tally.
function steps(root, pane, state, theme) {
    var expectedSize = 0
    var tests = [
        function () {
            state.changeKey("openMode", "double")
            pane.chooseView("list")
            pane.open(root.fixture)
            return true
        },
        function () {
            if (!root.ready(root.fixture)) return false
            expectedSize = TextSize.stepped(state.textSize, state.omarchyBase, 1).mode
            var sheet = root.openSheet()
            sheet.query = "larger"
            sheet.resultCursor = sheet.queryResults.findIndex(function (row) { return row.action === "textSizeUp" })
            root.check("control: sheet offers Larger", sheet.resultCursor >= 0, true)
            sheet.activateResult()
            return true
        },
        function () {
            root.check("sheet-window-action: Larger steps the real text size", theme.baseSize, expectedSize)
            state.followTextSize()
            state.changeLeaf("places", { rail: "hidden" })
            return true
        },
        function () {
            if (pane.sidebar) return false
            var sheet = root.openSheet()
            sheet.query = "home"
            sheet.resultCursor = sheet.queryResults.findIndex(function (row) { return row.section === 2 && row.name === "Home" })
            root.check("control: hidden rail Home can be chosen", sheet.resultCursor >= 0, true)
            sheet.activateResult()
            return true
        },
        function () {
            if (pane.listInFlight) return false
            root.check("sheet-hidden-rail: Home runs its real navigation", pane.path, pane.home)
            state.changeLeaf("places", { rail: "shown" })
            pane.open(root.fixture)
            return true
        },
        function () {
            if (!root.ready(root.fixture)) return false
            pane.trash.open()
            return true
        },
        function () {
            var trash = pane.trash.item
            if (!trash || trash.busy) return false
            root.check("control: Trash has its seeded item", trash.total, 1)
            trash.choose(0, false)
            pane.trash.sheetAction("keymapSheet")
            var sheet = root.sheet()
            sheet.query = "restore"
            root.check("trash-sheet: query offers Restore", sheet.queryResults.some(function (row) { return row.menuAction === "restoreTrashSelection" }), true)
            sheet.query = "empty trash"
            root.check("trash-sheet: query offers Empty Trash", sheet.queryResults.some(function (row) { return row.menuAction === "emptyTrash" && row.danger }), true)
            sheet.query = "delete permanently"
            sheet.resultCursor = sheet.queryResults.findIndex(function (row) { return row.menuAction === "deletePermanently" && row.danger })
            root.check("trash-sheet: permanent delete keeps its danger", sheet.resultCursor >= 0, true)
            sheet.activateResult()
            return true
        },
        function () {
            var trash = pane.trash.item
            if (trash.busy) return false
            root.check("trash-sheet: destructive query opens confirmation", trash.confirming, true)
            trash.close()
            return true
        }
    ]
    return tests.concat(clicks(root, pane, "list"), clicks(root, pane, "grid"), clicks(root, pane, "columns"), RailPress.steps(root, pane, state))
}

function clicks(root, pane, mode) {
    var at = 0
    var name = "renamed.txt"
    function row() { return pane.visibleItemFor(root.indexOf(name)) }
    function settled() { return Date.now() - at > Qt.styleHints.mouseDoubleClickInterval + 100 }
    function blank() {
        var item = row(), label = item.captionItem || item.nameItem()
        root.click(label, label.width - 2, Math.min(label.implicitHeight, label.height) / 2)
        at = Date.now()
    }
    return [
        function () {
            pane.chooseView(mode)
            pane.cancelSlowClick()
            pane.clearSelection()
            return true
        },
        function () {
            if (!row()) return false
            var item = row(), label = item.captionItem || item.nameItem()
            // Sample input: 412 237 (rowNameCentre x y, window-relative), or empty for a row with no name.
            var centre = root.ipc().rowNameCentre(root.indexOf(name)).split(" ").map(Number)
            var point = item.mapFromItem(null, centre[0], centre[1])
            root.check("rowNameCentre-" + mode + ": lands inside its own row",
                centre.length === 2 && point.x >= 0 && point.x < item.width && point.y >= 0 && point.y < item.height, true)
            root.check("rowNameCentre-" + mode + ": product accepts the drawn name",
                Tap.onName(label, null, {x: centre[0], y: centre[1]}, !!item.captionItem), true)
            root.check("rowNameCentre-" + mode + ": missing row has no target", root.ipc().rowNameCentre(-1), "")
            root.clickName(name)
            at = Date.now()
            return true
        },
        function () { if (!settled()) return false; root.clickName(name); at = Date.now(); return true },
        function () {
            if (!settled()) return false
            root.check("slow-click-" + mode + ": second name click renames", pane.renamingIndex, root.indexOf(name))
            pane.renamingIndex = -1
            pane.cancelSlowClick()
            return true
        },
        function () { blank(); return true },
        function () { if (!settled()) return false; blank(); return true },
        function () {
            if (!settled()) return false
            root.check("slow-click-name-only-" + mode + ": blank label slot only selects", pane.renamingIndex, -1)
            pane.renamingIndex = -1
            pane.cancelSlowClick()
            return true
        }
    ]
}
