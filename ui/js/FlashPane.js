.pragma library

.import "Flash.js" as Flash
.import "FlashCard.js" as FlashCard
.import "Ops.js" as Ops

// The flash pane's decisions, checked headless by tests/js/flashpane.js; the QML only applies them.

// A drive is the disk the backend re-checks at flash time, so the pane holds its choice by identity, never by a row index.
function same(a, b) {
    return !!a && !!b && a.dev === b.dev && a.seq === b.seq && a.serial === b.serial
}

function indexOf(drives, drive) {
    for (var i = 0; i < (drives || []).length; i++) {
        if (same(drives[i], drive))
            return i
    }
    return -1
}

// What a cursor position names: the image, a drive by identity, or the Flash step.
function target(cursor, drives) {
    if (cursor <= 0)
        return { kind: "image", drive: null }
    if (cursor > drives.length)
        return { kind: "flash", drive: null }
    return { kind: "drive", drive: drives[cursor - 1] }
}

// One drive-list answer folded in: the choice kept by identity, the cursor kept on what it named.
function reconcile(state, rows) {
    var list = rows || []
    var chosen = null
    if (state.pendingDisk) {
        var disk = Flash.railDisk(state.pendingDisk)
        for (var i = 0; i < list.length && chosen === null; i++) {
            if (list[i].dev === disk && Flash.fits(list[i]))
                chosen = list[i]
        }
    } else {
        var at = indexOf(list, state.chosen)
        chosen = at >= 0 && Flash.fits(list[at]) ? list[at] : null
        if (chosen === null && Flash.preselect(list) >= 0)
            chosen = list[Flash.preselect(list)]
    }
    var selected = indexOf(list, chosen)
    if (state.first || state.pendingDisk)
        return { chosen: chosen, selected: selected, cursor: selected + 1, moved: true }
    var was = target(state.cursor, state.drives || [])
    var cursor = was.kind === "image" ? 0 : was.kind === "flash" ? Flash.flashPos(list.length) : -1
    if (was.kind === "drive") {
        var held = indexOf(list, was.drive)
        cursor = held >= 0 && Flash.fits(list[held]) ? held + 1 : selected + 1
    }
    var now = target(cursor, list)
    return { chosen: chosen, selected: selected, cursor: cursor,
             moved: now.kind !== was.kind || (now.kind === "drive" && !same(now.drive, was.drive)) }
}

// The host marks the pane it covers; moving to another pane or leaving by Back clears the mark it leaves.
function cover(host, pane) {
    if (host.coverPane && host.coverPane !== pane)
        host.coverPane.flashActive = false
    host.coverPane = pane
    pane.flashActive = true
}

function uncover(host) {
    if (host.coverPane)
        host.coverPane.flashActive = false
}

// Reopening onto a running flash takes back the card Back handed the pane; a copy's card stays.
function reclaim(pane) {
    if (!pane.transfer || pane.transfer.flash !== true)
        return
    pane.transfer = Ops.emptyTransfer()
    pane.sticky("")
}

// Which press a flashdone answers: the running flash, a refusal of the press just sent before any flashstarted, or neither.
function doneFor(runner, message) {
    var id = message.id || 0
    if (runner.running)
        return id === runner.transferId ? "finished" : "ignore"
    return runner.pressSent && id === runner.pendingId ? "refused" : "ignore"
}

// The ending's figures: a verify miss names the backend's offset, every other ending the bytes the drive took, against the card's total.
function endingContext(transfer, message) {
    var at = String(message.err || "") === "verify" ? (message.at || 0) : (transfer.bytes || 0)
    return { at: at, total: FlashCard.total(transfer) || transfer.total || 0 }
}
