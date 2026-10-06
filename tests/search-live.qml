import QtQuick
import "../ui/js/Search.js" as Search
import "../ui/js/Swap.js" as Swap
import "../ui/js/Focus.js" as Focus
import "../ui/js/Filter.js" as Filter
import "../ui/js/Messages.js" as Messages
import "js/filterfixture.js" as Fixture

// Replays the real session tests/search-live.sh drove against target/debug/flea, given as the last
// qml6 argument: every keystroke goes through Focus.handleKey with no Enter, its sends must equal
// the transcript's S lines, and the transcript's R lines land through Messages.route and the real
// Swap keep/land decisions. Drawn rows emptied beside a count that still names them is the blank
// frame R0 forbids; an honest no-match window carries its own zero count.
Item {
    id: root
    property int checks: 0
    property int failures: 0
    property int blanks: 0
    property bool hadRows: false
    property var phase: Swap.idle()
    property bool listedSeen: false
    property var sent: []
    property string relisted: ""
    property string folder: ""
    property var pane: null
    property var sidebar: ({ renameEditor: function () { return null } })
    property real lastMs: 0

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
        if (root.pane.rows.length > 0)
            root.hadRows = true
    }
    property var msgRoot: ({
        listed: function (total, read, sort, path) { landListed(total, path) },
        rows: function (start, items) { landRows(start, items) },
        searching: function (total, scanned, ms, gen) { Search.searching(root.pane, total, scanned, ms, gen) },
        searched: function (total, scanned, ms, cancelled, gen, walking) {
            root.lastMs = ms
            Search.searched(root.pane, total, scanned, ms, cancelled, gen, walking)
        }
    })
    function landListed(total, path) {
        if (Swap.keepLive(root.pane.searchMode, root.pane.listInFlight)) {
            root.phase = Swap.kept(root.phase, { total: total, path: path })
            root.listedSeen = true
            return
        }
        root.pane.total = total
    }
    function landRows(start, items) {
        var action = Swap.onRows(root.phase, root.pane.listInFlight, root.listedSeen)
        if (action === Swap.DROP)
            return
        var total = root.phase.listed ? root.phase.listed.total : root.pane.total
        if (action === Swap.LAND)
            root.phase = Swap.landed(root.phase)
        root.pane.held = start
        root.pane.rows = items
        root.pane.total = total
        root.pane.refresh()
        root.listedSeen = false
    }
    function setup(rows, folder) {
        var p = Fixture.pane()
        p.path = folder
        p.home = ""
        p.searchMode = ""
        p.searchQuery = ""
        p.searchFrom = ""
        p.searchHere = false
        p.searchRunning = false
        p.searchCancelled = false
        p.searchScanned = 0
        p.searchMs = 0
        p.searchGen = 0
        p.searchCursor = -1
        p.showHidden = false
        p.windowSize = 200
        p.visibleRows = 4
        p.focusView = "list"
        p.viewMode = "list"
        p.listInFlight = false
        p.rows = rows.slice()
        p.total = rows.length
        p.cursorIndex = 2
        p.refresh()
        p.setCursor = function (index) { Filter.setCursor(p, index) }
        p.renameEditor = function () { return null }
        p.clearSelection = function () { p.selection.clear() }
        p.listArea = { restartSettle: function () {}, restartCoalesce: function () {} }
        p.act = function (action) { Focus.act(action, p) }
        p.openWithoutHistory = function (next) { root.relisted = next }
        p.backend = {
            searchOpen: function (scope, folder, hidden) {
                root.sent.push({ c: "searchopen", path: scope, folder: folder, hidden: hidden })
            },
            searchQuery: function (query, gen, count) {
                root.sent.push({ c: "searchquery", query: query, gen: gen, count: count })
            },
            searchClose: function () { root.sent.push({ c: "searchclose" }) }
        }
        root.pane = p
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
        checkKey(block.key, block.count)
    }
    function checkKey(k, n) {
        if (n === 0)
            root.check("f opens the session on the scope", root.pane.searchMode, "typing")
        if (n === 1 || n === 9 || n === 14)
            root.check("ranked result rows land with no Enter", names(),
                ["notes.md", "north.txt", "docs/notes-old.md", "photo.png", "src/main.rs"])
        if (n === 2)
            root.check("the next keystroke replaces the window whole", names(),
                ["notes.md", "north.txt", "docs/notes-old.md"])
        if (n === 3)
            root.check("down moves the result cursor without leaving the query",
                root.pane.cursorIndex + "|" + root.pane.searchMode, "1|typing")
        if (n === 4)
            root.check("and up moves it back", root.pane.cursorIndex, 0)
        if (n === 5)
            root.check("backspace narrows through the index", names()[0] + "|" + root.pane.searchQuery, "notes.md|n")
        if (n === 6 || n === 8)
            root.check("backspace to empty brings the folder rows back, strip open",
                names().length + "|" + root.pane.searchMode, "8|typing")
        if (n === 7)
            root.check("a query with no match lands an honest empty window",
                names().length + "|" + root.pane.total, "0|0")
        if (n === 10)
            root.check("enter keeps the results and moves the keys to them", root.pane.searchMode, "results")
        if (n === 11)
            root.check("keys now walk the results", root.pane.cursorIndex, 1)
        if (n === 12) {
            Search.restoreCursor(root.pane)
            root.check("escape returns to the folder and cursor", root.pane.cursorIndex + "|" + names().length, "2|8")
        }
        if (n === 15)
            root.check("tab re-opens the scope and scoped rows land", names().length, 5)
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
        // The folder rows seed the pane; the folder is what the first session opens from.
        var folder = blocks[0].sends[0].folder
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
        setup(folderRows, folder)
        for (var k = 0; k < blocks.length; k++)
            runBlock(blocks[k])
        root.check("no turn drew an empty listing beside a count naming rows", root.blanks, 0)
        console.log("SEARCHLIVE DONE checks=" + root.checks + " failed=" + root.failures)
        Qt.exit(root.failures === 0 ? 0 : 1)
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
