//@ pragma ShellId flea-navframe-test
import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import "flea" as Flea
import "flea/js/Swap.js" as Swap

// Navframe: Enter and Back in one view draw no frame between the key and the landing, and every input the listing gate
// refuses while a listing is out is still refused. The backend is paused while the reply is out, so a frame the key
// asked for has 80 ms to be drawn, inside the swap's 150 ms hold (ui/js/Swap.js HOLD_MS), before the reply can land.
ShellRoot {
    id: root
    readonly property string fixture: Quickshell.env("FLEA_NAVFRAME_DIR") || ""
    readonly property string pidFile: Quickshell.env("FLEA_NAVFRAME_PID") || ""
    readonly property string viewName: Quickshell.env("FLEA_NAVFRAME_VIEW") || "list"
    readonly property int entries: Number(Quickshell.env("FLEA_NAVFRAME_ENTRIES") || "0")
    property int checks: 0
    property int failures: 0
    property int frames: 0
    property int loadingNotes: 0
    property var pane: null
    // The steps left, and what the current one waits on: a condition, a time, or frames to stop.
    property var steps: []
    property var waitFor: null
    property double waitUntil: 0
    property double deadline: 0
    property bool quietNeeded: false
    property int quietMark: -1
    property double quietSince: 0
    property int keyFrames: 0
    property real wheelFrom: 0

    function check(name, actual, expected) {
        checks += 1
        if (actual !== expected) {
            failures += 1
            console.log("NAVFRAME FAIL " + viewName + " " + name + " got=" + actual + " expected=" + expected)
        } else console.log("NAVFRAME ok " + viewName + " " + name)
    }
    function finish() {
        console.log("NAVFRAME DONE " + viewName + " " + checks + " checks, " + failures + " failed")
        Qt.quit()
    }
    function view() { return root.viewName === "columns" ? pane.columnsArea.activeColumn().viewport : pane.listArea }
    // The centre of a visible entry, in the pane's own coordinates.
    function entryPoint(index) {
        var item = root.view().itemAtIndex(index)
        return item ? item.mapToItem(pane, item.width / 2, item.height / 2) : Qt.point(-1, -1)
    }
    function landed(path) {
        return function () {
            return !pane.listInFlight && !pane.swap.holding && pane.path === path
                && (path === fixture + "/e" ? pane.listingState === "empty" : pane.total > 0)
        }
    }
    function signalBackend(name) {
        signaller.command = ["/bin/sh", "-c", "kill -" + name + " \"$(cat \"$0\")\"", root.pidFile]
        signaller.done = false
        signaller.running = true
        root.waitFor = function () { return signaller.done }
    }
    function quiet() { root.quietNeeded = true; root.quietMark = -1 }
    // One measured navigation: pause the backend, press the key, let 80 ms pass, read the frames, resume, land.
    function measured(name, key, path) {
        return [
            quiet,
            function () { signalBackend("STOP") },
            function () {
                root.keyFrames = root.frames
                console.log("NAVFRAME KEY " + viewName + " " + name)
                keys.keyClick(key, Qt.NoModifier, -1)
                check(name + ": the listing is out after the key", pane.listInFlight, true)
                root.waitUntil = Date.now() + 80
            },
            function () {
                console.log("NAVFRAME HELD " + viewName + " " + name)
                check(name + ": the reply is still out after 80 ms", pane.listInFlight, true)
                check(name + ": frames drawn between the key and the landing", root.frames - root.keyFrames, 0)
                signalBackend("CONT")
            },
            function () { root.waitFor = landed(path) }
        ]
    }
    // While a listing is out: a press, a band drag and a wheel notch over the rows land on nothing, hover still reaches a row.
    function refusedWhileOut() {
        var flick = root.view()
        var row = entryPoint(3), below = entryPoint(5)
        var cursor = pane.cursorIndex, contentY = flick.contentY, notes = root.loadingNotes, selected = pane.selectionCount()
        keys.mouseClick(pane, row.x, row.y, Qt.LeftButton, Qt.NoModifier, -1)
        check("out: a press over a row shows the loading note", root.loadingNotes, notes + 1)
        check("out: a press over a row moves no cursor", pane.cursorIndex, cursor)
        check("out: a press over a row changes no selection", pane.selectionCount(), selected)
        keys.mousePress(pane, below.x, below.y, Qt.LeftButton, Qt.NoModifier, -1)
        keys.mouseMove(pane, below.x + 40, row.y, -1, Qt.LeftButton, Qt.NoModifier)
        check("out: a drag over the rows starts no band", pane.selectionBand, null)
        keys.mouseRelease(pane, below.x + 40, row.y, Qt.LeftButton, Qt.NoModifier, -1)
        check("out: a band drag changes no selection", pane.selectionCount(), selected)
        keys.mouseWheel(pane, row.x, row.y, Qt.NoButton, Qt.NoModifier, 0, -120, -1)
        check("out: a wheel notch scrolls nothing", flick.contentY, contentY)
        keys.mouseMove(pane, row.x, row.y + 2, -1, Qt.NoButton, Qt.NoModifier)
        check("out: hover still reaches the row", flick.itemAtIndex(3).hovered, true)
    }
    // Once landed the same inputs reach the rows: a band from empty ground, a press on a row.
    function passedInA() {
        var row = entryPoint(1), last = entryPoint(2)
        var ground = Qt.point(last.x, last.y + 3 * root.view().itemAtIndex(2).height)
        keys.mousePress(pane, ground.x, ground.y, Qt.LeftButton, Qt.NoModifier, -1)
        keys.mouseMove(pane, ground.x + 30, row.y, -1, Qt.LeftButton, Qt.NoModifier)
        check("landed: a drag from empty ground starts a band", pane.selectionBand !== null, true)
        keys.mouseRelease(pane, ground.x + 30, row.y, Qt.LeftButton, Qt.NoModifier, -1)
        check("landed: the band ends on release", pane.selectionBand, null)
        keys.mouseClick(pane, row.x, row.y, Qt.LeftButton, Qt.NoModifier, -1)
        check("landed: a press on a row moves the cursor there", pane.cursorIndex, 1)
    }
    function wheelPasses() {
        var flick = root.view(), row = entryPoint(3)
        root.wheelFrom = flick.contentY
        keys.mouseWheel(pane, row.x, row.y, Qt.NoButton, Qt.NoModifier, 0, -120, -1)
        root.waitUntil = Date.now() + 400
        root.waitFor = function () { return flick.contentY > root.wheelFrom }
    }
    function bandRefusedOnEmpty() {
        var flick = root.view(), ground = flick.mapToItem(pane, flick.width / 2, flick.height / 2)
        keys.mousePress(pane, ground.x, ground.y, Qt.LeftButton, Qt.NoModifier, -1)
        keys.mouseMove(pane, ground.x + 60, ground.y + 60, -1, Qt.LeftButton, Qt.NoModifier)
        check("empty: a drag on an empty listing starts no band", pane.selectionBand, null)
        keys.mouseRelease(pane, ground.x + 60, ground.y + 60, Qt.LeftButton, Qt.NoModifier, -1)
        check("empty: and shows no loading note", root.loadingNotes, 0)
    }

    FloatingWindow {
        id: win
        implicitWidth: 1200
        implicitHeight: 800
        Flea.Backend { id: probeBackend }
        Component {
            id: paneComponent
            Flea.Pane {
                width: 1200
                height: 800
                backend: probeBackend
                onMessage: function (text) { if (text === Swap.LOADING) root.loadingNotes += 1 }
            }
        }
        TestEvent { id: keys }
        Item {
            id: frameProbe
            Connections {
                target: frameProbe.Window.window
                function onFrameSwapped() { root.frames += 1 }
            }
        }
    }
    Process {
        id: signaller
        property bool done: false
        onExited: done = true
    }

    Component.onCompleted: {
        var a = fixture + "/a"
        steps = [
            function () { pane = paneComponent.createObject(win.contentItem); pane.open(fixture); root.waitFor = landed(fixture) },
            function () {
                check("the fixture is listed whole", pane.total, entries)
                check("the view is " + viewName, pane.viewMode, viewName)
                pane.listArea.forceActiveFocus()
            }
        ].concat(measured("enter", Qt.Key_Return, a), measured("back", Qt.Key_Backspace, fixture), [
            quiet,
            function () { signalBackend("STOP") },
            function () {
                keys.keyClick(Qt.Key_Return, Qt.NoModifier, -1)
                refusedWhileOut()
                signalBackend("CONT")
            },
            function () { root.waitFor = landed(a) },
            function () { check("out: the notes came only from the refused presses", root.loadingNotes, 2); passedInA() },
            function () { root.loadingNotes = 0; keys.keyClick(Qt.Key_Backspace, Qt.NoModifier, -1); root.waitFor = landed(fixture) },
            wheelPasses,
            function () { check("landed: a wheel notch scrolls the rows", view().contentY > root.wheelFrom, true) },
            function () { pane.open(fixture + "/e"); root.waitFor = landed(fixture + "/e") },
            function () { check("empty: the listing is empty", pane.listingState, "empty"); bandRefusedOnEmpty(); finish() }
        ])
        deadline = Date.now() + 25000
    }

    Timer {
        interval: 10
        running: true
        repeat: true
        onTriggered: {
            if (Date.now() > root.deadline) {
                console.log("NAVFRAME FAIL " + root.viewName + " stalled with " + root.steps.length + " steps left")
                root.finish()
                return
            }
            // Quiet: 300 ms with no presented frame, so a measured key starts from rest.
            if (root.quietNeeded) {
                if (root.quietMark !== root.frames) { root.quietMark = root.frames; root.quietSince = Date.now(); return }
                if (Date.now() - root.quietSince < 300) return
                root.quietNeeded = false
            }
            // A condition waits until it holds or its optional time runs out; a bare time is a delay.
            if (root.waitFor ? !root.waitFor() && (root.waitUntil === 0 || Date.now() < root.waitUntil)
                             : Date.now() < root.waitUntil) return
            root.waitFor = null
            root.waitUntil = 0
            if (root.steps.length === 0) return
            var step = root.steps[0]
            root.steps = root.steps.slice(1)
            try {
                step()
            } catch (error) {
                console.log("NAVFRAME FAIL " + root.viewName + " a step threw: " + error)
                root.finish()
            }
        }
    }
}
