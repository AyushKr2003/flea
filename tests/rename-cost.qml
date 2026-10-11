//@ pragma ShellId flea-rename-cost-test
import QtQuick
import QtTest
import Quickshell
import "flea" as Flea

// After a rename ends with Enter, Escape, the path field taking focus or a view switch, every cursor key reaches the pane's key handler as it did before, in every view, and costs no more work than it did before.
ShellRoot {
    id: root
    readonly property string fixture: Quickshell.env("HOME") + "/fixture"
    readonly property var pane: body.currentPane
    readonly property int stallTicks: 200
    // Each case renames one row through r and typed text, in each view and for each end: a name that stays in place, a name past the held window (far), and Escape.
    // Far cases measure their before phase on the last row, where the renamed row lands. End 0 opens the path field, and legs switch views.
    readonly property var cases: [
        { view: "columns", target: "f020.txt", typed: "zc", end: Qt.Key_Return, far: true },
        { view: "columns", target: "f023.txt", typed: "f023n", end: Qt.Key_Return },
        { view: "columns", target: "f024.txt", typed: "x", end: Qt.Key_Escape },
        { view: "list", target: "f021.txt", typed: "zl", end: Qt.Key_Return, far: true },
        { view: "list", target: "f027.txt", typed: "f027n", end: Qt.Key_Return },
        { view: "list", target: "f028.txt", typed: "x", end: Qt.Key_Escape },
        { view: "grid", target: "f022.txt", typed: "zg", end: Qt.Key_Return, far: true },
        { view: "grid", target: "f029.txt", typed: "f029n", end: Qt.Key_Return },
        { view: "grid", target: "f030.txt", typed: "x", end: Qt.Key_Escape },
        { view: "dual", target: "f031.txt", typed: "zd", end: Qt.Key_Return, far: true },
        { view: "dual", target: "f032.txt", typed: "f032n", end: Qt.Key_Return },
        { view: "dual", target: "f033.txt", typed: "x", end: Qt.Key_Escape },
        { view: "columns", target: "f025.txt", typed: "y", end: 0 },
        { view: "columns", target: "f026.txt", typed: "v", legs: ["list", "columns", "list"] },
        { view: "list", control: true }
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
    readonly property int frameSlack: 4
    readonly property int readsPerBump: 5
    property int caseIndex: 0
    property int stage: 0
    property int stageTicks: 0
    property int stepIndex: 0
    property int legIndex: 0
    property int legStart: -1
    property int waitTicks: 0
    property int checks: 0
    property var failures: []
    property var before: null
    property var stepLog: []
    // The delegates alive at the last key, each with the view position it draws.
    property var cells: ({ items: [], at: [] })
    // Counters the window and the pane feed while a phase is measured.
    property int frames: 0
    property int selectionBumps: 0
    property int rowsReplies: 0
    property int inputs: 0
    property int cursorRowEvals: 0
    // Field reads of held rows, in an object never reassigned: a getter that wrote a property would loop every binding that reads a row.
    readonly property var tally: ({ rowReads: 0 })

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
    function chrome() {
        for (var i = 0; i < body.children.length; i++)
            if (String(body.children[i]).indexOf("ChromeBar_") === 0) return body.children[i]
        return null
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
        root.cursorRowEvals = 0
        root.tally.rowReads = 0
    }
    function counters() {
        return { frames: root.frames, selection: root.selectionBumps, rows: root.rowsReplies, inputs: root.inputs,
                 cursorRow: root.cursorRowEvals, rowReads: root.tally.rowReads }
    }
    // rowFor is a QML method and cannot be wrapped, so every field a held row gives out is counted instead; a reply brings new rows, armed on the next snapshot.
    function armRows() {
        for (var i = 0; i < pane.rows.length; i++)
            for (var field in pane.rows[i])
                root.armField(pane.rows[i], field)
    }
    function armField(row, field) {
        var desc = Object.getOwnPropertyDescriptor(row, field)
        if (desc.get !== undefined) return
        var value = row[field]
        Object.defineProperty(row, field, { get: function () { root.tally.rowReads++; return value }, enumerable: true, configurable: true })
    }
    // Every row delegate under the window, pooled ones included: List's Row, the Grid's tile and Columns' ColumnRow carry listingIndex.
    function cellSnap() {
        var out = { items: [], at: [] }
        var stack = [body.Window.window.contentItem]
        while (stack.length > 0) {
            var o = stack.pop()
            if (o === null || o === undefined) continue
            if (o.listingIndex !== undefined) {
                out.items.push(o)
                out.at.push(o.index)
                continue
            }
            var kids = o.children !== undefined ? o.children : []
            for (var i = 0; i < kids.length; i++) stack.push(kids[i])
        }
        return out
    }
    // Delegates built since the last snapshot, destroyed since, and kept ones that now draw another position (a reuse rebinds them).
    function cellDelta(a, b) {
        var out = { built: 0, destroyed: 0, rebound: 0 }
        for (var i = 0; i < b.items.length; i++) {
            var was = a.items.indexOf(b.items[i])
            if (was < 0) out.built++
            else if (a.at[was] !== b.at[i]) out.rebound++
        }
        for (var j = 0; j < a.items.length; j++)
            if (b.items.indexOf(a.items[j]) < 0) out.destroyed++
        return out
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
            // Sampled at rest, so a timer a key starts for a few milliseconds is not counted as a leak.
            root.stepLog = [{ idle: root.counters(), listFocus: pane.listArea.activeFocus, focus: root.focusChain(), census: root.census() }]
            root.armRows()
            root.resetCounters()
            root.cells = root.cellSnap()
            root.stepIndex = 0
            root.waitTicks++
        }
        if (root.stepIndex > 0) {
            var row = root.counters()
            row.cursor = pane.cursorIndex
            root.armRows()
            var now = root.cellSnap()
            var delta = root.cellDelta(root.cells, now)
            row.built = delta.built
            row.destroyed = delta.destroyed
            row.rebound = delta.rebound
            root.cells = now
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
        var sum = { frames: 0, selection: 0, rows: 0, inputs: 0, cursorRow: 0, rowReads: 0, built: 0, destroyed: 0, rebound: 0 }
        var missed = 0
        for (var k = 0; k < steps.length; k++) {
            for (var name in sum) sum[name] += steps[k][name]
            if (steps[k].inputs !== 1) missed++
        }
        var result = { idleFrames: head.idle.frames, listFocus: head.listFocus, focus: head.focus, keys: sum, missed: missed, delegates: root.cells.items.length,
                       census: head.census, anchor: pane.wire.anchor !== null, follows: pane.selection.follows(),
                       trace: steps.map(function (s) { return s.cursor + "/" + s.inputs }).join(" ") }
        root.line(tag, result)
        root.waitTicks = 0
        return result
    }

    function advance() {
        var c = root.cases[root.caseIndex]
        var tag = c.view + " " + c.target + (c.legs ? " switch" : c.end === Qt.Key_Escape ? " escape" : c.end === 0 ? " away" : c.far ? " enter far" : " enter")
        if (c.control) return root.control(c)
        if (root.stage === 0) {
            if (Flea.ViewState.state.view !== c.view) { pane.chooseView(c.view); return false }
            if (!root.ready()) return false
            pane.listArea.forceActiveFocus()
            pane.clearSelection()
            // A row outside the held window reads as missing, so the cursor goes home until the window holds it.
            var home = c.far ? pane.total - 1 : root.indexOfName(c.target)
            if (c.far ? !pane.rowFor(home) : home < 0) { pane.setCursor(c.far ? home : 0); return false }
            pane.setCursor(home)
            root.stage = c.legs ? 2 : 1
            return true
        }
        if (root.stage === 1) {
            var measured = root.phase(tag + " before")
            if (measured === false) return false
            root.before = measured
            root.stage = 2
            return true
        }
        if (root.stage === 2) {
            var at = root.indexOfName(c.target)
            if (at < 0) { pane.setCursor(0); return false }
            if (pane.cursorIndex !== at) { pane.setCursor(at); return false }
            driver.keyClickChar("r", Qt.NoModifier, -1)
            root.stage = 3
            return true
        }
        if (root.stage === 3) {
            var editor = pane.renameEditor()
            if (!editor || !editor.editorField || !editor.editorField.inputItem.activeFocus) return false
            for (var i = 0; i < c.typed.length; i++) driver.keyClickChar(c.typed.charAt(i), Qt.NoModifier, -1)
            // A double click on the path opens the field through startEdit, and the editor abandons on losing focus.
            if (c.legs) pane.chooseView(c.legs[0])
            else if (c.end === 0) root.chrome().startEdit()
            else driver.keyClick(c.end, Qt.NoModifier, -1)
            root.waitTicks = 0
            root.stage = 4
            return true
        }
        if (root.stage === 4) {
            var landed = c.end === Qt.Key_Return ? c.typed + ".txt" : c.target
            if (!root.settled() || root.indexOfName(landed) < 0) return false
            // Ten more ticks let a late window reply or a queued layout land before the idle second starts.
            if (++root.waitTicks < 10) return false
            root.waitTicks = 0
            if (c.end === 0) {
                root.check(root.chrome().pathField.activeFocus, tag + " the path field lost the keyboard to " + root.focusChain())
                root.check(!pane.listArea.activeFocus && root.census().editors === 0, tag + " list focus " + pane.listArea.activeFocus + ", editors " + root.census().editors)
                // A press on the listing hands the keyboard back, as ui/SelectionBand.qml does.
                pane.listArea.forceActiveFocus()
            }
            root.stage = 5
            return true
        }
        if (root.stage === 5 && c.legs) {
            if (!root.leg(c, tag)) return false
            root.caseIndex++
            root.stage = 0
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

    // A positive control for the per-key counts: a cursor jump of sixty rows scrolls the list inside the held window, so delegates rebind and held rows are read.
    function control(c) {
        if (root.stage === 0) {
            if (Flea.ViewState.state.view !== c.view) { pane.chooseView(c.view); return false }
            if (!root.settled()) return false
            pane.listArea.forceActiveFocus()
            pane.clearSelection()
            if (pane.cursorIndex !== 0 || !pane.rowFor(0) || !pane.rowFor(60)) { pane.setCursor(0); return false }
            root.armRows()
            root.resetCounters()
            root.cells = root.cellSnap()
            pane.setCursor(60)
            root.waitTicks = 0
            root.stage = 1
            return true
        }
        if (++root.waitTicks < 6) return false
        var delta = root.cellDelta(root.cells, root.cellSnap())
        var seen = root.counters()
        root.line("control scroll", { delta: delta, seen: seen })
        root.check(delta.rebound + delta.built > 0, "control a sixty row jump rebound or built no delegate")
        root.check(seen.rowReads > 0, "control a sixty row jump read no held row")
        root.check(seen.cursorRow > 0, "control a sixty row jump left the cursor row alone")
        root.waitTicks = 0
        root.stage = 0
        root.caseIndex++
        return true
    }

    // One view per leg, settled: three Down presses one tick apart move the cursor three rows, and that view's own area holds the keyboard.
    function leg(c, tag) {
        var view = c.legs[root.legIndex]
        if (Flea.ViewState.state.view !== view) { pane.chooseView(view); return false }
        if (pane.viewMode !== view || !root.settled() || ++root.waitTicks < 10) return false
        if (root.waitTicks === 10) root.legStart = pane.cursorIndex
        if (root.waitTicks <= 12) { driver.keyClick(Qt.Key_Down, Qt.NoModifier, -1); return false }
        if (root.waitTicks < 19) return false
        var moved = pane.cursorIndex - root.legStart
        var held = view === "columns" ? body.Window.window.activeFocusItem === pane.columnsArea : pane.listArea.activeFocus
        root.line(tag + " leg " + root.legIndex + " " + view, { moved: moved, held: held, focus: root.focusChain() })
        root.check(moved === 3, tag + " leg " + root.legIndex + " " + view + " Down x3 moved the cursor " + moved)
        root.check(held, tag + " leg " + root.legIndex + " " + view + " the keyboard sits in " + root.focusChain())
        root.waitTicks = 0
        return ++root.legIndex === c.legs.length
    }

    // Per rename end and view, no count of the sixteen keys is higher after the rename than before it; a landed row's selection follows the cursor by design, one bump per key, so selection may rise to the key count.
    function compare(tag, a, b) {
        root.check(a.listFocus && a.missed === 0, tag + " before the rename " + a.missed + " keys missed the key handler, list focus " + a.listFocus)
        root.check(b.listFocus, tag + " the list area lost the keyboard to " + b.focus)
        root.check(b.missed === 0, tag + " " + b.missed + " of " + root.keys.length + " keys never reached the key handler: " + b.trace)
        root.check(b.idleFrames <= Math.max(a.idleFrames, root.idleFloor), tag + " idle frames " + a.idleFrames + " before, " + b.idleFrames + " after")
        root.check(b.census.timers <= a.census.timers, tag + " running timers " + a.census.timers + " before, " + b.census.timers + " after")
        root.check(b.census.animations <= a.census.animations, tag + " running animations " + a.census.animations + " before, " + b.census.animations + " after")
        var costs = ["rows", "cursorRow", "built", "destroyed", "rebound"]
        for (var n = 0; n < costs.length; n++)
            root.check(b.keys[costs[n]] <= a.keys[costs[n]], tag + " " + costs[n] + " over " + root.keys.length + " keys " + a.keys[costs[n]] + " before, " + b.keys[costs[n]] + " after")
        // The grid draws 40 to 45 frames for the same sixteen keys from run to run, so frames get four of slack.
        root.check(b.keys.frames <= a.keys.frames + root.frameSlack, tag + " frames over " + root.keys.length + " keys " + a.keys.frames + " before, " + b.keys.frames + " after")
        // Each bump of the landed row's selection makes the status strip total that one row in five field reads; Escape bumps nothing and reads the same.
        root.check(b.keys.rowReads <= a.keys.rowReads + root.readsPerBump * b.keys.selection, tag + " row field reads over " + root.keys.length + " keys " + a.keys.rowReads + " before, " + b.keys.rowReads + " after, " + b.keys.selection + " selection bumps")
        root.check(b.keys.selection <= Math.max(a.keys.selection, root.keys.length), tag + " selection bumps over " + root.keys.length + " keys " + a.keys.selection + " before, " + b.keys.selection + " after")
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
        function onCursorRowChanged() { root.cursorRowEvals++ }
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
                    + " view=" + Flea.ViewState.state.view + " ready=" + root.ready() + " row=" + (pane.rowFor(pane.cursorIndex) ? pane.rowFor(pane.cursorIndex).n : "none"))
                root.report()
            }
        }
    }
}
