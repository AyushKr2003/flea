.pragma library

.import "Ops.js" as Ops
.import "Search.js" as Search

// The With-password compress and the encrypted extract's retry, over resolved paths: a row index names another file once the listing moves.
function openCompressPw(pane, menuId, cards) {
    var idx = Ops.targetIndices(pane)
    if (idx.length === 0) return Ops.sayNoTarget(pane)
    pane.pathsPending = { kind: "compressPw",
        deliver: function (list) { compressPwResolved(cards, pane, list, menuId) } }
    pane.backend.askPaths(idx)
}

// The answer to askPaths: the paths and menu id the cards host opens over.
function compressPwResolved(cards, pane, paths, menuId) {
    if (paths.length === 0) return Ops.sayNoTarget(pane)
    cards.openCompressDialog({ paths: paths, menuId: menuId || 0 }, Ops.leaf(pane.path), pane)
}

// The dialog's Compress: the name is free, and the backend refuses a destination that appeared meanwhile.
function submitCompressPw(pane, source, format, name, password, encryptNames) {
    if (!source || !source.paths || source.paths.length === 0) {
        return
    }
    var dest = pane.join(Search.baseOf(pane), name)
    pane.backend.compressPw(source.paths, dest, format, password, encryptNames, source.menuId)
    // A refused send parks nothing, so only a sent compress shows its running line.
    if (!pane.backend.queueing) pane.sticky(compressSticky(source.paths.length, format))
}

// The sticky line from one template, filled once, never joined from fragments.
function compressSticky(count, format) {
    return "Compressing %1 to .%2".replace("%1", Ops.items(count)).replace("%2", format)
}

// The extract card's Extract: the archive and destination the card was opened over, retried with a password.
function submitExtractPw(pane, source, password) {
    if (!source || !source.path) {
        return
    }
    pane.backend.extractPw(source.path, source.dest, password, 0)
}
