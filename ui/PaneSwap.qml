import QtQuick
import "js/RecentMode.js" as RecentMode
import "js/Anchor.js" as Anchor
import "js/BackReturn.js" as BackReturn
import "js/DirSizes.js" as DirSizes
import "js/Nav.js" as Nav
import "js/Reload.js" as Reload
import "js/Search.js" as Search
import "js/Startup.js" as Startup
import "js/Swap.js" as Swap
import "js/Tabs.js" as Tabs
import "js/Thumbs.js" as Thumbs

// Where a listing's listed and rows replies land, holding the old rows until they do; see AGENTS.md "The listing swap".
Item {
    id: root

    property var pane: null
    // ui/PaneWire.qml, which owns the anchor, the retry and the rename a landing listing settles.
    property var wire: null
    // The cursor a Back or Forward owes the asked listing, or null; hold() arms each listing's own.
    property var restore: null
    // The first window a landing set aside while its locate is out, or null.
    property var parked: null
    // A locate that never answers is a listing that never answers, so past Startup's listing wait the parked rows land at the top.
    property int parkedWaitMs: Startup.LISTING_WAIT_MS
    // Built on the first park, so a window that never parks a Back starts no object for it.
    property var parkedWait: null
    onParkedChanged: {
        if (!root.parked) {
            if (root.parkedWait !== null) root.parkedWait.stop()
            return
        }
        if (root.parkedWait === null) {
            root.parkedWait = Qt.createQmlObject("import QtQuick; Timer { repeat: false }", root, "PaneSwap.parkedWait")
            root.parkedWait.triggered.connect(root.landParked)
        }
        root.parkedWait.interval = root.parkedWaitMs
        root.parkedWait.restart()
    }
    property var phase: Swap.idle()
    readonly property bool holding: root.phase.holding
    readonly property bool fellBack: root.phase.fellBack

    // What tests/ui.sh noblank reads through ui/Ipc.qml swapState: how each hold ended and every empty frame.
    property int holds: 0
    property int fallbacks: 0
    property int blankFrames: 0
    property int loadingFrames: 0
    property var last: ({ ms: 0, end: "" })

    // ui/js/Nav.js asks for every listing through here; false means nothing is held and it forgets now.
    // A search's matches are never held.
    function hold(ask) {
        root.restore = ask.restore ? Object.assign({}, ask.restore) : null
        root.parked = null
        root.phase = Swap.begin(root.phase, root.pane.listingState, root.pane.searchMode, ask, Date.now())
        if (!root.holding)
            return false
        root.holds += 1
        cap.restart()
        return true
    }

    // The listed line held or fallen-back rows wait for is kept for them, an earlier request's is dropped, any other applied.
    function takeListed(total, readMs, sortMs, path, changed) {
        var action = Swap.onListed(root.phase, root.pane.listInFlight, path, root.pane.listingPath)
        if (action === Swap.KEEP) {
            root.phase = Swap.kept(root.phase, { total: total, readMs: readMs, sortMs: sortMs, path: path, changed: changed })
            root.pane.listedSeen = true
        } else if (action === Swap.APPLY) {
            root.phase = Swap.heard(root.phase, root.pane.searchMode === Search.RESULTS)
            root.applyListed(total, readMs, sortMs, path, changed)
        }
    }

    // A rows line lands with the listed line kept for it, or alone; one ahead of its listed line is dropped as it always was.
    function takeRows(start, items, kinds, listing) {
        var action = Swap.onRows(root.phase, root.pane.listInFlight, root.pane.listedSeen)
        if (action === Swap.DROP)
            return
        // A re-sort renumbers every row, so a selection made while it was in flight names other files under the new numbering.
        if (Swap.clearsSelection(root.pane.backend.heldListing, listing) && root.pane.selectionCount() > 0)
            root.pane.clearSelection()
        root.pane.backend.heldListing = listing
        if (action === Swap.LAND) {
            // The owed name sits outside this window, so these rows wait for the window its locate names.
            if (BackReturn.deferForLocate(root.pane, root.restore, items, root.phase.listed)) {
                root.parked = { start: start, items: items, kinds: kinds }
                return
            }
            root.parked = null
            root.land(start, items, kinds)
            return
        }
        root.pane.held = start
        root.pane.rows = RecentMode.stampRows(root.pane, items)
        root.pane.kindNames = kinds
        root.rowsLanded()
    }

    // The reset, the path and the rows land in one turn, so no frame falls between two listings; past the cap the reset already ran.
    function land(start, items, kinds) {
        var reply = root.phase.listed
        if (root.holding)
            root.release(Swap.landed(root.phase), "landed")
        else
            root.phase = Swap.landed(root.phase)
        // The rows go in before the count, so each delegate the count builds is built on its own row.
        root.pane.held = start
        root.pane.rows = RecentMode.stampRows(root.pane, items)
        root.pane.kindNames = kinds
        root.applyListed(reply.total, reply.readMs, reply.sortMs, reply.path, reply.changed)
        root.rowsLanded()
    }

    // A refused located window, any other failure or the wait running out lands the rows set aside, at the top, so the listing still ends.
    function landParked() {
        var parked = root.parked
        if (!parked || root.phase.listed === null)
            return false
        root.parked = null
        root.restore = null
        root.land(parked.start, parked.items, parked.kinds)
        return true
    }

    // A failed or refused listing lets the held rows go at once, and the failure draws what it always did.
    function drop() {
        if (root.holding)
            root.release(Swap.dropped(root.phase), "dropped")
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
            ViewState.changeLeaf("sort", { key: pane.backend.sortBy === "mtime" ? "date" : pane.backend.sortBy,
                                         reverse: pane.backend.sortDesc })
            pane.appliedListingPreferences = pane.listingPreferences
        }
        if (pane.listInFlight) {
            pane.listedSeen = true
        }
        pane.total = total
        // A search's opening listed line is the walk starting, not a directory that came back empty.
        if (pane.searchMode === Search.RESULTS) {
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
        // The Back or Forward cursor lands with the rows, in this same turn, or not at all.
        BackReturn.landRestore(pane, root.restore)
        root.restore = null
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
            root.restore = null
            root.parked = null
            root.phase = Swap.ended(root.phase)
        }
    }

    // afterAnimating runs on this thread just before each frame is synchronised, so it sees what that frame draws.
    Connections {
        target: root.Window.window
        function onAfterAnimating() {
            var kind = Swap.frameKind(root.pane.listInFlight, root.pane.listingState, root.fellBack)
            if (kind === "blank")
                root.blankFrames += 1
            else if (kind === "loading")
                root.loadingFrames += 1
        }
    }
}
