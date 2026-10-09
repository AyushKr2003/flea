import QtQuick
import "js/RecentMode.js" as RecentMode
import "js/Anchor.js" as Anchor
import "js/DirSizes.js" as DirSizes
import "js/Nav.js" as Nav
import "js/Reload.js" as Reload
import "js/Search.js" as Search
import "js/Swap.js" as Swap
import "js/Tabs.js" as Tabs
import "js/Thumbs.js" as Thumbs

// Where a listing's listed and rows replies land, holding the old rows until they do; see AGENTS.md "The listing swap".
Item {
    id: root

    property var pane: null
    // ui/PaneWire.qml, which owns the anchor, the retry and the rename a landing listing settles.
    property var wire: null
    property var phase: Swap.idle()
    readonly property bool holding: root.phase.holding
    readonly property bool fellBack: root.phase.fellBack

    // What tests/ui.sh noblank reads through ui/Ipc.qml swapState: how each hold ended and every empty frame.
    property int holds: 0
    property int fallbacks: 0
    property int blankFrames: 0
    // The gen whose rows last landed: a new gen parks the cursor on its best match, a re-answer keeps the file.
    property int landedGen: 0
    // The query the drawn rows answered, set in the turn they land; rows read it, never the live text.
    property string answeredQuery: ""
    property int loadingFrames: 0
    property var last: ({ ms: 0, end: "" })

    // ui/js/Nav.js asks for every listing here; false means nothing is held, and one after a live answer holds the walk's state unless clearAtOnce.
    function hold(ask) {
        root.phase = Swap.begin(root.phase, root.pane.listingState, root.pane.searchMode, ask, Date.now())
        if (!root.holding)
            return false
        root.holds += 1
        cap.restart()
        return true
    }

    // Held or fallen-back rows keep their listed line and drop an earlier request's; a live answer keeps the old rows until its own land.
    function takeListed(total, readMs, sortMs, path, changed, gen) {
        if (Swap.dropSessionLine(root.pane.searchMode, gen, root.pane.searchGen, root.pane.searchLeaving === true, root.pane.searchOpenedGen)) {
            return
        }
        var action = Swap.onListed(root.phase, root.pane.listInFlight, path, root.pane.listingPath)
        if (action === Swap.DROP) {
            return
        }
        if (Swap.keepLive(root.pane.searchMode, root.pane.listInFlight) || action === Swap.KEEP) {
            root.phase = Swap.kept(root.phase, { total: total, readMs: readMs, sortMs: sortMs, path: path, changed: changed })
            root.pane.listedSeen = true
            return
        }
        root.phase = Swap.heard(root.phase, root.pane.searchMode === Search.RESULTS)
        root.applyListed(total, readMs, sortMs, path, changed)
    }

    // A rows line lands with the listed line kept for it, or alone; one ahead of its listed line is dropped as it always was.
    function takeRows(start, items, kinds, listing, gen) {
        if (Swap.dropSessionLine(root.pane.searchMode, gen, root.pane.searchGen, root.pane.searchLeaving === true, root.pane.searchOpenedGen)) {
            return
        }
        var action = Swap.onRows(root.phase, root.pane.listInFlight, root.pane.listedSeen)
        if (action === Swap.DROP) {
            return
        }
        if (gen > 0 && gen === root.pane.searchGen && root.pane.searchFirstRowsAt === 0) {
            root.pane.searchFirstRowsAt = Date.now()
        }
        // A re-sort renumbers every row, so a selection made while it was in flight names other files under the new numbering.
        if (Swap.clearsSelection(root.pane.backend.heldListing, listing) && root.pane.selectionCount() > 0)
            root.pane.clearSelection()
        root.pane.backend.heldListing = listing
        // A live answer names its query, a listing none: rows and their marks change in this turn.
        root.answeredQuery = gen > 0 ? root.pane.searchQuery : ""
        if (action === Swap.LAND) {
            root.land(start, items, kinds, gen > 0 && gen !== root.landedGen && (root.pane.searchQuery || "").length > 0)
            root.landedGen = gen
            return
        }
        root.pane.held = start
        root.pane.rows = RecentMode.stampRows(root.pane, items)
        root.pane.kindNames = kinds
        root.rowsLanded()
    }

    // Reset, path and rows land in one turn (past the cap the reset already ran); a re-answer keeps the cursor's file, a new query takes row 0.
    function land(start, items, kinds, fresh) {
        var reply = root.phase.listed
        var keep = root.pane.searchMode.length > 0 && start === 0 && !fresh && root.pane.rowFor(root.pane.cursorIndex)
        // A live answer on the base the rows already stand on keeps the folder sizes and thumbnails it lists again; the first answer and an exit start clean.
        var again = root.pane.searchLeaving !== true && root.pane.searchBase === reply.path
            && (root.pane.searchMode === Search.TYPING || root.pane.searchMode === Search.RESULTS)
        var sizes = again ? DirSizes.carried(root.pane.dirSizeState, root.pane.rows, root.pane.held, items, start) : null
        var thumbs = again ? Thumbs.carried(root.pane.thumbState, root.pane.rows, root.pane.held, items, start) : null
        if (root.holding)
            root.release(Swap.landed(root.phase), "landed")
        else
            root.phase = Swap.landed(root.phase)
        // The rows go in before the count, so each delegate the count builds is built on its own row.
        root.pane.held = start
        root.pane.rows = RecentMode.stampRows(root.pane, items)
        root.pane.kindNames = kinds
        root.applyListed(reply.total, reply.readMs, reply.sortMs, reply.path, reply.changed)
        if (sizes)
            root.pane.dirSizeState = sizes
        if (thumbs)
            root.pane.thumbState = thumbs
        if (keep) {
            root.pane.setCursor(Search.keptIndex(keep.n, items, start))
        } else if (fresh) {
            root.pane.setCursor(start)
        }
        root.rowsLanded()
    }

    // A failed or refused listing, or a kept live answer, lets the held rows go at once; the failure draws what it always did.
    function drop() {
        if (root.holding)
            root.release(Swap.dropped(root.phase), "dropped")
        else
            root.phase = Swap.dropped(root.phase)
    }

    function release(next, end) {
        var query = root.phase.query
        root.last = { ms: Date.now() - root.phase.since, end: end }
        cap.stop()
        root.phase = next
        Nav.forget(root.pane, query)
    }

    function applyListed(total, readMs, sortMs, path, changed) {
        var pane = root.pane
        pane.thumbState = Thumbs.empty()
        pane.dirSizeState = DirSizes.empty()
        pane.reloadChanged = (changed === undefined || changed === null) ? -1 : changed
        if (!pane.dualMode && !pane.listInFlight && pane.searchMode.length === 0) {
            // With remember on each folder keeps its own order, so the fallback every other folder opens with stays untouched.
            if (ViewState.state.rememberSort === false)
                ViewState.changeLeaf("sort", { key: pane.backend.sortBy === "mtime" ? "date" : pane.backend.sortBy,
                                             reverse: pane.backend.sortDesc })
            pane.appliedListingPreferences = pane.listingPreferences
        }
        if (pane.listInFlight) {
            pane.listedSeen = true
        }
        pane.total = total
        // A live answer replaces rows in place with listed.path as the base in the same turn.
        if (pane.searchMode === Search.TYPING || pane.searchMode === Search.RESULTS) {
            pane.searchBase = path
            pane.listingState = Search.listingState(pane, total)
            pane.stateMessage = ""
            return
        }
        if (path.length > 0) pane.path = path  // the listing landed, so this is where the pane moves
        pane.listingState = total === 0 ? "empty" : "ready"
        pane.stateMessage = total === 0 ? "This directory is empty; add a file to see it here." : ""
        pane.opened(pane.path)
    }

    // Everything a rows reply does once its rows are in the pane, whether they came alone or with a swap.
    function rowsLanded() {
        // A landed live answer marks the phase a search, so an exit re-list forgets at once.
        if (root.pane.searchMode.length > 0) {
            root.phase = Swap.heard(root.phase, true)
        }
        var pane = root.pane
        if (pane.rowsAt === 0 && pane.inputAt > 0 && pane.rowFor(pane.cursorIndex))
            pane.rowsAt = Date.now()
        pane.applyPendingSelect()
        root.wire.anchor = Anchor.apply(pane, root.wire.anchor, Theme.fileRowHeight)
        if (pane.preferenceAnchor)
            pane.preferenceAnchor = Anchor.applyPreference(pane, pane.preferenceAnchor)
        // A manual reload's notice, said only when rows changed; every other listing owes none.
        Reload.landed(pane)
        Tabs.applyPending(pane)
        pane.listArea.restartSettle()
        if (pane.listInFlight) {
            pane.listInFlight = false
            pane.listedSeen = false
        }
        root.wire.locateRetry()
        root.wire.openRenameOnArrival()
    }

    function describe() {
        return { holding: root.holding, fellBack: root.fellBack, holds: root.holds, fallbacks: root.fallbacks,
                 blankFrames: root.blankFrames, loadingFrames: root.loadingFrames, last: root.last }
    }

    // A slow listing falls back to the loading state, which stands until its rows land with their listed line.
    Timer {
        id: cap
        interval: Swap.HOLD_MS
        repeat: false
        onTriggered: {
            if (!root.holding)
                return
            root.fallbacks += 1
            root.release(Swap.expired(root.phase), "expired")
        }
    }

    Connections {
        target: root.pane
        function onListInFlightChanged() {
            if (root.pane.listInFlight)
                return
            cap.stop()
            root.phase = Swap.ended(root.phase)
        }
    }

    // afterAnimating runs on this thread just before each frame is synchronised, so it sees what that frame draws.
    Connections {
        target: root.Window.window
        function onAfterAnimating() {
            // Search and "/" never put a list in flight, so their blank is no row drawn while the count still names rows.
            var live = Search.live(root.pane) || root.pane.filterQuery.length > 0
            var kind = Swap.frameKind(root.pane.listInFlight, root.pane.listingState, root.fellBack,
                root.pane.rows.length, root.pane.total, live)
            if (kind === "blank")
                root.blankFrames += 1
            else if (kind === "loading")
                root.loadingFrames += 1
        }
    }
}
