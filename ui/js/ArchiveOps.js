.pragma library

.import "Archive.js" as Archive
.import "Ops.js" as Ops

// The With-password compress and the encrypted extract's retry. The selection is resolved first,
// exactly like a plain compress, and the dialogs carry resolved paths rather than row indices:
// a row index names another file once the listing moves. The password rides stdin, and the
// backend refuses a destination that appeared meanwhile anyway. The pending carries its own
// deliver, the way a drag does, so pathsResolved needs no branch for it.
function openCompressPw(pane, menuId, cards) {
    var idx = Ops.targetIndices(pane)
    if (idx.length === 0) return Ops.sayNoTarget(pane)
    pane.pathsPending = { kind: "compressPw",
        deliver: function (list) { compressPwResolved(cards, pane, list, menuId) } }
    pane.backend.askPaths(idx)
}

// The answer to the askPaths above: the cards host opens over these paths, and the submit below
// sends them.
function compressPwResolved(cards, pane, paths, menuId) {
    if (paths.length === 0) {
        return
    }
    cards.compressPwSource = { paths: paths, menuId: menuId || 0 }
    cards.openCompressDialog(cards.compressPwSource, Ops.leaf(pane.path), pane)
}

// The dialog's Compress: the name is free, the password rides stdin, and the backend refuses a
// destination that appeared meanwhile anyway.
function submitCompressPw(pane, source, format, name, password, encryptNames) {
    if (!source || !source.paths || source.paths.length === 0) {
        return
    }
    var dest = pane.join(pane.path, name)
    pane.backend.compressPw(source.paths, dest, format, password, encryptNames, source.menuId)
    pane.sticky(compressSticky(source.paths.length, format))
}

// The sticky line from one template, filled once, never joined from fragments.
function compressSticky(count, format) {
    return "Compressing %1 to .%2".replace("%1", Ops.items(count)).replace("%2", format)
}

// The extract card's Extract: the same destination the first attempt named, retried with a password.
function submitExtractPw(pane, password) {
    var source = pane.extractPwSource
    if (!source || !source.path) {
        return
    }
    pane.backend.extractPw(source.path, source.dest, password, 0)
}
