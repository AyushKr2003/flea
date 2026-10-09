//@ pragma ShellId flea-rename-cost-test
import QtQuick
import QtTest
import Quickshell
import "flea" as Flea

// After a rename ends with Enter or Escape, every cursor key reaches the pane's key handler as it did before, in every view.
ShellRoot {
    id: root
    readonly property string fixture: Quickshell.env("HOME") + "/fixture"
    readonly property var pane: body.currentPane
    readonly property int stallTicks: 200
    // Each case renames one row through r and typed text; far names sort past the held window, Escape abandons.
    readonly property var cases: [
        { view: "columns", target: "f020.txt", typed: "zc", end: Qt.Key_Return },
        { view: "list", target: "f021.txt", typed: "zl", end: Qt.Key_Return },
        { view: "grid", target: "f022.txt", typed: "zg", end: Qt.Key_Return },
        { view: "columns", target: "f023.txt", typed: "f023n", end: Qt.Key_Return },
        { view: "columns", target: "f024.txt", typed: "x", end: Qt.Key_Escape }
    ]
    // The arrows and the letters the report names, one tick apart.
    readonly property var keys: [
        { key: Qt.Key_Up }, { key: Qt.Key_Up }, { key: Qt.Key_Up }, { key: Qt.Key_Up },
        { key: Qt.Key_Down }, { key: Qt.Key_Down }, { key: Qt.Key_Down }, { key: Qt.Key_Down },
        { text: "k" }, { text: "k" }, { text: "k" }, { text: "k" },
        { text: "j" }, { text: "j" }, { text: "j" }, { text: "j" }
    ]
    readonly property int idleTicks: 20
    // An armed frame hook draws on every vsync, so an idle second past half of one is a leak, below it noise.
    readonly property int idleFloor: 30
    property int caseIndex: 0
    property int stage: 0
    property int stageTicks: 0
    property int stepIndex: 0
    property int waitTicks: 0
    property int checks: 0
    property var failures: []
    property var before: null
    property var stepLog: []
    // Counters the window and the pane feed while a phase is measured.
    property int frames: 0
    property int selectionBumps: 0
    property int rowsReplies: 0
    property int inputs: 0

    function check(cond, label) {
        root.checks++
        if (!cond) {
            root.failures.push(label)
            console.log("RENAMECOST FAIL " + label)
        }
    }
    function ready() { return !pane.listInFlight && pane.path === fixture && pane.listingState === "ready" }
    function settled() {
        return root.ready() && pane.renamingIndex < 0 && !pane.renamePending && pane.wire.anchor === null
    }
    function indexOfName(name) {
        for (var i = 0; i < pane.total; i++)
            if (pane.rowFor(i) && String(pane.rowFor(i).n) === name) return i
        return -1
    }
    // Every object under the window: children and resources, so Timers and Connections count too.
    function census() {
        var out = { timers: 0, animations: 0, editors: 0 }
        var stack = [body.Window.window.contentItem]
        while (stack.length > 0) {
            var o = stack.pop()
            if (o === null || o === undefined) continue
            if (o.running === true && o.interval !== undefined && o.triggeredOnStart !== undefined) out.timers++
            if (o.running === true && o.loops !== undefined && o.alwaysRunToEnd !== undefined) out.animations++
            if (typeof o.queueDeparture === "function" && typeof o.ownsEdit === "function") out.editors++
            var kids = o.children !== undefined ? o.children : []
            for (var i = 0; i < kids.length; i++) stack.push(kids[i])
            var res = o.resources !== undefined ? o.resources : []
            for (var j = 0; j < res.length; j++) stack.push(res[j])
        }
        return out
    }
    function focusChain() {
        var out = []
        for (var o = body.Window.window.activeFocusItem; o && out.length < 4; o = o.parent) out.push(String(o).split("_QML")[0].split("(")[0])
        return out.join(" < ")
    }
    function resetCounters() {
        root.frames = 0
        root.selectionBumps = 0
        root.rowsReplies = 0
        root.inputs = 0
    }
    function counters() {
        return { frames: root.frames, selection: root.selectionBumps, rows: root.rowsReplies, inputs: root.inputs }
    }
    function line(tag, value) { console.log("RENAMECOST " + tag + " " + JSON.stringify(value)) }
    function press(step) {
        if (step.text !== undefined) driver.keyClickChar(step.text, Qt.NoModifier, -1)
        else driver.keyClick(step.key, Qt.NoModifier, -1)
    }

    // A phase: idle frames over one second, then every key one tick apart, then a census.
    function phase(tag) {
        if (root.waitTicks === 0) {
            root.resetCounters()
            root.waitTicks = 1
            return false
        }
        if (root.waitTicks <= root.idleTicks) {
            root.waitTicks++
            return false
        }
        if (root.waitTicks === root.idleTicks + 1) {
            root.stepLog = [{ idle: root.counters(), listFocus: pane.listArea.activeFocus, focus: root.focusChain() }]
            root.resetCounters()
            root.stepIndex = 0
            root.waitTicks++
        }
        if (root.stepIndex > 0) {
            var row = root.counters()
            row.cursor = pane.cursorIndex
            root.stepLog.push(row)
            root.resetCounters()
        }
        if (root.stepIndex < root.keys.length) {
            root.press(root.keys[root.stepIndex])
            root.stepIndex++
            return false
        }
        var head = root.stepLog[0]
        var steps = root.stepLog.slice(1)
        var sum = { frames: 0, selection: 0, rows: 0, inputs: 0 }
        var missed = 0
        for (var k = 0; k < steps.length; k++) {
            for (var name in sum) sum[name] += steps[k][name]
            if (steps[k].inputs !== 1) missed++
        }
        var result = { idleFrames: head.idle.frames, listFocus: head.listFocus, focus: head.focus, keys: sum, missed: missed,
                       census: root.census(), anchor: pane.wire.anchor !== null, follows: pane.selection.follows(),
                       trace: steps.map(function (s) { return s.cursor + "/" + s.inputs }).join(" ") }
        root.line(tag, result)
        root.waitTicks = 0
        return result
    }

    function advance() {
        var c = root.cases[root.caseIndex]
        var tag = c.view + " " + c.target + (c.end === Qt.Key_Escape ? " escape" : " enter")
        if (root.stage === 0) {
            if (Flea.ViewState.state.view !== c.view) { pane.chooseView(c.view); return false }
            if (!root.ready()) return false
            pane.listArea.forceActiveFocus()
            pane.clearSelection()
            // A row outside the held window reads as missing, so the cursor goes home until the window holds it.
            if (root.indexOfName(c.target) < 0) { pane.setCursor(0); return false }
            pane.setCursor(root.indexOfName(c.target))
            root.stage = 1
            return true
        }
        if (root.stage === 1) {
            var measured = root.phase(tag + " before")
            if (measured === false) return false
            root.before = measured
            pane.setCursor(root.indexOfName(c.target))
            root.stage = 2
            return true
        }
        if (root.stage === 2) {
            if (pane.cursorIndex !== root.indexOfName(c.target)) return false
            driver.keyClickChar("r", Qt.NoModifier, -1)
            root.stage = 3
            return true
        }
        if (root.stage === 3) {
            var editor = pane.renameEditor()
            if (!editor || !editor.editorField || !editor.editorField.inputItem.activeFocus) return false
            for (var i = 0; i < c.typed.length; i++) driver.keyClickChar(c.typed.charAt(i), Qt.NoModifier, -1)
            driver.keyClick(c.end, Qt.NoModifier, -1)
            root.waitTicks = 0
            root.stage = 4
            return true
        }
        if (root.stage === 4) {
            var landed = c.end === Qt.Key_Escape ? c.target : c.typed + ".txt"
            if (!root.settled() || root.indexOfName(landed) < 0) return false
            // Ten more ticks let a late window reply or a queued layout land before the idle second starts.
            if (++root.waitTicks < 10) return false
            root.waitTicks = 0
            root.stage = 5
            return true
        }
        if (root.stage === 5) {
            var after = root.phase(tag + " after")
            if (after === false) return false
            root.compare(tag, root.before, after)
            root.caseIndex++
            root.stage = 0
            return true
        }
        return true
    }

    // A landed row's selection follows the cursor by design, so selection bumps and window replies are logged, not checked.
    function compare(tag, a, b) {
        root.check(a.listFocus && a.missed === 0, tag + " before the rename " + a.missed + " keys missed the key handler, list focus " + a.listFocus)
        root.check(b.listFocus, tag + " the list area lost the keyboard to " + b.focus)
        root.check(b.missed === 0, tag + " " + b.missed + " of " + root.keys.length + " keys never reached the key handler: " + b.trace)
        root.check(b.idleFrames <= Math.max(a.idleFrames, root.idleFloor), tag + " idle frames " + a.idleFrames + " before, " + b.idleFrames + " after")
        root.check(b.census.timers <= a.census.timers, tag + " running timers " + a.census.timers + " before, " + b.census.timers + " after")
        root.check(b.census.animations <= a.census.animations, tag + " running animations " + a.census.animations + " before, " + b.census.animations + " after")
        root.check(b.census.editors === 0, tag + " " + b.census.editors + " rename editors live after the rename")
        root.check(!b.anchor, tag + " the rename anchor still stands")
    }

    function report() {
        stepper.running = false
        root.check(root.caseIndex === root.cases.length, "ran " + root.caseIndex + " of " + root.cases.length + " cases")
        console.log("RENAMECOST DONE checks=" + root.checks + " failed=" + root.failures.length)
        Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }

    FloatingWindow {
        id: window
        implicitWidth: 1000
        implicitHeight: 650
        Flea.WindowBody { id: body; host: window }
        Item { anchors.fill: parent; TestEvent { id: driver } }
    }

    Connections {
        target: body.Window.window
        function onAfterAnimating() { root.frames++ }
    }
    Connections {
        target: root.pane
        function onSelectionVersionChanged() { root.selectionBumps++ }
        function onInputAtChanged() { root.inputs++ }
    }
    Connections {
        target: root.pane ? root.pane.backend : null
        function onRows() { root.rowsReplies++ }
    }

    Timer {
        id: stepper
        interval: 50
        running: true
        repeat: true
        onTriggered: {
            if (root.caseIndex >= root.cases.length) {
                root.report()
                return
            }
            var before = root.stage
            if (root.advance() === true) {
                root.stageTicks = 0
                return
            }
            root.stageTicks++
            if (root.stageTicks > root.stallTicks) {
                root.failures.push("stage " + before + " of case " + root.caseIndex + " never completed")
                console.log("RENAMECOST FAIL stalled at stage " + before + " case " + root.caseIndex + " index=" + pane.renamingIndex
                    + " pending=" + pane.renamePending + " anchor=" + (pane.wire.anchor !== null) + " cursor=" + pane.cursorIndex
                    + " view=" + Flea.ViewState.state.view)
                root.report()
            }
        }
    }
}
