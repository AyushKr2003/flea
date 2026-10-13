//@ pragma ShellId flea-preview-scroll-test
import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import "flea" as Flea
import "flea/js/Scroll.js" as Scroll

ShellRoot {
    id: root
    readonly property string fixture: Quickshell.env("PREVIEW_SCROLL_DIR")
    readonly property string shots: Quickshell.env("PREVIEW_SCROLL_OUT")
    property var pane: null
    property var keys: null
    property int checks: 0
    property int failures: 0
    property int at: 0
    property var waiting: null
    property double started: Date.now()
    property bool finished: false
    property bool ticking: false
    property real beforeY: 0
    property real expectedY: 0
    property var beforeFocus: null
    property int beforeCursor: 0
    property int beforeObjects: 0
    property int beforeHeld: 0
    property real savedCode: 0
    property real savedMarkdown: 0
    property string restoring: ""
    property real restoreY: 0
    property int restoreFrames: 0
    property int badFrames: 0
    property bool watchScroll: false
    property bool captured: false
    readonly property var ops: ["open", "seams", "capture-code-rest", "code-click", "code-wheel", "forward", "capture-code-paged", "back", "code-save", "code-next", "code-return",
        "code-memory", "code-end", "forward-end", "code-top", "back-top", "short", "short-check", "markdown",
        "capture-markdown-rest", "markdown-click", "markdown-wheel", "forward", "capture-markdown-paged", "back", "markdown-save", "markdown-next", "markdown-return", "markdown-memory",
        "markdown-end", "forward-end", "markdown-top", "back-top", "image", "image-check", "code-again", "rewrite", "rewrite-check",
        "empty", "empty-check", "large", "large-check", "capacity", "list", "list-check", "done"]

    function check(label, actual, expected) {
        root.checks++
        var ok = JSON.stringify(actual) === JSON.stringify(expected)
        if (!ok) root.failures++
        console.log("PVSCROLL " + (ok ? "PASS " : "FAIL ") + label + " got=" + JSON.stringify(actual) + " expected=" + JSON.stringify(expected))
    }
    function near(label, actual, expected) { root.check(label + " actual=" + actual + " expected=" + expected, Math.abs(actual - expected) <= 1, true) }
    function descendants(item) {
        var out = item ? [item] : []
        for (var i = 0; i < out.length; i++) {
            var kids = out[i].children || []
            for (var k = 0; k < kids.length; k++) out.push(kids[k])
        }
        return out
    }
    function col() { return root.pane ? root.pane.previewColumnItem : null }
    function view() { return root.memory() ? root.memory().viewport : null }
    function memory() { return root.descendants(root.col()).filter(function (n) { return n.objectName === "previewScroll" })[0] }
    function code() { return root.col() ? root.col().linesItem.code : null }
    function name() { return root.col() ? root.col().path.split("/").pop() : "" }
    function listingObjects() { return root.descendants(root.pane.listArea.activeColumn().viewport).length }
    function bar() {
        return root.descendants(root.col()).filter(function (n) { return n.flickable === root.view() && n.vertical === true && n.knobItem !== undefined })[0]
    }
    function ready(file) {
        var c = root.col()
        return c && root.name() === file && c.swap.ready && !c.swap.holding && !c.swap.capturing && !c.textLoading
    }
    function key(text) { root.keys.keyClickChar(text, text === text.toUpperCase() ? Qt.ShiftModifier : Qt.NoModifier, -1) }
    function waitFile(file) { root.waiting = function () { return root.ready(file) } }
    function moveTo(index, file) { root.pane.setCursor(index); root.waitFile(file) }
    function snapshot() {
        root.pane.listArea.activeColumn().viewport.forceLayout()
        root.beforeY = root.view().contentY
        root.beforeFocus = win.contentItem.Window.window.activeFocusItem
        root.beforeCursor = root.pane.cursorIndex
        root.beforeObjects = root.listingObjects()
        root.beforeHeld = root.code() ? Object.keys(root.code().held).length : 0
        root.watchScroll = true
    }
    function stable() {
        root.check("listing keeps keyboard focus", win.contentItem.Window.window.activeFocusItem === root.beforeFocus, true)
        root.check("listing cursor is unchanged", root.pane.cursorIndex, root.beforeCursor)
        root.check("scroll builds no listing objects", root.listingObjects(), root.beforeObjects)
        if (!root.col().isMarkdownRow) {
            var added = Object.keys(root.code().held).length - root.beforeHeld
            root.check("code asks no more than a newly visible screen", added <= Math.ceil(root.view().height / root.code().rowHeight) + 1, true)
        }
        root.watchScroll = false
    }
    function page(letter) {
        root.snapshot()
        var bounds = Scroll.limitsY(root.view())
        root.expectedY = Math.max(bounds.min, Math.min(bounds.max, root.beforeY + (letter === "F" ? 1 : -1) * root.view().height))
        root.key(letter)
        root.waiting = function () {
            if (root.col().textLoading) return false
            root.near(letter + " moves one viewport height with clamps", root.view().contentY, root.expectedY)
            root.stable()
            return true
        }
    }
    function sample() {
        var c = root.col(), v = root.view()
        if (!c || !v || c.swap.holding || c.swap.capturing) return
        if (root.watchScroll && !c.isMarkdownRow && root.code() && !root.code().firstScreen) {
            root.badFrames++
            console.log("PVSCROLL MISSING " + root.ops[root.at] + " y=" + v.contentY + " needed=" + JSON.stringify(root.code().needed()))
        }
        if (!c.swap.ready) return
        if (root.restoring && root.name() === root.restoring) {
            root.restoreFrames++
            if (Math.abs(v.contentY - root.restoreY) > 1) root.badFrames++
        }
    }
    function run(op) {
        if (op === "open") {
            Flea.ViewState.changeKey("view", "columns")
            root.pane = paneComponent.createObject(win.contentItem)
            root.keys = Qt.createQmlObject("import QtTest; TestEvent {}", root.pane.listArea)
            root.pane.open(root.fixture)
            root.waitFile("00-long.rs")
        } else if (op === "seams") {
            root.check("column exposes viewport and pageBy", !!root.view() && typeof root.col().pageBy === "function", true)
            if (!root.view() || typeof root.col().pageBy !== "function") { root.finish(); return }
            root.check("code model contains all 132 lines", root.view().count, 132)
            var b = root.bar()
            root.check("long code has one shared vertical bar", root.descendants(root.col()).filter(function (n) { return n.flickable === root.view() && n.vertical === true }).length, 1)
            root.check("long code overflows", !!b && b.overflow, true)
            root.near("knob shows visible share", b.handleLength, b.trackLength * root.view().height / root.view().contentHeight)
            root.check("knob stays hidden at rest", b.shown, false)
        } else if (op.startsWith("capture-")) {
            root.captured = false
            root.pane.grabToImage(function (result) {
                root.check("capture saves " + op, result.saveToFile(root.shots + "/" + op + ".png"), true)
                root.captured = true
            })
            root.waiting = function () { return root.captured }
        } else if (op.endsWith("-click")) {
            root.snapshot()
            var clickPoint = root.col().frameItem.mapToItem(root.pane, root.col().frameItem.width / 2, root.col().frameItem.height / 2)
            driver.mouseClick(root.pane, clickPoint.x, clickPoint.y, Qt.LeftButton, Qt.NoModifier, 1)
            root.stable()
        } else if (op.endsWith("-wheel")) {
            root.snapshot()
            var point = root.col().frameItem.mapToItem(root.pane, root.col().frameItem.width / 2, root.col().frameItem.height / 2)
            driver.mouseWheel(root.pane, point.x, point.y, Qt.NoButton, Qt.NoModifier, 0, -120, 1)
            root.waiting = function () {
                if (root.view().contentY <= root.beforeY || root.col().textLoading) return false
                root.check("wheel scrolls the preview", root.view().contentY > root.beforeY, true)
                root.check("shared knob appears during use", root.bar().shown, true)
                root.stable()
                return true
            }
        } else if (op === "forward" || op === "forward-end") root.page("F")
        else if (op === "back" || op === "back-top") root.page("B")
        else if (op.endsWith("-end") || op.endsWith("-top")) {
            var end = op.endsWith("-end")
            root.waiting = function () {
                var bounds = Scroll.limitsY(root.view()), target = end ? bounds.max : bounds.min
                if (Math.abs(root.view().contentY - target) <= 1 && !root.col().textLoading) return true
                if (!root.col().textLoading) root.key(end ? "F" : "B")
                return false
            }
        } else if (op === "code-save" || op === "markdown-save") {
            root.page("F")
            var saveReady = root.waiting
            root.waiting = function () {
                if (!saveReady()) return false
                root.check("saved place is below the top", root.view().contentY > Scroll.limitsY(root.view()).min, true)
                if (op === "code-save") root.savedCode = root.view().contentY
                else root.savedMarkdown = root.view().contentY
                return true
            }
        } else if (op === "code-next" || op === "markdown-next") {
            root.key("j")
            root.waitFile(op === "code-next" ? "01-other.rs" : "04-other.md")
        } else if (op === "code-return" || op === "markdown-return") {
            root.restoring = op === "code-return" ? "00-long.rs" : "03-long.md"
            root.restoreY = op === "code-return" ? root.savedCode : root.savedMarkdown
            root.restoreFrames = 0
            root.key("k")
            root.waitFile(root.restoring)
        } else if (op === "code-memory" || op === "markdown-memory") {
            root.near("file returns to its saved position", root.view().contentY, root.restoreY)
            root.check("return sampled its first live frame", root.restoreFrames > 0, true)
            root.check("no live frame at top or with missing code", root.badFrames, 0)
            root.restoring = ""
        } else if (op === "short") root.moveTo(2, "02-short.txt")
        else if (op === "short-check") {
            root.check("short file has ten lines", root.view().count, 10)
            root.check("short file draws no knob", root.bar().overflow, false)
            root.page("F")
        } else if (op === "markdown") root.moveTo(3, "03-long.md")
        else if (op === "image") root.moveTo(5, "05-image.png")
        else if (op === "image-check") {
            root.check("image exposes no scrolling viewport", root.view(), null)
            var cursor = root.pane.cursorIndex
            root.key("F"); root.key("B")
            root.check("paging image leaves cursor alone", root.pane.cursorIndex, cursor)
        } else if (op === "code-again") root.moveTo(0, "00-long.rs")
        else if (op === "rewrite") {
            root.page("F")
            rewrite.setText("fn rewritten() {}\n".repeat(10))
        } else if (op === "rewrite-check") {
            root.waiting = function () {
                if (!root.ready("00-long.rs") || root.code().total !== 10) return false
                root.near("changed file starts at top", root.view().contentY, Scroll.limitsY(root.view()).min)
                return true
            }
        } else if (op === "capacity") {
            var m = root.memory()
            for (var i = 0; i < 257; i++) m.store("/fixture/" + i, "same", { y: i })
            root.check("session memory is bounded to 256 paths", m.order.length, 256)
            root.check("oldest path is evicted", m.places["/fixture/0"] === undefined, true)
            root.check("latest path is retained", m.places["/fixture/256"].place.y, 256)
        } else if (op === "empty") root.moveTo(6, "06-empty.txt")
        else if (op === "empty-check") {
            root.check("empty text settles without a restore wait", [root.view().count, root.col().textLoading], [0, false])
        } else if (op === "large") root.moveTo(7, "07-large.md")
        else if (op === "large-check") {
            root.check("oversize Markdown settles without reading", [root.col().markdown.tooLarge, root.col().textLoading], [true, false])
        } else if (op === "list") {
            root.keys.keyClick(Qt.Key_1, Qt.ControlModifier, -1)
            root.waiting = function () { return root.pane.viewMode === "list" }
        } else if (op === "list-check") {
            var before = root.pane.cursorIndex
            root.key("F"); root.key("B")
            root.check("paging List view leaves cursor alone", root.pane.cursorIndex, before)
        } else if (op === "done") root.finish()
    }
    function finish() {
        if (root.finished) return
        root.finished = true
        console.log("PVSCROLL DONE " + root.checks + " checks, " + root.failures + " failed")
        quitter.start()
    }
    function tick() {
        if (Date.now() - root.started > 20000) {
            var c = root.col(), m = root.memory()
            console.log("PVSCROLL STATE " + JSON.stringify({ file: root.name(), loading: c.textLoading,
                pending: m.pendingRestore, ready: m.contentReady, wanted: m.wanted, places: m.places,
                y: root.view() ? root.view().contentY : null,
                markdown: c.markdown ? { loading: c.markdown.loading, ready: c.markdown.contentReady, count: c.markdown.viewport.count } : null }))
            root.check(root.ops[root.at] + " finishes", "timeout", "done"); root.finish(); return
        }
        if (root.waiting !== null) {
            if (!root.waiting()) return
            root.waiting = null
            root.at++
            root.started = Date.now()
            return
        }
        if (root.at >= root.ops.length) { root.finish(); return }
        root.run(root.ops[root.at])
        if (root.waiting === null) { root.at++; root.started = Date.now() }
    }
    FloatingWindow {
        id: win
        implicitWidth: 1200
        implicitHeight: 760
        color: Flea.Theme.color.background
        TestEvent { id: driver }
        Item { id: frameProbe }
    }
    Connections {
        target: frameProbe.Window.window
        function onAfterAnimating() { root.sample() }
    }
    Flea.Backend { id: realBackend }
    FileView { id: rewrite; path: root.fixture + "/00-long.rs"; printErrors: false; blockWrites: true }
    Component { id: paneComponent; Flea.Pane { width: 1200; height: 760; backend: realBackend } }
    Timer { id: quitter; interval: 100; onTriggered: Qt.exit(root.failures > 0 ? 1 : 0) }
    Timer {
        interval: 40
        running: !root.finished
        repeat: true
        onTriggered: {
            if (root.ticking) return
            root.ticking = true
            root.tick()
            root.ticking = false
        }
    }
}
