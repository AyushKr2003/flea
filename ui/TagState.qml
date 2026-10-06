import QtQuick
import "js/Menu.js" as Menu
import "js/Ops.js" as Ops
import "js/Search.js" as Search
import "js/Tags.js" as Tags

// One pane's file tags, built when a listing first carries one or a tag key or menu first asks,
// so a session that never tags builds nothing for tags.
Item {
    id: root
    required property var pane
    // The 88 px slot stands on every row of a folder once a tagged row has been seen in it.
    property bool latched: false
    // Every tag this session has seen set, which is what the rail's TAGS section lists.
    property var inUse: ({})
    // The change the last settags carried, cleared by its answer; the status line reads it.
    property var lastChange: null

    // A rows reply is the whole held window; a fresh listing starts the latch over.
    function take(items, fresh) {
        var seen = Tags.stamp(items, root.latched, root.inUse, fresh)
        root.latched = seen.latched
        if (seen.grew) root.inUse = Object.assign({}, root.inUse)
    }

    function filesFor(indices) {
        return indices.map(function (index) {
            var row = root.pane.rowFor(index)
            return row && row.tg ? row.tg : []
        })
    }

    // The flyout's rows for the selection: seven tags with digit hints, then Remove all tags.
    function flyout() {
        return Tags.tagEntries(Tags.statesFor(root.filesFor(Ops.targetIndices(root.pane))), Theme.tag.fallback)
    }

    // A flyout choice toggles that tag over the selection, or clears every tag off it.
    function choose(name) {
        var rows = Ops.targetIndices(root.pane)
        if (rows.length === 0) return
        var clear = name === Tags.CLEAR_ID
        var op = clear ? "clear" : Tags.opFor(Tags.stateFor(root.filesFor(rows), name))
        root.lastChange = { op: op, tag: clear ? "" : name }
        root.pane.backend.send({ c: "settags", rows: rows, op: op, tag: clear ? "" : name })
    }

    // T opens the Tags flyout straight from the listing, the same list the menu's Tags row opens.
    function openMenu() {
        var pane = root.pane
        if (pane.lockedTarget.length > 0) return
        if (!pane.canTag) {
            pane.message("This filesystem does not support file tags.", true)
            return
        }
        var menu = pane.contextMenu()
        if (!Menu.openAtCursor(pane, menu, Theme.spacing.rowPaddingX)) return
        for (var i = 0; i < menu.entries.length; i++) {
            if (menu.entries[i].action === "tags") {
                menu.openSubmenu(i)
                return
            }
        }
    }

    // A tag walks Home for that tag, an explicit walk like any search; esc returns to the listing.
    function openTag(name) {
        if (!name) return
        root.pane.searchHere = false
        root.pane.searchQuery = "tag:" + name
        Search.run(root.pane)
    }

    // The settags answer lands the pending change: ask the visible window again, then say it.
    function setTaggedDone(ok) {
        var change = root.lastChange
        root.lastChange = null
        if (!change) return
        root.pane.backend.window(root.pane.held, root.pane.windowSize)
        root.pane.message(change.op === "clear" ? Tags.clearedLine(ok) : Tags.statusLine(ok, change.tag), false)
    }
}
