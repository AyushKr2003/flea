.import "../../ui/js/Trash.js" as Trash
.import "../../ui/js/Ops.js" as Ops
.import "../../ui/js/Sort.js" as Sort
.import "sourcefixture.js" as Source

// The dd pair, issue 7. A single d used to trash and sat among the letters a name is typed with, so
// the third keystroke of "Vid" trashed the row. These drive Trash.arm directly, because the stamp
// and the window are the whole of the policy and neither needs a window to be true.

// What Ops.trash reaches for, plus the stamp Trash.arm reads and writes.
function pane() {
    var p = {
        trashArmedAt: 0,
        cursorIndex: 3,
        // The filter's own list, null while nothing is filtered, which is what the pane always carries.
        shown: null,
        trashedIdx: [],
        said: "",
        selectedIndices: function () { return [] }
    }
    p.message = function (text, isError) { p.said = text }
    p.backend = { trash: function (idx) { p.trashedIdx = idx } }
    return p
}

function run(check) {
    var p = pane()
    Trash.arm(p)
    check("the first d trashes nothing and says what to press", p.trashedIdx.length, 0)
    check("and the sentence names both routes", p.said,
          "Press d again to trash, or Delete on its own.")
    check("and it leaves the pair armed", p.trashArmedAt > 0, true)
    Trash.arm(p)
    check("the second d inside the window trashes the cursor row", p.trashedIdx.join(","), "3")
    check("and disarms, so a third d only arms again", p.trashArmedAt, 0)

    // A stamp older than the window is not half a pair, however long it has stood.
    var stale = pane()
    stale.trashArmedAt = Date.now() - 60000
    Trash.arm(stale)
    check("a d a minute after the first is a fresh arm, not the second of a pair",
          stale.trashedIdx.length, 0)
    check("and it re-arms rather than completing a pair nobody meant",
          stale.trashArmedAt > Date.now() - 1000, true)

    // Delete is not a letter a name is typed with, so it never armed and still goes on one press.
    var direct = pane()
    Ops.trash(direct)
    check("Delete trashes on one press, with no arming", direct.trashedIdx.join(","), "3")
    check("and it leaves no arm behind it", direct.trashArmedAt, 0)

    // The selection wins over the cursor, the rule Ops.targetIndices keeps for every write.
    var picked = pane()
    picked.selectedIndices = function () { return [1, 4] }
    picked.trashArmedAt = Date.now()
    Trash.arm(picked)
    check("the pair trashes the selection when there is one", picked.trashedIdx.join(","), "1,4")

    // Issue 227: window-level keys from the Trash view reach the window handlers, "direct" ones skipping pane.act.
    check("? reaches the sheet without going through the pane", Trash.route("keymapSheet"), "direct")
    check("the path bar does too", Trash.route("pathBar"), "direct")
    check("larger text does too", Trash.route("textSizeUp"), "direct")
    check("smaller text does too", Trash.route("textSizeDown"), "direct")
    check("reset size does too", Trash.route("textSizeReset"), "direct")
    check("settings goes through the pane", Trash.route("settings"), "act")
    check("the rail toggle does too", Trash.route("sidebar"), "act")
    check("a new tab does too", Trash.route("tabNew"), "act")
    check("closing a tab does too", Trash.route("tabClose"), "act")
    check("a numbered tab does too", Trash.route("tab3"), "act")
    // Trash-own keys stay in Trash; ordinary listing keys never reach the covered pane.
    check("a Trash cursor key stays in Trash", Trash.route("cursorDown"), "trash")
    check("the dd arm stays in Trash", Trash.route("trashArm"), "trash")
    check("the row menu stays in Trash", Trash.route("menu"), "trash")
    check("a listing search stays out", Trash.route("search"), "trash")
    check("a listing filter stays out", Trash.route("filter"), "trash")
    check("the covered pane's terminal stays out", Trash.route("openTerminal"), "trash")
    check("the covered pane's folder path stays out", Trash.route("copydirpath"), "trash")
    // Wire pins, not execution: the checks above prove the decision, these prove the QML calls it.
    var trashSrc = Source.source("ui/TrashView.qml")
    check("wire pin: Trash forwards by route instead of three names",
        trashSrc.indexOf('TrashKeys.route(action) !== "trash"') >= 0, true)
    var hostSrc = Source.source("ui/TrashHost.qml")
    check("wire pin: host opens the sheet on the Trash host",
        hostSrc.indexOf("pane.keymapSheet.open(root)") >= 0, true)
    var windowDispatch = hostSrc.indexOf("Focus.dispatchAction(action, root.pane)") >= 0
    var focusSrc = Source.source("ui/js/Focus.js")
    check("wire pin: host asks the bar through the pane signal",
        windowDispatch && focusSrc.indexOf("root.pathBarRequested()") >= 0, true)
    check("wire pin: host asks the size through the pane signal",
        windowDispatch && focusSrc.indexOf("root.textSizeRequested(") >= 0, true)

    // 0.3.10: the list is newest deleted first and m opens on the cursor row.
    check("an empty Trash keeps the whole-Trash menu", Trash.menuTarget(0, 0, false), "strip")
    check("m with nothing marked opens the cursor row's menu", Trash.menuTarget(5, 0, false), "cursor")
    check("a lone mark on the cursor row is still the cursor row's menu", Trash.menuTarget(5, 1, true), "cursor")
    check("a lone mark off the cursor row is the marked rows' menu", Trash.menuTarget(5, 1, false), "marked")
    check("two marked rows open the marked rows' menu", Trash.menuTarget(5, 2, true), "marked")
    check("a bulk selection opens the marked rows' menu", Trash.menuTarget(5000, 5000, true), "marked")
    check("one item with nothing marked is the cursor row's menu", Trash.menuTarget(1, 0, false), "cursor")
    var rust = Source.source("src/backend/trashbrowse.rs")
    check("wire pin: the listing sorts by deletion date, newest first, before the uri tie",
        rust.indexOf("dated.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.uri.cmp(&b.1.uri)))") >= 0, true)
    check("wire pin: one gio list dates every volume's items, no per-item call",
        rust.indexOf('gio(&["list", "-u", "-a", "trash::deletion-date", "trash:///"])') >= 0 && rust.indexOf("fn deletion_date(") < 0, true)
    check("wire pin: the backend orders every listing it reads",
        rust.indexOf("newest_first(&mut items, |item| dates.get(&item.uri)") >= 0, true)
    check("wire pin: the view lands on the newest row and m asks the target rule",
        trashSrc.indexOf("if (landing && total > 0) choose(0, false)") >= 0 && trashSrc.indexOf("TrashKeys.menuTarget(total, selectedCount, isSelected(item.uri))") >= 0, true)
    check("wire pin: the header draws the shared descending mark", trashSrc.indexOf("text: Sort.title(\"Deleted\", true)") >= 0, true)
    check("wire pin: Header.qml draws its mark from the same function", Source.source("ui/Header.qml").indexOf("Sort.title(label, root.sortDesc)") >= 0, true)
    check("the shared mark is the List view's pair", Sort.title("Modified", true) + "|" + Sort.title("Modified", false), "Modified \u25be|Modified \u25b4")
}
