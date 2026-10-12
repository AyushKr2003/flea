.import "../../ui/js/Crumbs.js" as Crumbs
.import "../../ui/js/Drag.js" as Drag
.import "sourcefixture.js" as Source

// The chrome's breadcrumb, issue 45 and Chrome rule 2: the pieces a click can land on, and what
// fits when the strip is narrower than the path. Split out of tests/js/nav.js with the module.

// The two readings a crumb check makes: what the bar draws, and where each piece would take you.
function drawn(list) {
    return list.map(function (c) { return c.text }).join("")
}

function targets(list) {
    return list.map(function (c) { return c.path }).join(" ")
}

function run(check) {
    // Issue 45: the chrome's path as the pieces a click can land on. The pieces have to concatenate
    // to exactly the one line they replace, or the bar draws something nobody asked for, and each
    // has to name the directory ui/ChromeBar.qml would hand to pathEntered.
    var under = Crumbs.crumbs("/home/gm/Work/claude", "/home/gm")
    check("the crumbs read as the tilde path they replace", drawn(under), "~/Work/claude")
    check("and each one names the directory it would open",
          targets(under), "/home/gm /home/gm/Work /home/gm/Work/claude")
    check("and only the last is the directory the pane is already in",
          under.map(function (c) { return c.last }).join(","), "false,false,true")
    var atHome = Crumbs.crumbs("/home/gm", "/home/gm")
    check("home itself is one crumb, the bare tilde",
          drawn(atHome) + "|" + targets(atHome), "~|/home/gm")
    var outside = Crumbs.crumbs("/usr/share", "/home/gm")
    check("a path outside home keeps its leading separator, which is a crumb of its own",
          drawn(outside) + "|" + targets(outside), "/usr/share|/ /usr /usr/share")
    var root = Crumbs.crumbs("/", "/home/gm")
    check("the root is one crumb and it is the last one",
          drawn(root) + "|" + targets(root) + "|" + root.length, "/|/|1")
    var noHome = Crumbs.crumbs("/home/gm/Work", "")
    check("with no home in the environment every component is its own crumb",
          drawn(noHome) + "|" + targets(noHome), "/home/gm/Work|/ /home /home/gm /home/gm/Work")
    // ui/js/Format.js tilde writes /home/gmx as "~x", which is a wrong label on a line nobody can
    // click and a wrong destination on one they can, so the crumbs test the separator themselves.
    var sibling = Crumbs.crumbs("/home/gmx/deep", "/home/gm")
    check("a sibling whose name merely starts with home's is outside it, and says so",
          drawn(sibling) + "|" + targets(sibling), "/home/gmx/deep|/ /home /home/gmx /home/gmx/deep")

    // Issue 237: a saved label replaces only the whole mounted root component, and every target stays the real GVFS path.
    var davRoot = "/run/user/1000/gvfs/dav:host=cloud.example.com,ssl=true,prefix=%2Fdav%2Fspaces%2FSPACE-ID"
    var dav = Crumbs.crumbs(davRoot + "/Documents/Projects", "/home/gm",
                            { path: davRoot, label: "Cloud — Personal" })
    check("a saved network label replaces the internal GVFS root in the breadcrumb",
          drawn(dav), "Cloud — Personal/Documents/Projects")
    check("and every aliased crumb still navigates by its real filesystem path",
          targets(dav), davRoot + " " + davRoot + "/Documents " + davRoot + "/Documents/Projects")
    var davAtRoot = Crumbs.crumbs(davRoot, "/home/gm", { path: davRoot, label: "Cloud — Personal" })
    check("the mounted root itself is one crumb carrying the saved label",
          drawn(davAtRoot) + "|" + targets(davAtRoot), "Cloud — Personal|" + davRoot)
    var davTrailing = Crumbs.crumbs(davRoot + "/", "/home/gm", { path: davRoot, label: "Cloud — Personal" })
    check("a trailing slash on the mounted root still draws the saved label alone",
          drawn(davTrailing) + "|" + targets(davTrailing) + "|" + davTrailing[0].last,
          "Cloud — Personal|" + davRoot + "|true")
    var slashLabel = Crumbs.crumbs(davRoot + "/Documents", "/home/gm",
                                   { path: davRoot, label: "Cloud / Personal" })
    check("a slash inside a saved label does not split it into false path crumbs",
          slashLabel.length + "|" + slashLabel[0].text + "|" + targets(slashLabel),
          "2|Cloud / Personal/|" + davRoot + " " + davRoot + "/Documents")
    var davSibling = Crumbs.crumbs(davRoot + "-old/Documents", "/home/gm",
                                   { path: davRoot, label: "Cloud — Personal" })
    check("a path that merely starts with the mount root does not inherit its label",
          drawn(davSibling), davRoot + "-old/Documents")

    var aliases = Crumbs.rememberAlias([], davRoot, "Cloud — Personal", "davs://cloud/personal")
    var teamRoot = davRoot + "/Team"
    aliases = Crumbs.rememberAlias(aliases, teamRoot + "/", "Cloud — Team", "davs://cloud/team")
    check("the deepest of two mounted roots on one host supplies the visible label",
          Crumbs.aliasAt(teamRoot + "/Roadmap", aliases).label, "Cloud — Team")
    var deepFirst = Crumbs.rememberAlias(Crumbs.rememberAlias([], teamRoot, "Cloud — Team", "davs://cloud/team"),
                                         davRoot, "Cloud — Personal", "davs://cloud/personal")
    check("and the deepest root wins whichever order the two were remembered in",
          Crumbs.aliasAt(teamRoot + "/Roadmap", deepFirst).label, "Cloud — Team")
    check("and the broader root still labels its own other descendants",
          Crumbs.aliasAt(davRoot + "/Documents", aliases).label, "Cloud — Personal")
    check("a sibling outside every remembered root has no alias",
          Crumbs.aliasAt(davRoot + "-old/Documents", aliases), null)
    var moved = Crumbs.rememberAlias(aliases, davRoot + "/Personal", "Personal files", "davs://cloud/personal")
    check("resolving one saved location at a new path replaces its stale root",
          Crumbs.aliasAt(davRoot + "/Documents", moved), null)
    check("and the replacement root keeps the new label",
          Crumbs.aliasAt(davRoot + "/Personal/Docs", moved).label, "Personal files")
    // The live row deliberately shares the favourite's key: accepting it would let gio's label overwrite the saved one on every poll.
    var labels = Crumbs.labelsByKey([
        { path: "davs://cloud/personal/", label: "Cloud — Private", saved: true },
        { uri: "davs://cloud/personal/", label: "Personal on cloud.example.com", saved: false }
    ], function (uri) { return String(uri).replace(/\/$/, "") })
    var renamed = Crumbs.relabelAliases(moved, labels)
    check("a live gio row cannot overwrite the saved connection label under the same key",
          Crumbs.aliasAt(davRoot + "/Personal/Docs", renamed).label, "Cloud — Private")
    check("and leaves another mounted space's label alone",
          Crumbs.aliasAt(teamRoot + "/Roadmap", renamed).label, "Cloud — Team")

    // Chrome rule 2: the strip collapses whole crumbs into one marker rather than cutting one in half.
    var deep = Crumbs.crumbs("/home/gm/one/two/three/four/five", "/home/gm")
    check("a path that fits keeps every crumb", drawn(Crumbs.fitCrumbs(deep, 80)), "~/one/two/three/four/five")
    check("a path too long for the strip reads as its root, a marker and the two nearest you",
          drawn(Crumbs.fitCrumbs(deep, 16)), "~/\u2026/four/five")
    // The marker names no directory, so ui/ChromeBar.qml has something to refuse a press on.
    check("and the marker it inserts carries no destination",
          Crumbs.fitCrumbs(deep, 16)[1].path + String(Crumbs.fitCrumbs(deep, 16)[1].elided), "true")
    check("room left over goes back to the crumbs nearest the root",
          drawn(Crumbs.fitCrumbs(deep, 24)), "~/one/two/\u2026/four/five")
    // Three crumbs have no middle to collapse, so the marker would cost a segment and save nothing.
    check("a path with nothing between its root and the two nearest is left whole",
          drawn(Crumbs.fitCrumbs(Crumbs.crumbs("/home/gm/one/two", "/home/gm"), 4)), "~/one/two")

    // V7: at the floor width the leaf was cut by the strip's own edge, with no marker of any kind.
    var long = Crumbs.crumbs("/home/gm/a-directory-with-a-deliberately-long-name", "/home/gm")
    check("a leaf too long for what is left of the strip takes the ellipsis itself",
          drawn(Crumbs.fitCrumbs(long, 20)), "~/a-directo\u2026ong-name")
    check("and it still names the directory it stands for",
          Crumbs.fitCrumbs(long, 20)[1].path, "/home/gm/a-directory-with-a-deliberately-long-name")
    check("the collapsed form elides its leaf too, once the marker leaves it no room",
          drawn(Crumbs.fitCrumbs(Crumbs.crumbs("/home/gm/one/two/three/a-very-long-leaf-name", "/home/gm"), 18)),
          "~/\u2026/three/a-ve\u2026ame")
    check("a leaf that exactly fills what is left of the strip is drawn whole",
          drawn(Crumbs.fitCrumbs(Crumbs.crumbs("/home/gm/one/two/three/four", "/home/gm"), 14)), "~/\u2026/three/four")
    // A parent that leaves the leaf less than its floor is elided itself, rather than the leaf being
    // cut to nothing: rule 2 elides whole crumbs and the leaf is the one that may not be dropped.
    var wide = Crumbs.crumbs("/home/gm/one/two/a-parent-with-a-very-long-name-indeed/leaf-name", "/home/gm")
    check("a parent that leaves the leaf no room is elided with the middle",
          drawn(Crumbs.fitCrumbs(wide, 16)), "~/\u2026/leaf-name")
    // The floor's own case: a leaf shorter than it gives up more to the ellipsis than that saves.
    check("and a budget too small for even that keeps the leaf whole rather than cutting it to an ellipsis",
          drawn(Crumbs.fitCrumbs(Crumbs.crumbs("/home/gm/one/two/three/four", "/home/gm"), 6)), "~/\u2026/four")

    // Drops040 specimen e: a crumb takes the folder row's verb, a move within one drive.
    check("a plain drop on a same-device crumb moves",
          Drag.verbFor(true, false, false, 56, 56, true), "move")
    check("and on another device's crumb it copies",
          Drag.verbFor(true, false, false, 56, 32, true), "copy")
    // The crumb hands verbFor the device the peek answer carried, never the listing's guess.
    var dropSrc = Source.source("ui/CrumbDrop.qml")
    var asked = []
    var peekPane = { backend: { peek: function (path, first) { asked.push(path + "|" + first) } } }
    var askRoot = { dest: "/media/usb", destDev: 77, asked: "", containsDrag: false, crumb: {}, pane: peekPane }
    askRoot.askDev = new Function("root", "return function () {" + Source.block(dropSrc, "function askDev()", "ui/CrumbDrop.qml") + "}")(askRoot)
    var dragChanged = new Function("root", "return function () {" + Source.block(dropSrc, "onContainsDragChanged:", "ui/CrumbDrop.qml") + "}")(askRoot)
    var destChanged = new Function("root", "return function () {" + Source.block(dropSrc, "onDestChanged:", "ui/CrumbDrop.qml") + "}")(askRoot)
    check("a crumb made by a navigation, with no drag over it, sends no peek", asked.length + "|" + dropSrc.indexOf("Component.onCompleted"), "0|-1")
    destChanged()
    check("a new destination with no drag over it resets the verb to copy and still sends no peek", askRoot.destDev + "|" + asked.length, "0|0")
    askRoot.containsDrag = true
    dragChanged()
    check("the first drag over the crumb asks the backend for its device", asked.join(","), "/media/usb|0")
    dragChanged()
    askRoot.containsDrag = false
    dragChanged()
    askRoot.containsDrag = true
    dragChanged()
    check("a second drag over the same destination asks nothing more", asked.length, 1)
    askRoot.dest = "/media/other"
    destChanged()
    check("a destination change under a drag asks for the new one", asked.join(","), "/media/usb|0,/media/other|0")
    // A crumb made before its pane marks nothing asked, so the pane's arrival still gets its ask.
    var late = { dest: "/media/usb", destDev: 0, asked: "", containsDrag: true, crumb: {}, pane: null }
    late.askDev = new Function("root", "return function () {" + Source.block(dropSrc, "function askDev()", "ui/CrumbDrop.qml") + "}")(late)
    late.askDev()
    check("a crumb with no pane yet asks nothing and marks nothing asked", late.asked + "|" + asked.length, "|2")
    late.pane = peekPane
    late.askDev()
    check("and asks once its pane arrives", asked.slice(2).join(","), "/media/usb|0")
    var landBody = Source.block(dropSrc, "function landDev(path, first, readFailed, dev)", "ui/CrumbDrop.qml")
    function landed(dest, path, first, readFailed, dev) {
        var root = { dest: dest, destDev: 0 }
        new Function("root", "return function (path, first, readFailed, dev) {" + landBody + "}")(root)(path, first, readFailed, dev)
        return root.destDev
    }
    check("the answered device lands on the crumb", landed("/media/usb", "/media/usb", 0, false, 32), 32)
    check("a reply for another path lands nowhere", landed("/media/usb", "/home/gm", 0, false, 56), 0)
    check("nor does a column's own reply", landed("/media/usb", "/media/usb", 200, false, 32), 0)
    check("a failed read stays a copy", landed("/media/usb", "/media/usb", 0, true, 32), 0)
    // Backend's own declared signal order feeds the Connections handler, so a moved parameter lands the wrong device.
    var declared = /signal peeked\(([^)]*)\)/.exec(Source.source("ui/Backend.qml"))[1].split(",").map(function (one) { return one.trim().split(/\s+/)[1] })
    var wired = { dest: "/media/usb", destDev: 0 }
    wired.landDev = new Function("root", "return function (path, first, readFailed, dev) {" + landBody + "}")(wired)
    var onPeeked = new Function("root", "return (" + Source.slice(dropSrc, "function onPeeked(", "\n    }") + ")")(wired)
    onPeeked.apply(null, declared.map(function (name) {
        return { path: "/media/usb", hidden: false, total: 0, rows: [], readFailed: false, mode: 0, hiddenLast: false, first: 0, dev: 32 }[name] }))
    check("a peeked emitted in Backend's declared order lands its device through the handler", wired.destDev, 32)
    // The other two peeked readers drop the first-0 device ask, which carries no rows.
    var seen = []
    var chromeHandler = new Function("chrome", "return (" + Source.slice(Source.source("ui/WindowBody.qml"), "function onPeeked(", "\n") + ")")({ completeWith: function (path) { seen.push("chrome " + path) } })
    var repairHandler = new Function("root", "return (" + Source.slice(Source.source("ui/NetworkMounts.qml"), "function onPeeked(", "\n") + ")")({ repairPeeked: function (path) { seen.push("repair " + path) } })
    function emit(handler, first) {
        handler.apply(null, declared.map(function (name) { return { path: "/p", hidden: false, total: 0, rows: [], readFailed: false, mode: 0, hiddenLast: false, first: first, dev: 1 }[name] }))
    }
    emit(chromeHandler, 0)
    emit(repairHandler, 0)
    check("a crumb's first-0 reply reaches neither the bar's completion nor the mount repair", seen.length, 0)
    emit(chromeHandler, 200)
    emit(repairHandler, 512)
    check("while their own replies still do", seen.join(","), "chrome /p,repair /p")
}
