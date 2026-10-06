.pragma library
.import "Input.js" as Input
.import "DirSizes.js" as DirSizes
.import "Format.js" as Format
.import "Thumbs.js" as Thumbs

// Live subtree search: the strip opens a session, each keystroke sends its query, rows replace folder rows with no Enter.
var OFF = ""
var TYPING = "typing"
var RESULTS = "results"

// f opens the session: the scope's walk starts at once and no rows change.
function start(root) {
    if ((root.searchMode || "").length > 0) {
        return
    }
    root.searchFrom = root.path
    root.searchCursor = root.cursorIndex
    root.searchGen = 0
    root.searchQuery = ""
    root.searchMode = TYPING
    root.searchRunning = true
    root.searchCancelled = false
    root.searchScanned = 0
    var scope = scopeRoot(root.path, root.home || "", root.searchHere)
    root.backend.searchOpen(scope, root.path, root.showHidden)
}

// Universal search: home when the pane stands inside it, else the pane's directory (backend has no home notion). Issue 30: here=true stays; abort()/reveal() leave it; nothing persists.
function scopeRoot(path, home, here) {
    if (here === true) {
        return path
    }
    if (home.length === 0) {
        return path
    }
    if (path === home || String(path).indexOf(home + "/") === 0) {
        return home
    }
    return path
}

// Keystrokes send rising gens with old rows held; cursor parks on best match, selection goes.
function sendQuery(root) {
    root.searchGen += 1
    root.clearSelection()
    root.thumbState = Thumbs.empty()
    root.dirSizeState = DirSizes.empty()
    root.setCursor(0)
    root.backend.searchQuery(root.searchQuery, root.searchGen, root.windowSize)
}

function extend(root, character) {
    root.searchQuery += character
    sendQuery(root)
}

// Backspace to empty sends "" and the folder rows come back, with the strip still open.
function shrink(root) {
    if (root.searchQuery.length === 0) {
        return
    }
    root.searchQuery = root.searchQuery.substring(0, root.searchQuery.length - 1)
    sendQuery(root)
}

// Enter keeps the results and moves the keys to them, with no new request.
function commit(root) {
    if ((root.searchQuery || "").length === 0) {
        abort(root)
        return
    }
    root.searchMode = RESULTS
}

// Tab flips the scope, opens the new scope at once and re-sends the standing query.
function rescope(root) {
    root.searchHere = !root.searchHere
    var scope = scopeRoot(root.path, root.home || "", root.searchHere)
    root.backend.searchOpen(scope, root.path, root.showHidden)
    sendQuery(root)
}

// Esc closes the session and re-lists the folder it came from on its cursor; unsent lists nothing, empty already drew folder rows.
function abort(root) {
    var back = (root.searchFrom || "").length > 0 ? root.searchFrom : root.path
    var cursor = root.searchCursor
    var query = root.searchQuery
    var sent = root.searchGen > 0
    closeSession(root)
    root.searchCursor = -1
    if (!sent) {
        return
    }
    if (query.length === 0) {
        if (cursor >= 0) {
            root.setCursor(cursor)
        }
        return
    }
    root.openWithoutHistory(back)
    root.searchCursor = cursor
}

// Esc from a live session re-lists the folder, and its landing puts the cursor where it stood.
function restoreCursor(root) {
    if (root.searchCursor >= 0 && (root.searchMode || "").length === 0) {
        root.setCursor(root.searchCursor)
        root.searchCursor = -1
        return true
    }
    return false
}

// A navigation drops the session without re-listing, so the next listing lands on clean state.
function leaveWalk(root) {
    if (!closeSession(root)) {
        return false
    }
    root.searchCursor = -1
    return true
}

// Closing the session is one searchclose; a list closes it too, so a doubled close is silence.
function closeSession(root) {
    if ((root.searchMode || "").length === 0) {
        return false
    }
    if (root.backend) {
        root.backend.searchClose()
    }
    root.searchMode = OFF
    root.searchQuery = ""
    root.searchRunning = false
    root.searchCancelled = false
    root.searchScanned = 0
    root.searchFrom = ""
    return true
}

// A terminal or batch line answers only the newest sent gen; older gens drop, gen-less lines are today's.
function accepts(root, gen) {
    return (root.searchMode || "").length > 0 && (!(gen > 0) || gen === root.searchGen)
}

// The answered counts land; the first window rides its own rows line, so nothing is asked for.
function searched(root, total, scanned, ms, cancelled, gen, walking) {
    if (!accepts(root, gen)) {
        return
    }
    root.searchRunning = walking === true
    root.searchCancelled = cancelled
    root.total = total
    root.searchScanned = scanned
    root.searchMs = ms
    root.listingState = listingState(root, total)
    root.listArea.restartSettle()
}

// A batch moves the same counts while the walk grows; the rows arrive on their own lines.
function searching(root, total, scanned, ms, gen) {
    if (!accepts(root, gen)) {
        return
    }
    root.total = total
    root.searchScanned = scanned
    root.searchMs = ms
    root.listingState = listingState(root, total)
    root.listArea.restartSettle()
}

// Query-line keys: enter keeps, escape leaves, tab rescopes, printables extend; cursor motions run through Focus.
function typeKey(event, root) {
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        commit(root)
        return true
    }
    if (event.key === Qt.Key_Escape) {
        abort(root)
        return true
    }
    if (event.key === Qt.Key_Backspace) {
        shrink(root)
        return true
    }
    // Issue 30's control: tab flips the scope between the whole home directory and the one the pane
    // is standing in. It is the only writer, and nothing resets it, so the flip holds for the window;
    // ui/SearchStrip.qml draws "in <scope>" under the caret, so every search says which one it took.
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
        rescope(root)
        return true
    }
    if (Input.isPrintable(event.text)) {
        extend(root, event.text)
        return true
    }
    return true
}

// o on a result opens the directory that holds it and puts the cursor on the row, the design's reveal.
function reveal(root) {
    var row = root.rowFor(root.cursorIndex)
    if (!row) {
        return
    }
    var full = root.join(root.path, row.n)
    var cut = full.lastIndexOf("/")
    if (cut <= 0) {
        return
    }
    root.recentMode = ""
    root.recentFrom = ""
    root.recentPaths = []
    // Through the pane: importing RecentMode.js here would close a Nav import cycle.
    root.restoreRecentSort()
    root.pendingSelect = full
    root.open(full.substring(0, cut))
}

// What activating a row means right now. On a search result the operator's ruling is that it takes
// you to the file instead of opening it; the canvas keeps enter on open and o on reveal, so it is
// only the pointer that asks this. ui/js/Tap.js is the one caller.
function activateAction(root) {
    return root.searchMode === RESULTS ? "reveal" : "open"
}

// A walk with no matches yet is still working, so the list area keeps the crawl rather than
// flashing the empty state at every directory that happens to hold nothing.
function listingState(root, total) {
    if (total > 0) {
        return "ready"
    }
    return root.searchRunning ? "loading" : "empty"
}

// Strip right edge as whole Update.js-idiom templates: count walking, count with time landed.
var NOTE = { walking: "%1 found", landed: "%1 found in %2 s" }
function note(total, running, ms, empty) {
    if (empty === true) {
        return ""
    }
    if (running) {
        return NOTE.walking.replace("%1", Format.count(total))
    }
    return NOTE.landed.replace("%1", Format.count(total)).replace("%2", (ms / 1000).toFixed(1))
}

// The strip's own right edge: one press leaves, walking or landed.
var WAY_OUT = "esc returns"

// The rule itself lives in Format.tilde, because the window chrome draws a path through the same one.
function scope(path, home) {
    return Format.tilde(path, home)
}

// The status bar's own left half while a search is up, the two lines the canvas draws.
function statusLine(running, total, scanned, ms) {
    var found = Format.count(total) + " found"
    if (running) {
        return found + " · Searching, " + Format.count(scanned) + " scanned"
    }
    return found + " in " + (ms / 1000).toFixed(1) + " s"
}
