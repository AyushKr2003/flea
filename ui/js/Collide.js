.pragma library
.import "Format.js" as Format
.import "Ops.js" as Ops
.import "Status.js" as Status
.import "Swap.js" as Swap

// The question a paste or a drop asks before it lands on names that exist, as decisions ui/CollideHost.qml and ui/CollideConfirm.qml wire.

// Left to right, the order h, l and Tab walk.
var BUTTONS = ["cancel", "skip", "keep", "merge", "replace"]
var LABELS = { cancel: "Cancel", skip: "Skip", keep: "Keep both", merge: "Merge", replace: "Replace" }
// Where the card opens, and so what a reflexive Enter takes: the one choice that changes nothing already there.
var START = "keep"
var EXPLAIN = "Replaced items go to Trash, and Undo restores them."
// What a transfer carries when nothing collided: any name that appears after the question is refused.
var NONE = "refuse"
var WAITING = "A transfer is already waiting on its question; try again once it is answered."

// The folder's own name, which is what the title says; the root has no leaf, so it says itself.
function folderName(dest) {
    var path = String(dest || "")
    var cut = path.lastIndexOf("/")
    var leaf = cut >= 0 ? path.substring(cut + 1) : path
    return leaf.length > 0 ? leaf : "/"
}

// "screenshot.png already exists in Pictures" for one, "3 items already exist in Downloads" for several.
function title(names, total, dest) {
    if (total === 1 && names.length > 0)
        return names[0].n + " already exists in " + folderName(dest)
    return Format.count(total) + " items already exist in " + folderName(dest)
}

// The row under the list, empty when every collision is already on it.
function more(total, shown) {
    return total > shown ? "and " + Format.count(total - shown) + " more" : ""
}

// Only the buttons the card shows take the ring; a hidden Merge never holds it.
function shownButtons(showMerge) {
    return showMerge === true ? BUTTONS : BUTTONS.filter(function (b) { return b !== "merge" })
}

// h and l stop at the ends like TrashConfirm's pair; Tab and Backtab come round.
function moved(focus, key, showMerge) {
    var shown = shownButtons(showMerge)
    var at = shown.indexOf(focus)
    if (at < 0)
        at = shown.indexOf(START)
    var last = shown.length - 1
    if (key === Qt.Key_H || key === Qt.Key_Left)
        return shown[Math.max(0, at - 1)]
    if (key === Qt.Key_L || key === Qt.Key_Right)
        return shown[Math.min(last, at + 1)]
    if (key === Qt.Key_Tab)
        return shown[(at + 1) % shown.length]
    if (key === Qt.Key_Backtab)
        return shown[(at + last) % shown.length]
    return shown[at]
}

function activates(key) {
    return key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Space
}

// The transfer the card holds, its rows stamped in the numbering they were read in; a menu's is resolved from the menu's own capture.
function waiting(request, held) {
    return request.menuId ? request : Swap.named(request, held)
}

// One question at a time, open or still in flight: a second is refused out loud rather than replacing the first.
function refusal(opened, pending) {
    return opened || pending !== null ? WAITING : ""
}

// A refused question ends the wait the same way an answered one does: the card never opens, so nothing stays waiting.
function droppedPending(where, input) {
    return where === "stale" && (input === "collisions" || input === "mergecollisions")
}

// The question names the same sources the transfer will, in the backend's order: a shelf drag's paths, a menu's selection, paths, rows.
function question(request, probe, id) {
    var asked = { c: "collisions", id: id, dest: request.dest }
    if (probe && probe.length > 0)
        asked.paths = probe
    else if (request.menuId)
        asked.menuId = request.menuId
    else if (request.paths && request.paths.length > 0)
        asked.paths = request.paths
    else
        asked.rows = request.rows || []
    // Rows are asked about in the numbering the transfer will name, ui/js/Swap.js named().
    if (asked.rows && request.listing !== undefined)
        asked.listing = request.listing
    return asked
}

// The waiting transfer with the answer on it; the id is what lets the backend cover only the names it listed.
function transfer(request, choice, id) {
    return Object.assign({}, request, { collide: choice, collideId: id })
}

// Paste as links answers on the waiting request like a transfer; rows ride along only when named, so paths-only pastes skip listing checks.
function link(request, choice, id) {
    var out = { c: "link", op: request.op, paths: request.paths || [],
                dest: request.dest, collide: choice, collideId: id }
    if (request.rows && request.rows.length > 0) out.rows = request.rows
    if (request.listing !== undefined) out.listing = request.listing
    return out
}

// After Merge, one walk of the sources against the destination, before anything is written.
function mergeQuestion(request, probe, id) {
    var asked = { c: "mergecollisions", id: id, dest: request.dest }
    if (probe && probe.length > 0)
        asked.paths = probe
    else if (request.menuId)
        asked.menuId = request.menuId
    else if (request.paths && request.paths.length > 0)
        asked.paths = request.paths
    else
        asked.rows = request.rows || []
    if (asked.rows && request.listing !== undefined)
        asked.listing = request.listing
    return asked
}

// The merge transfer with the second card's answer on it; the id names the walk it answers.
function mergeTransfer(request, inner, id) {
    return Object.assign({}, request, { collide: "merge", collideId: id, inner: inner })
}

// The second card names the folder it merges into: the one merging folder, else the destination.
function mergeDest(request, outerNames) {
    var folders = (outerNames || []).filter(function (n) { return n.d === true }).map(function (n) { return n.n })
    if (folders.length === 1)
        return String(request.dest).replace(/\/$/, "") + "/" + folders[0]
    return request.dest
}

// The board's merged line as whole %1/%2 labels, joined once; the undo hint stays its suffix.
var MERGED_LINE = "Merged %1 into %2"
var MERGED_KEPT = "%1 kept both"
var MERGED_FAILED = "%1 failed"
var MERGED_SKIPPED = "%1 skipped"
function merged(count, keptBoth, leaf, failed, skipped, cancelled, note) {
    var segments = [MERGED_LINE.replace("%1", Ops.items(count)).replace("%2", leaf)]
    if (keptBoth > 0) segments.push(MERGED_KEPT.replace("%1", Format.count(keptBoth)))
    if (failed > 0) segments.push(MERGED_FAILED.replace("%1", Format.count(failed)))
    if (skipped > 0) segments.push(MERGED_SKIPPED.replace("%1", Format.count(skipped)))
    if (cancelled) segments.push("cancelled")
    if (count > 0 && String(note || "").length > 0) segments.push(note)
    var line = segments.join(" · ")
    return line + (count > 0 ? Status.UNDO_HINT : "")
}

// The done line off the transferdone line itself, so a refused merge never mislabels the next copy.
function doneLine(t, r) {
    if (r.into && r.into.length > 0)
        return merged(r.merged || 0, r.keptBoth || 0, r.into, r.failed, r.skipped, r.cancelled, r.note)
    return Ops.transferDone(t, r.ok, r.failed, r.skipped, r.cancelled, r.durable, r.note)
}
