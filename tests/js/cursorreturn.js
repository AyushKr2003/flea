.import "../../ui/js/BackReturn.js" as BackReturn
.import "../../ui/js/Nav.js" as Nav
.import "../../ui/js/Tabs.js" as Tabs
.import "nav.js" as NavSuite

// Back and Forward land the cursor by name, then saved index, then the top, in ui/PaneSwap.qml's rows turn.

function rowsOf(names) { return names.map(function (name) { return { n: name } }) }

// A pane standing in /home/gm/Work with its cursor on index, through the real Nav verbs.
function standing(names, index, history) {
    var p = NavSuite.browsing(history || [])
    p.searchMode = ""
    p.searchFrom = ""
    p.recentMode = ""
    p.recentFrom = ""
    p.viewMode = "list"
    p.showHidden = false
    p.selectionVersion = 0
    p.held = 0
    p.rows = rowsOf(names)
    p.total = names.length
    p.cursorIndex = index
    p.listingPath = "/home/gm/Work"
    // ui/PaneSwap.qml hold(): every listing arms the travel's restore, any other listing clears it.
    p.swap = { restore: null,
        hold: function (ask) { p.swap.restore = ask.restore || null; return false } }
    p.rowFor = function (i) { return p.rows[i - p.held] || null }
    p.join = function (base, name) { return base + "/" + name }
    p.selectedIndices = function () { return [] }
    p.selection = { follows: function () { return false }, toggle: function () {} }
    p.clearSelection = function () { p.selectionVersion++ }
    p.backend.sortBy = "name"
    p.backend.sortDesc = false
    p.backend.listRequests = 1
    p.backend.dirDev = 7
    p.setCursor = function (i) { p.cursorIndex = Math.max(0, Math.min(p.total - 1, i)) }
    return p
}

// The listing's first rows in ui/PaneSwap.qml rowsLanded order; returns the cursor that turn took.
function land(p, names, total) {
    Nav.forget(p)
    p.held = 0
    p.rows = rowsOf(names)
    p.total = total === undefined ? names.length : total
    BackReturn.landRestore(p, p.swap.restore)
    p.swap.restore = null
    p.listInFlight = false
    return p.cursorIndex
}

function run(check) {
    // Travel keeps the departed directory for forward, a refresh keeps the branch, a new open drops it.
    var travel = standing(["a"], 0, [BackReturn.makeEntry("/home/gm", "", 0)])
    Nav.back(travel)
    check("back preserves the departed directory for forward",
        travel.forwardHistory.map(BackReturn.pathOf).join("|"), "/home/gm/Work")
    Nav.forward(travel)
    check("forward while loading preserves the destination", travel.forwardHistory.length, 1)
    travel.listInFlight = false
    Nav.forward(travel)
    check("forward returns to the departed directory", travel.path, "/home/gm/Work")
    check("forward restores back history",
        travel.history.map(BackReturn.pathOf).join("|"), "/home/gm")
    travel.listInFlight = false
    Nav.back(travel)
    travel.listInFlight = false
    Nav.open(travel, travel.path)
    check("refresh preserves forward history", travel.forwardHistory.length, 1)
    travel.listInFlight = false
    Nav.open(travel, "/tmp")
    check("new navigation discards the old forward branch", travel.forwardHistory.length, 0)

    // Entering a folder records the row; Back finds it by name after an insertion renumbered it.
    var into = standing(["a", "b", "c", "d", "Music", "z"], 4)
    Nav.open(into, "/home/gm/Work/Music")
    check("entering a folder records the row the cursor left",
        BackReturn.pathOf(into.history[0]) + "|" + into.history[0].name + "|" + into.history[0].index,
        "/home/gm/Work|Music|4")
    land(into, ["x", "y"])
    into.setCursor(1)
    Nav.back(into)
    check("back records the folder it leaves for forward",
        BackReturn.pathOf(into.forwardHistory[0]) + "|" + into.forwardHistory[0].name,
        "/home/gm/Work/Music|y")
    check("back lands on the folder it left, by name, after an insertion renumbered it",
        land(into, ["a", "b", "new", "c", "d", "Music", "z"]), 5)
    Nav.forward(into)
    check("forward lands on the row it left there, by name, after a reorder",
        land(into, ["y", "x"]), 0)
    into.setCursor(1)
    Nav.back(into)
    check("a second back keeps finding the name wherever the sort put it",
        land(into, ["Music", "a"]), 0)

    // Gone since: the saved index, clamped to the listing; an empty listing keeps the top.
    var gone = standing(["a"], 0)
    gone.history = [BackReturn.makeEntry("/home/gm", "deleted", 7)]
    Nav.back(gone)
    check("a name missing from the listing falls back to the saved index, clamped",
        land(gone, ["a", "b", "c"]), 2)
    var empty = standing(["a"], 0)
    empty.history = [BackReturn.makeEntry("/home/gm", "deleted", 7)]
    Nav.back(empty)
    check("an empty directory settles at the top with nothing armed",
        land(empty, [], 0) + "|" + empty.swap.restore, "0|null")

    // A newer listing replaces the armed entry, so the next rows land at the top and another directory's landing is dropped.
    var replaced = standing(["a"], 0)
    replaced.history = [BackReturn.makeEntry("/home/gm", "far", 3)]
    Nav.back(replaced)
    replaced.listInFlight = false
    replaced.swap.restore = null
    check("a failed listing drops the entry it armed", replaced.swap.restore, null)
    check("and the next rows land at the top", land(replaced, ["far", "b"]), 0)
    BackReturn.landRestore(replaced, BackReturn.makeEntry("/elsewhere", "far", 3))
    check("a landing for another directory moves nothing", replaced.cursorIndex, 0)

    // A walk's rows name matches under their scope, so leaving one records no row to come back to.
    var search = standing(["sub/found.txt"], 0, [])
    search.searchMode = "results"
    Nav.open(search, "/tmp")
    check("leaving a search records its scope at the top, naming no row",
        BackReturn.pathOf(search.history[0]) + "|" + search.history[0].name + "|" + search.history[0].index,
        "/home/gm/Work||0")

    // A re-sorted folder still answers by name: the order left behind is not the order returned to.
    var resorted = standing(["b", "a", "Music"], 2)
    Nav.open(resorted, "/home/gm/Work/Music")
    check("back finds the name in the new order, not the index it stood on",
        land(resorted, ["Music", "a", "b"]), 0)

    // Each tab keeps its own stacks, so a tab switch keeps what every Back still owes its folder.
    var tabbed = standing(["a", "b", "Music"], 2)
    tabbed.history = [BackReturn.makeEntry("/home/gm", "Music", 2)]
    tabbed.tabs = Tabs.pack([Tabs.snapshot(tabbed), Tabs.snapshot(tabbed)], 0)
    Tabs.selectAt(tabbed, 1)
    Tabs.selectAt(tabbed, 0)
    Nav.back(tabbed)
    check("a tab switch keeps the stacks the back travels",
        land(tabbed, ["a", "b", "Music"]), 2)
}
