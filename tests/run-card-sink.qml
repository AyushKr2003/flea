//@ pragma ShellId flea-run-card-sink-test
import QtQuick
import Quickshell
import Quickshell.Io
import QtTest
import "flea" as Flea

// tests/run-card-sink.sh's harness: the real ui/RunCard.qml over a stub pane, offscreen.
ShellRoot {
    id: shell

    property int checks: 0
    property var failures: []
    property int ticks: 0
    property int scene: -1
    property bool done: false
    readonly property int settleTicks: 3
    readonly property int sceneTickBound: 50

    property var messages: []
    property var focused: []
    property var made: []
    property var shownOld: []
    property var shownFor: []

    function log(line) { console.log("RUNCARD " + line) }
    function quit() { Quickshell.execDetached(["kill", String(Quickshell.processId)]) }
    function check(name, actual, expected) {
        shell.checks++
        if (JSON.stringify(actual) === JSON.stringify(expected)) return
        shell.failures.push(name)
        shell.log("FAIL " + name + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected))
    }
    function finitePositive(v) { return typeof v === "number" && isFinite(v) && v > 0 }

    // The asking pane, recording every route the card takes back to it.
    QtObject {
        id: stubPane
        function message(text, err) { shell.messages.push(text) }
        function forceActiveFocus() { shell.focused.push("pane") }
        function makeExecutable(paths, script) { shell.made.push([(paths || []).join("|"), script]) }
        function showOpenWith(path) { if (path === undefined) shell.shownOld.push("old"); else shell.shownFor.push(path) }
    }
    // A second pane, so the open-text route proves which pane it took.
    QtObject {
        id: stubPane2
        function message(text, err) { shell.messages.push(text) }
        function forceActiveFocus() { shell.focused.push("pane2") }
    }

    FloatingWindow {
        implicitWidth: 1000
        implicitHeight: 700
        color: "#303030"
        Item {
            id: holder
            anchors.fill: parent
            Flea.RunCard { id: card }
        }
        TestEvent { id: driver }
    }

    function scriptInfo() {
        return { path: "/d/tool.sh", kind: "script", size: 9420, makeExecutable: false, hasHandler: false,
                 dev: "8", ino: "9", mtimeS: "11", mtimeNs: "12", target: "/d/tool.sh",
                 raw: '{"ask":"run","kind":"script","size":9420,"makeExecutable":false,"hasHandler":false,"dev":"8","ino":"9","mtimeS":"11","mtimeNs":"12","target":"/d/tool.sh"}' }
    }
    function appInfo() {
        return { path: "/d/app.AppImage", kind: "appimage", size: 96, makeExecutable: false, hasHandler: true,
                 dev: "8", ino: "9", mtimeS: "11", mtimeNs: "12", target: "/d/app.AppImage",
                 raw: '{"ask":"run","kind":"appimage","size":96,"makeExecutable":false,"hasHandler":true,"dev":"8","ino":"9","mtimeS":"11","mtimeNs":"12","target":"/d/app.AppImage"}' }
    }
    function linkInfo() {
        return { path: "/link.sh", kind: "script", size: 8, makeExecutable: false, hasHandler: false,
                 dev: "8", ino: "9", mtimeS: "11", mtimeNs: "12", target: "/real/tool.sh",
                 raw: '{"ask":"run","kind":"script","size":8,"makeExecutable":false,"hasHandler":false,"dev":"8","ino":"9","mtimeS":"11","mtimeNs":"12","target":"/real/tool.sh"}' }
    }
    function resetLogs() {
        shell.messages = []
        shell.focused = []
        shell.made = []
        shell.shownOld = []
        shell.shownFor = []
    }

    function sizeScene() {
        card.open(shell.scriptInfo(), stubPane)
    }
    function runSize() {
        shell.check("size:width-finite-positive", shell.finitePositive(card.cardItem.width), true)
        shell.check("size:height-finite-positive", shell.finitePositive(card.cardItem.height), true)
    }
    function defaultScene() {
        card.open(shell.appInfo(), stubPane)
    }
    function runDefault() {
        shell.check("default:handler-first", card.focusName, "handler")
    }
    function titleScene() {
        card.open(shell.linkInfo(), stubPane)
    }
    function runTitle() {
        shell.check("title:names-resolved-target", card.titleText, "tool.sh is a program")
        // The shared DialogHeader draws the title and ends in its hairline rule, as the board does.
        var header = shell.headerIn(card.cardItem)
        var rule = header ? header.children[header.children.length - 1] : null
        shell.check("title:shared-header-with-its-rule", [header ? header.text : "", rule ? rule.y + rule.height : -1, rule ? rule.height > 0 : false],
            ["tool.sh is a program", header ? header.height : 0, true])
    }
    function headerIn(item) {
        if (item.boardAir !== undefined && item.truncated !== undefined) return item
        for (var i = 0; i < item.children.length; i++) {
            var hit = shell.headerIn(item.children[i])
            if (hit) return hit
        }
        return null
    }
    // A file name carrying markup is drawn as the characters it is, R4: the card never names what runs in another voice.
    readonly property string markupTitle: "<u>x.sh is a program"
    function markupScene() {
        var info = shell.scriptInfo()
        info.path = info.target = "/d/<u>x.sh"
        info.raw = info.raw.replace('"target":"/d/tool.sh"', '"target":"/d/<u>x.sh"')
        card.open(info, stubPane)
    }
    function runMarkup() {
        var label = shell.textShowing(card.cardItem, shell.markupTitle)
        shell.check("title:markup-name-is-plain-text", label !== null && label.textFormat === Text.PlainText, true)
    }
    // The Text item drawing exactly `needle` inside `item`, found by walking the card's own tree.
    function textShowing(item, needle) {
        if (item.text === needle && item.textFormat !== undefined) return item
        for (var i = 0; i < item.children.length; i++) {
            var hit = shell.textShowing(item.children[i], needle)
            if (hit) return hit
        }
        return null
    }
    // A click on the shared DialogScrim, off the card, dismisses it.
    function scrimScene() {
        card.open(shell.scriptInfo(), stubPane)
    }
    function runScrim() {
        driver.mouseClick(card.cardItem, card.cardItem.width / 2, 2, Qt.LeftButton, Qt.NoModifier, 0)
        shell.check("scrim:click-on-the-card-keeps-it", card.opened, true)
        driver.mouseClick(holder, 5, 5, Qt.LeftButton, Qt.NoModifier, 0)
        shell.check("scrim:click-off-the-card-closes", card.opened, false)
    }
    function closeScene() {
        shell.resetLogs()
        card.open(shell.scriptInfo(), stubPane)
    }
    function runClose() {
        card.close()
        shell.check("focus:close-returns", shell.focused, ["pane"])
        shell.check("focus:close-hides", card.opened, false)
    }
    function cancelScene() {
        shell.resetLogs()
        card.open(shell.scriptInfo(), stubPane)
    }
    function runCancel() {
        card.choose("cancel")
        shell.check("focus:cancel-returns", shell.focused, ["pane"])
        shell.check("focus:cancel-hides", card.opened, false)
    }
    function repeatScene() {
        shell.resetLogs()
        card.open(shell.scriptInfo(), stubPane)
    }
    function runRepeat() {
        if (typeof card.keyPressed !== "function") {
            shell.check("autorepeat:guard-present", "missing", "keyPressed")
            return
        }
        card.keyPressed(Qt.Key_Return, true, Qt.NoModifier)
        shell.check("autorepeat:held-does-not-run", card.runCurrent + "|" + card.opened, "|true")
        card.keyPressed(Qt.Key_Return, false, Qt.NoModifier)
        shell.check("autorepeat:press-runs", card.runCurrent, "/d/tool.sh")
    }
    function textScene() {
        shell.resetLogs()
        card.close()
    }
    function runText() {
        card.openText("/x", stubPane2)
        shell.check("opentext:routes-pane", card.pane === stubPane2, true)
    }
    function routesScene() {
        shell.resetLogs()
        card.open(shell.scriptInfo(), stubPane)
    }
    function runRoutes() {
        card.choose("make")
        shell.check("routes:make-names-card-path", shell.made, [[("/d/tool.sh"), true]])
        card.open(shell.appInfo(), stubPane)
        card.choose("handler")
        shell.check("routes:handler-names-card-path", shell.shownFor, ["/d/app.AppImage"])
        shell.check("routes:handler-skips-cursor", shell.shownOld, [])
    }
    function linkScene() {
        shell.resetLogs()
        card.open(shell.linkInfo(), stubPane)
    }
    function runLink() {
        card.choose("make")
        shell.check("routes:link-make-names-listed-path", shell.made, [[("/link.sh"), true]])
        card.open(shell.linkInfo(), stubPane)
        card.choose("handler")
        shell.check("routes:link-handler-names-listed-path", shell.shownFor, ["/link.sh"])
    }

    readonly property var scenes: [
        { setup: shell.sizeScene, ready: function () { return card.buttonItem("terminal") !== null }, run: shell.runSize },
        { setup: shell.defaultScene, ready: function () { return card.buttonItem("handler") !== null }, run: shell.runDefault },
        { setup: shell.titleScene, ready: function () { return card.opened }, run: shell.runTitle },
        { setup: shell.markupScene, ready: function () { return card.titleText === shell.markupTitle }, run: shell.runMarkup },
        { setup: shell.closeScene, ready: function () { return card.opened }, run: shell.runClose },
        { setup: shell.cancelScene, ready: function () { return card.opened }, run: shell.runCancel },
        { setup: shell.scrimScene, ready: function () { return card.opened }, run: shell.runScrim },
        { setup: shell.repeatScene, ready: function () { return card.opened }, run: shell.runRepeat },
        { setup: shell.textScene, ready: function () { return !card.opened }, run: shell.runText },
        { setup: shell.routesScene, ready: function () { return card.buttonItem("terminal") !== null }, run: shell.runRoutes },
        { setup: shell.linkScene, ready: function () { return card.opened }, run: shell.runLink }
    ]

    Timer {
        id: ticker
        interval: 100
        repeat: true
        running: true
        onTriggered: shell.advance()
    }

    function advance() {
        if (shell.done) return
        shell.ticks++
        if (shell.scene < 0) {
            if (shell.ticks < shell.settleTicks) return
            shell.scene = 0
            shell.scenes[0].setup()
            shell.ticks = 0
            return
        }
        var current = shell.scenes[shell.scene]
        if (!shell.ready(current.ready()) && shell.ticks <= shell.sceneTickBound) return
        current.run()
        shell.scene++
        shell.ticks = 0
        if (shell.scene >= shell.scenes.length) {
            shell.report()
            return
        }
        shell.scenes[shell.scene].setup()
    }
    function ready(item) { return item !== null && item !== undefined && item !== false }

    function report() {
        ticker.running = false
        shell.done = true
        if (shell.failures.length === 0)
            shell.log("PASS " + shell.checks + " checks")
        shell.log("DONE failures=" + shell.failures.length)
        shell.quit()
    }
}
