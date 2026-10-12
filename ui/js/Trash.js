.pragma library

.import "Format.js" as Format
.import "Ops.js" as Ops

// The dd pair. A single d used to trash, and it sat in the middle of the letters a name is typed
// with, so the third keystroke of "Vid" trashed the row (issue 7). Delete and Ctrl+Delete are not
// letters and still go on one press, through Ops.trash directly.

// How long the first d stays armed. Long enough to be a deliberate pair, short enough that an arm
// nobody finished cannot be completed by a d typed minutes later.
var ARM_MS = 1500

// ui/js/Focus.js clears pane.trashArmedAt for every other action, so an arm never survives the key
// after it; this reads the stamp before it writes one, which is what makes the second press the pair.
function arm(pane) {
    if (pane.trashArmedAt > 0 && Date.now() - pane.trashArmedAt < ARM_MS) {
        pane.trashArmedAt = 0
        Ops.trash(pane)
        return
    }
    pane.trashArmedAt = Date.now()
    pane.message("Press d again to trash, or Delete on its own.", false)
}

// Window-level keys the Trash view borrows: "direct" skips pane.act as Focus.handleKey does, "act" goes through it, "trash" stays here.
function route(action) {
    if (action === "keymapSheet" || action === "pathBar") return "direct"
    if (action.indexOf("textSize") === 0) return "direct"
    if (action === "settings" || action === "sidebar") return "act"
    if (action.indexOf("tab") === 0) return "act"
    return "trash"
}

// The delete card's words come from a filled snapshot only (R0: the whole filled card or nothing), so an unfilled one says no word at all.
function filled(snapshot) {
    return typeof snapshot.count === "number"
}

// "Empty Trash?", or one whole sentence per count; Format.fill takes the grouped count into the placeholder.
function confirmTitle(snapshot) {
    if (!filled(snapshot)) return ""
    if (snapshot.all) return "Empty Trash?"
    return snapshot.count === 1 ? "Delete 1 item permanently?" : Format.fill("Delete %1 items permanently?", Format.count(snapshot.count))
}

function confirmBody(snapshot, scope) {
    if (!filled(snapshot)) return ""
    return snapshot.all ? Ops.deleteAllLine(snapshot.count, Format.size(snapshot.bytes || 0)) : Ops.deleteScopeLine(scope, snapshot.count)
}
