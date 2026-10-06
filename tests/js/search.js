.import "../../ui/js/Search.js" as Search
.import "../../ui/js/RecentMode.js" as RecentMode

function run(check) {
    // The strip's right edge while a session walks: the count alone, then the count with its time.
    // Only these shapes reach the strip; an empty query shows no count over the folder rows.
    check("a walking session pairs the count with nothing else", Search.note(9, true, 0, false), "9 found")
    check("and a landed one with its time", Search.note(9, false, 412, false), "9 found in 0.4 s")
    check("and a four-figure find groups", Search.note(1204, true, 0, false), "1,204 found")
    check("and nothing found still says so", Search.note(0, false, 412, false), "0 found in 0.4 s")
    check("and an empty query shows no count at all", Search.note(12, true, 0, true), "")
    check("even once its folder rows land", Search.note(12, false, 30, true), "")

    // V7: the SearchFilter board's own status cell, the count beside the state that changes it.
    check("a running walk pairs what it found with what it scanned",
          Search.statusLine(true, 12, 4120, 300), "12 found · Searching, 4,120 scanned")
    check("a finished walk reports what it found and how long it took",
          Search.statusLine(false, 1, 18204, 412), "1 found in 0.4 s")
    check("and nothing found still says so", Search.statusLine(false, 0, 18204, 412), "0 found in 0.4 s")


    check("the home prefix reads as a tilde", Search.scope("/home/gm/Work/claude/flea", "/home/gm"), "~/Work/claude/flea")
    check("home itself is the bare tilde", Search.scope("/home/gm", "/home/gm"), "~")
    check("a path outside home keeps its own form", Search.scope("/usr/share", "/home/gm"), "/usr/share")

    // The scope rule: the backend walks whatever path this picks, so this is the whole of
    // "universal search across the home folder" and the only place the policy lives.
    check("a search anywhere under home walks the whole home directory",
          Search.scopeRoot("/home/u/Downloads/deep", "/home/u"), "/home/u")
    check("home itself is already the scope", Search.scopeRoot("/home/u", "/home/u"), "/home/u")
    check("a mount outside home searches the mount, never home instead",
          Search.scopeRoot("/run/media/u/NAS/photos", "/home/u"), "/run/media/u/NAS/photos")
    check("a sibling whose name merely starts with home's is outside it",
          Search.scopeRoot("/home/under", "/home/u"), "/home/under")
    check("with no home in the environment the pane searches where it stands",
          Search.scopeRoot("/d", ""), "/d")

    // The strip's own right edge, which the board draws as the pair esc really is from here.
    check("the strip's way out is one esc, walking or landed", Search.WAY_OUT, "esc returns")


    // The pointer's own contract: a double click on a result reveals it, and opens a row anywhere
    // else. ui/js/Tap.js asks this rather than deciding it, so the rule lives beside the reveal.
    check("a double click on a search result takes the operator to the file",
          Search.activateAction({ searchMode: "results" }), "reveal")
    check("a double click on an ordinary row still opens it",
          Search.activateAction({ searchMode: "" }), "open")
    check("a double click while the query line is still up opens the row under it",
          Search.activateAction({ searchMode: "typing" }), "open")

    // A walk with no matches yet is still working, so the area keeps the crawl rather than flashing empty.
    check("matches make the listing ready", Search.listingState({ searchRunning: true }, 3), "ready")
    check("a running walk with nothing yet is still loading", Search.listingState({ searchRunning: true }, 0), "loading")
    check("a stopped walk with nothing is empty", Search.listingState({ searchRunning: false }, 0), "empty")

    // The live session: opening starts the scope's walk at once, every keystroke sends its
    // query with a rising generation, and answers for an older generation are ignored.
    // Only the members start, typed and backspace touch are stubbed; sent records the wire.
    function typing(query) {
        var sent = []
        var p = {
            searchMode: "typing", searchQuery: query, searchRunning: false, searchScanned: 0,
            searchCancelled: false, searchMs: 0, searchGen: 0, searchCursor: 3, path: "/d",
            showHidden: false, total: 0, held: 0, rows: [], kindNames: [], cursorIndex: 3,
            listingState: "ready", opened: 0, sent: sent, windowSize: 200, shownTotal: 9,
            home: "", searchFrom: "", relisted: "", searchHere: false,
            clearSelection: function () {},
            setCursor: function (index) { p.cursorIndex = Math.max(0, Math.min(p.shownTotal - 1, index)) },
            listArea: { restartSettle: function () {} },
            open: function (path) { p.opened += 1 },
            openWithoutHistory: function (path) { p.relisted = path },
            // Mirrors ui/Pane.qml restoreRecentSort, so a walk from Recent restores through it.
            restoreRecentSort: function () { RecentMode.restoreSort(p) },
            backend: { searchOpen: function (scope, folder, hidden) { sent.push("open " + scope + "|" + folder) },
                        searchQuery: function (query, gen, count) { sent.push("query " + gen + ":" + query + "/" + count) },
                        searchClose: function () { sent.push("close") } }
        }
        return p
    }
    function press(code, text) { return { key: code, text: text, modifiers: Qt.NoModifier } }
    var opener = typing("")
    opener.searchMode = ""
    Search.start(opener)
    check("opening the strip starts the scope walk at once, with no rows touched",
          opener.searchMode + "|" + opener.sent.join(","), "typing|open /d|/d")
    check("and remembers the folder and cursor for the way back",
          opener.searchFrom + "|" + opener.searchCursor, "/d|3")
    var again = typing("")
    again.searchMode = "typing"
    Search.start(again)
    check("opening twice starts one session", again.sent.length, 0)
    var delLine = typing("")
    Search.typeKey({ key: Qt.Key_Delete, text: "\u007f", modifiers: Qt.NoModifier }, delLine)
    check("DEL types nothing into search", delLine.searchQuery + "|" + delLine.sent.length, "|0")
    Search.typeKey(press(Qt.Key_E, "e"), delLine)
    check("a letter sends its query with the first generation",
          delLine.searchQuery + "|" + delLine.sent.join(","), "e|query 1:e/200")
    var line = typing("scr")
    Search.typeKey(press(Qt.Key_E, "e"), line)
    check("a printable key extends the query and sends the next generation",
          line.searchQuery + "|" + line.sent.join(","), "scre|query 1:scre/200")
    Search.typeKey(press(Qt.Key_E, "e"), line)
    check("and generations rise one per keystroke", line.sent.join(","), "query 1:scre/200,query 2:scree/200")
    check("and each send parks the cursor on the best match", line.cursorIndex, 0)
    Search.typeKey(press(Qt.Key_Backspace, ""), line)
    check("backspace shrinks the query and re-sends it",
          line.searchQuery + "|" + line.sent.pop(), "scre|query 3:scre/200")
    Search.typeKey(press(Qt.Key_Backspace, ""), line)
    Search.typeKey(press(Qt.Key_Backspace, ""), line)
    Search.typeKey(press(Qt.Key_Backspace, ""), line)
    Search.typeKey(press(Qt.Key_Backspace, ""), line)
    check("backspace to empty sends the empty query and the folder rows come back, strip open",
          line.searchQuery + "|" + line.sent.pop() + "|" + line.searchMode, "|query 7:/200|typing")
    check("backspace past empty sends nothing more", line.sent.length, 5)
    var keyed = typing("scr")
    keyed.searchGen = 2
    keyed.total = 11
    Search.searched(keyed, 11, 400, 33.1, false, 1, false)
    check("an answer for an older generation is ignored", keyed.total + "|" + keyed.searchRunning, "11|false")
    Search.searched(keyed, 4, 400, 33.1, false, 2, true)
    check("and one for the newest sent generation replaces the counts while walking",
          keyed.total + "|" + keyed.searchRunning, "4|true")
    Search.searched(keyed, 4, 400, 33.1, false, 2, false)
    check("and its landing ends the walk", keyed.searchRunning, false)
    var batch = typing("scr")
    batch.searchGen = 2
    Search.searching(batch, 3, 400, 33.1, 2)
    check("a batch for the standing query moves the counts", batch.total, 3)
    Search.searching(batch, 9, 400, 33.1, 1)
    check("and a batch for an older one is dropped", batch.total, 3)
    var kept = typing("scr")
    kept.searchGen = 1
    Search.typeKey(press(Qt.Key_Return, ""), kept)
    check("enter keeps the results and moves the keys to them, sending nothing",
          kept.searchMode + "|" + kept.sent.length, "results|0")
    var abandoned = typing("scr")
    abandoned.searchGen = 3
    Search.typeKey(press(Qt.Key_Escape, ""), abandoned)
    check("escape closes the session and re-lists the folder it came from",
          abandoned.searchMode + "|" + abandoned.sent.join(",") + "|" + abandoned.relisted, "|close|/d")
    var untouched = typing("")
    untouched.searchMode = ""
    Search.start(untouched)
    Search.typeKey(press(Qt.Key_Escape, ""), untouched)
    check("escape with nothing sent closes the session and lists nothing again",
          untouched.sent.join(",") + "|" + untouched.relisted, "open /d|/d,close|")
    var underHome = typing("scr")
    underHome.home = "/home/u"
    underHome.path = "/home/u/Downloads"
    underHome.searchMode = ""
    Search.start(underHome)
    check("the session opens on the home scope and remembers the folder, never taking it as base",
          underHome.sent.join(",") + "|" + underHome.path + "|" + underHome.searchFrom,
          "open /home/u|/home/u/Downloads|/home/u/Downloads|/home/u/Downloads")

    // Issue 30: the scope is chosen on the query line itself rather than in the settings, because it
    // belongs to this search and not to the application; the strip's own "in <scope>" is the readout,
    // and nothing is persisted, which is the whole reason this needs no settings row.
    check("with the scope set to here the walk stays in the pane's own directory",
          Search.scopeRoot("/home/u/Downloads/deep", "/home/u", true), "/home/u/Downloads/deep")
    check("and with it off the walk is still the whole home directory",
          Search.scopeRoot("/home/u/Downloads/deep", "/home/u", false), "/home/u")
    var here = typing("scr")
    here.home = "/home/u"
    here.path = "/home/u/Downloads"
    here.searchGen = 1
    Search.typeKey(press(Qt.Key_Tab, "\t"), here)
    check("tab on the query line points the walk at the directory the pane is in", here.searchHere, true)
    check("re-opens the new scope and re-sends the standing query",
          here.sent.join(","), "open /home/u/Downloads|/home/u/Downloads,query 2:scr/200")
    Search.typeKey(press(Qt.Key_Backtab, "\t"), here)
    check("and the key flips back, so home is one press away again", here.searchHere, false)
    check("each flip re-opens and re-sends", here.sent.pop(), "query 3:scr/200")

    var blank = typing("")
    Search.typeKey(press(Qt.Key_Return, ""), blank)
    check("enter on an empty line closes it and sends nothing",
          blank.searchMode + "|" + blank.sent.join(","), "|close")

    var landed = typing("no")
    landed.searchMode = ""
    landed.searchCursor = 2
    landed.cursorIndex = 0
    check("the folder re-list restores the cursor the session opened on",
          Search.restoreCursor(landed) + "|" + landed.cursorIndex + "|" + landed.searchCursor, "true|2|-1")
    var waiting = typing("no")
    waiting.searchCursor = 2
    check("while a session stands nothing is restored", Search.restoreCursor(waiting), false)
}
