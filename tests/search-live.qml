import QtQuick
import "../ui/js/Search.js" as Search
import "../ui/js/Swap.js" as Swap
import "../ui/js/Focus.js" as Focus
import "../ui/js/Filter.js" as Filter
import "../ui/js/Messages.js" as Messages
import "../ui/js/Nav.js" as Nav
import "../ui/js/RecentMode.js" as RecentMode
import "../ui/js/Anchor.js" as Anchor
import "../ui/js/DirSizes.js" as DirSizes
import "../ui/js/Thumbs.js" as Thumbs
import "../ui/js/Reload.js" as Reload
import "../ui/js/Tabs.js" as Tabs
import "js/filterfixture.js" as Fixture
import "js/sourcefixture.js" as Ship

// Replays the real session tests/search-live.sh drove against target/debug/flea, given as the last
// qml6 argument: the scope is the fixture root while the pane stands on its subfolder, so every
// joined path proves the listing base. Each keystroke goes through Focus.handleKey with no Enter,
// its sends must equal the transcript's S lines, and the transcript's R lines land through
// Messages.route into the shipped ui/PaneSwap.qml takeListed/takeRows, built from that file's own
// text below, so a mutation there reddens here. Drawn rows emptied beside a count that
// still names them is the blank frame R0 forbids; an honest no-match window carries its own zero.
Item {
    id: root
    property int checks: 0
    property int failures: 0
    property int blanks: 0
    // What the shipped per-frame counter would have counted on each landed turn.
    property int frameBlanks: 0
    property bool hadRows: false
    property var sent: []
    property string relisted: ""
    property string opened: ""
    property string scope: ""
    property string folder: ""
    property var joinedBases: []
    property var said: []
    property var pane: null
    property var swap: null
    property string shipSrc: ""
    property var sidebar: ({ renameEditor: function () { return null } })
    // The singletons the shipped landing reads, stubbed: the row height its anchor math needs,
    // and the sort-leaf writer only a directory landing reaches.
    property var themeStub: ({ fileRowHeight: 37 })
    property var viewStub: ({ changeLeaf: function () {} })
    property var capStub: ({ stop: function () {}, restart: function () {} })

    function check(label, actual, expected) {
        root.checks++
        if (JSON.stringify(actual) === JSON.stringify(expected)) {
            console.log("ok   " + label)
            return
        }
        root.failures++
        console.log("FAIL " + label + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected))
    }
    function eq(a, b) {
        if (typeof a !== typeof b)
            return false
        if (a === null || b === null || typeof a !== "object")
            return a === b
        if (Array.isArray(a) !== Array.isArray(b) || Object.keys(a).length !== Object.keys(b).length)
            return false
        for (var k in a)
            if (!eq(a[k], b[k]))
                return false
        return true
    }
    function key(code, text) { return { key: code, text: text, modifiers: Qt.NoModifier } }
    function type(text) {
        for (var i = 0; i < text.length; i++)
            Focus.handleKey(key(Qt.Key_A + text.charCodeAt(i) - 97, text.charAt(i)), root.pane, root.sidebar)
    }
    function press(code) { Focus.handleKey(key(code, ""), root.pane, root.sidebar) }
    function names() { return root.pane.rows.map(function (r) { return r.n }) }
    function sample() {
        if (root.pane === null)
            return
        if (root.hadRows && root.pane.rows.length === 0 && root.pane.total > 0 && root.pane.searchMode.length > 0)
            root.blanks++
        // The shipped counter's own decision on this turn: no list is ever in flight here.
        var live = Search.live(root.pane)
        if (Swap.frameKind(false, root.pane.listingState, false, root.pane.rows.length, root.pane.total, live) === "blank")
            root.frameBlanks++
        if (root.pane.rows.length > 0)
            root.hadRows = true
    }
    property var msgRoot: ({
        listed: function (total, read, sort, path, changed, gen) { root.swap.takeListed(total, read, sort, path, changed, gen) },
        rows: function (start, items, ms, kinds, listing, gen) { root.swap.takeRows(start, items, kinds, listing, gen) },
        searched: function (total, scanned, ms, cancelled, gen, walking) {
            Search.searched(root.pane, total, scanned, ms, cancelled, gen, walking)
        }
    })
    // One shipped PaneSwap function by its own text: the replay holds no landing of its own.
    function shipFn(swap, name, args) {
        var body = Ship.block(root.shipSrc, "function " + name + "(", "ui/PaneSwap.qml")
        var pre = ["root", "cap", "Swap", "Search", "RecentMode", "Anchor", "DirSizes", "Thumbs", "Reload", "Tabs", "Nav", "Theme", "ViewState"]
        var f = new Function(pre.concat(args).join(","), body)
        var deps = [swap, root.capStub, Swap, Search, RecentMode, Anchor, DirSizes, Thumbs, Reload, Tabs, Nav, root.themeStub, root.viewStub]
        return function () { return f.apply(null, deps.concat(Array.prototype.slice.call(arguments))) }
    }
    // The real swap over the stub pane and backend: every landing below runs shipped code.
    function makeSwap(p) {
        var wire = { anchor: null, locateRetry: function () {}, openRenameOnArrival: function () {} }
        var swap = { pane: p, wire: wire, phase: Swap.idle(), landedGen: 0, holding: false, last: { ms: 0, end: "" } }
        swap.takeListed = root.shipFn(swap, "takeListed", ["total", "readMs", "sortMs", "path", "changed", "gen"])
        swap.takeRows = root.shipFn(swap, "takeRows", ["start", "items", "kinds", "listing", "gen"])
        swap.land = root.shipFn(swap, "land", ["start", "items", "kinds", "fresh"])
        swap.applyListed = root.shipFn(swap, "applyListed", ["total", "readMs", "sortMs", "path", "changed"])
        swap.rowsLanded = root.shipFn(swap, "rowsLanded", [])
        swap.release = root.shipFn(swap, "release", ["next", "end"])
        swap.drop = root.shipFn(swap, "drop", [])
        return swap
    }
    function setup(rows, folder, home) {
        root.shipSrc = Ship.source("ui/PaneSwap.qml")
        var p = Fixture.pane()
        p.path = folder
        p.home = home
        p.searchMode = ""
        p.searchQuery = ""
        p.searchFrom = ""
        p.searchHere = false
        p.searchRunning = false
        p.searchCancelled = false
        p.searchScanned = 0
        p.searchMs = 0
        p.searchGen = 0
        p.searchKeyAt = 0
        p.searchFirstRowsAt = 0
        p.searchSettledAt = 0
        p.showHidden = false
        p.windowSize = 200
        p.visibleRows = 4
        p.focusView = "list"
        p.viewMode = "list"
        p.recentMode = ""
        p.searchBase = ""
        p.pendingSelect = ""
        p.listInFlight = false
        p.listingPath = ""
        p.listedSeen = false
        p.held = 0
        p.kindNames = []
        p.dualMode = false
        p.listingState = "ready"
        p.stateMessage = ""
        p.reloadFrom = -1
        p.reloadChanged = -1
        p.appliedListingPreferences = []
        p.listingPreferences = []
        p.rows = rows.slice()
        p.total = rows.length
        p.cursorIndex = 2
        p.refresh()
        p.setCursor = function (index) { Filter.setCursor(p, index) }
        p.renameEditor = function () { return null }
        p.restoreRecentSort = function () {}
        p.clearSelection = function () { p.selection.clear() }
        p.selectionCount = function () { return p.selection.count() }
        p.applyPendingSelect = function () { Nav.applyPendingSelect(p) }
        p.opened = function (target) { root.opened = target }
        p.message = function (text, isError) { root.said.push(text) }
        p.join = function (base, name) { root.joinedBases.push(base); return base + "/" + name }
        p.listArea = { restartSettle: function () {}, restartCoalesce: function () {}, primeSettle: function () {} }
        p.act = function (action) { Focus.act(action, p) }
        p.escapePressed = function () { p.escaped = true }
        p.open = function (target) { root.opened = target; Search.leaveWalk(p) }
        p.openWithoutHistory = function (next) { root.relisted = next }
        p.backend = {
            heldListing: 0,
            sortBy: "name",
            sortDesc: false,
            searchOpen: function (scope, folder, hidden) {
                root.sent.push({ c: "searchopen", path: scope, folder: folder, hidden: hidden })
            },
            searchQuery: function (query, gen, count) {
                root.sent.push({ c: "searchquery", query: query, gen: gen, count: count })
            },
            searchClose: function () { root.sent.push({ c: "searchclose" }) }
        }
        root.pane = p
        root.swap = root.makeSwap(p)
        p.swap = root.swap
    }
    function stroke(k) {
        if (k === "BS")
            press(Qt.Key_Backspace)
        else if (k === "Down")
            press(Qt.Key_Down)
        else if (k === "Up")
            press(Qt.Key_Up)
        else if (k === "Return")
            press(Qt.Key_Return)
        else if (k === "Tab")
            press(Qt.Key_Tab)
        else if (k === "Escape")
            press(Qt.Key_Escape)
        else if (k === "Reveal")
            Focus.act("reveal", root.pane)
        else
            type(k)
    }
    // One transcript key block: the keystroke, its sends against the S lines, then its R lines.
    // A transcript list line is the escape relist the stub records instead of sending.
    function runBlock(block) {
        var before = root.sent.length
        stroke(block.key)
        sample()
        var made = root.sent.slice(before)
        var want = []
        for (var i = 0; i < block.sends.length; i++) {
            if (block.sends[i].c === "list") {
                root.check("escape re-lists " + block.sends[i].path, root.relisted, block.sends[i].path)
                continue
            }
            want.push(block.sends[i])
        }
        root.check("the " + block.key + " keystroke sends what the wire sent",
            made.every(function (m, j) { return eq(m, want[j]) }) && made.length === want.length, true)
        for (var r = 0; r < block.receives.length; r++) {
            Messages.route(msgRoot, JSON.parse(block.receives[r]))
            sample()
        }
        root.pane.refresh()
        checkKey(block.key, block.count)
    }
    function checkKey(k, n) {
        if (n === 0)
            root.check("f opens the session on the scope above the folder", root.pane.searchMode, "typing")
        if (n === 1 || n === 10 || n === 17) {
            root.check("ranked result rows land with no Enter", names(),
                ["notes.md", "north.txt", "docs/notes-old.md", "sub/photo.png"])
            var stamps = Search.stamps(root.pane)
            root.check("the stopwatch names the newest gen in order",
                stamps.gen === root.pane.searchGen && stamps.keyAt > 0
                && stamps.keyAt <= stamps.firstRowsAt && stamps.firstRowsAt <= stamps.settledAt, true)
        }
        if (n === 2)
            root.check("the next keystroke replaces the window whole", names(),
                ["notes.md", "north.txt", "docs/notes-old.md"])
        if (n === 3)
            root.check("down moves the result cursor without leaving the query",
                root.pane.cursorIndex + "|" + root.pane.searchMode, "1|typing")
        if (n === 4)
            root.check("and up moves it back", root.pane.cursorIndex, 0)
        if (n === 5)
            root.check("down again stands on the second match", root.pane.cursorIndex, 1)
        if (n === 6)
            root.check("a new query parks the cursor on its best match", root.pane.cursorIndex, 0)
        if (n === 6)
            root.check("backspace narrows through the index", names()[0] + "|" + root.pane.searchQuery, "notes.md|n")
        if (n === 7 || n === 9)
            root.check("backspace to empty brings the folder rows back, strip open",
                names().length + "|" + root.pane.searchMode, "4|typing")
        if (n === 8)
            root.check("a query with no match lands an honest empty window",
                names().length + "|" + root.pane.total, "0|0")
        if (n === 11)
            root.check("tab re-opens the folder scope and its row lands", names(), ["photo.png"])
        if (n === 12)
            root.check("tab back re-opens the scope and scoped rows land", names(),
                ["notes.md", "north.txt", "docs/notes-old.md", "sub/photo.png"])
        if (n === 13)
            root.check("enter keeps the results and moves the keys to them", root.pane.searchMode, "results")
        if (n === 14)
            root.check("keys now walk the results", root.pane.cursorIndex, 1)
        if (n === 15) {
            Nav.applyPendingSelect(root.pane)
            root.check("escape returns to the folder and cursor", root.pane.cursorIndex + "|" + names().length, "2|4")
            root.check("with the file still marked", root.pane.selectedIndices().join(","), "2")
        }
        if (n === 16)
            root.check("f opens the session on the scope above the folder", root.pane.searchMode, "typing")
        if (n === 18)
            root.check("enter keeps the scoped results", root.pane.searchMode, "results")
        if (n === 19) {
            var row = root.pane.rowFor(root.pane.cursorIndex)
            root.check("reveal joins the cursor row against the scope, not the folder",
                root.joinedBases[root.joinedBases.length - 1], root.scope)
            root.check("and opens the folder holding it", root.opened, root.scope)
            root.check("naming the revealed file", root.pane.pendingSelect, root.scope + "/notes.md")
        }
        if (n === 20)
            root.check("escape with no session leaves rows alone", names().length + "|" + root.pane.escaped, "4|true")
    }
    function load(path) {
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return
            parse(xhr.responseText)
        }
        xhr.open("GET", "file://" + path)
        xhr.send()
    }
    function parse(text) {
        var block = null
        var blocks = []
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i]
            if (line.indexOf("# key ") === 0) {
                block = { key: line.substring(6), count: blocks.length, sends: [], receives: [] }
                blocks.push(block)
            } else if (line.indexOf("S ") === 0)
                block.sends.push(JSON.parse(line.substring(2)))
            else if (line.indexOf("R ") === 0)
                block.receives.push(line.substring(2))
        }
        // The folder rows seed the pane; the scope is what the first session opens.
        var folder = blocks[0].sends[0].folder
        root.scope = blocks[0].sends[0].path
        root.folder = folder
        var folderRows = []
        for (var e = 0; e < blocks.length && folderRows.length === 0; e++) {
            for (var s = 0; s < blocks[e].sends.length; s++) {
                if (blocks[e].sends[s].c === "searchquery" && blocks[e].sends[s].query === "") {
                    for (var r = 0; r < blocks[e].receives.length; r++) {
                        var m = JSON.parse(blocks[e].receives[r])
                        if (m.t === "rows")
                            folderRows = m.rows
                    }
                }
            }
        }
        setup(folderRows, folder, root.scope)
        for (var k = 0; k < blocks.length; k++)
            runBlock(blocks[k])
        // A new session's first answer parks on its best match even when its generation equals the
        // stale landedGen: land gen 2, close the session with no directory landing in between, open
        // a new one and type two characters at once, so the burst collapses and gen 2 is the first
        // answer to land. Standing on the second match, the cursor must be back on row 0.
        var tailRows = [{ n: "notes.md" }, { n: "north.txt" }, { n: "docs/notes-old.md" }]
        Search.start(root.pane)
        type("n")
        feedAnswer(1, tailRows)
        type("o")
        feedAnswer(2, tailRows)
        Search.closeSession(root.pane)
        Search.start(root.pane)
        press(Qt.Key_Down)
        type("n")
        type("o")
        feedAnswer(2, tailRows)
        root.check("a new session parks on its best match with a stale generation behind it", root.pane.cursorIndex, 0)
        root.check("no turn drew an empty listing beside a count naming rows", root.blanks, 0)
        root.check("the shipped counter counts no blank frame on any turn either", root.frameBlanks, 0)
        console.log("SEARCHLIVE DONE checks=" + root.checks + " failed=" + root.failures)
        Qt.exit(root.failures === 0 ? 0 : 1)
    }
    // One canned answer triple through the shipped landing, the reply a backend would send.
    function feedAnswer(gen, rows) {
        Messages.route(msgRoot, { t: "listed", n: rows.length, read: 1, sort: 1, path: root.scope, changed: 0, v: 1, w: true, gen: gen })
        sample()
        Messages.route(msgRoot, { t: "rows", start: 0, rows: rows, ms: 1, kinds: [], listing: 900 + gen, gen: gen })
        sample()
        Messages.route(msgRoot, { t: "searched", n: rows.length, scanned: 10, ms: 5, cancelled: false, gen: gen, walking: false })
        sample()
        root.pane.refresh()
    }
    Timer {
        interval: 10
        repeat: false
        running: true
        onTriggered: {
            var args = Qt.application.arguments
            root.load(args[args.length - 1])
        }
    }
}
