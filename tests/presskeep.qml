//@ pragma ShellId flea-presskeep-test
import QtQuick
import QtTest
import Quickshell
import "flea" as Flea

// A press held across a watched re-read of an unchanged listing must still tap on release, in every view.
ShellRoot {
    id: root
    readonly property var pane: body.currentPane
    readonly property string fixture: Quickshell.env("FLEA_PATH")
    readonly property int fixtureRows: 4
    readonly property int pressedRow: 2
    readonly property int pollMs: 20
    readonly property int stageLimitMs: 5000
    readonly property int pointerEventMs: 1
    // Longer than the 400 ms watchMs burst timer plus a local round trip, so a re-read the press does not hold lands inside the press.
    readonly property int holdMs: 700
    readonly property var cases: {
        var out = []
        for (var view of ["list", "grid", "columns"])
            for (var button of [Qt.RightButton, Qt.LeftButton])
                for (var changed of [false, true]) out.push({view: view, button: button, changed: changed})
        return out
    }
    property int caseIndex: 0
    property string stage: "view"
    property int checks: 0
    property int failures: 0
    property int beforeLists: 0
    property double started: Date.now()
    property bool executing: false
    property bool finished: false
    property var heldItem: null
    property point heldPoint: Qt.point(0, 0)
    readonly property var current: cases[caseIndex]

    function label() { return caseIndex < cases.length ? current.view + "/" + (current.button === Qt.RightButton ? "right" : "left") + (current.changed ? "/changed" : "/quiet") : "end" }
    function check(name, actual, expected) {
        checks += 1
        var equal = actual === expected
        if (!equal) failures += 1
        console.log("PRESSKEEP " + (equal ? "ok " : "FAIL ") + label() + " " + name + ": got " + actual + ", expected " + expected)
    }
    function next(stage) { root.stage = stage; started = Date.now() }
    function finish() {
        finished = true
        console.log("PRESSKEEP DONE checks=" + checks + " failed=" + failures)
        body.quitBackends()
    }
    function advance() {
        if (executing || finished) return
        executing = true
        try { runStage() }
        catch (error) { check("harness error", String(error), "none"); finish() }
        executing = false
    }
    function settled() {
        return !pane.listInFlight && pane.listingState === "ready" && pane.path === fixture && pane.total === fixtureRows
            && !pane.wire.anchor && !pane.wire.stale && !!pane.visibleItemFor(pressedRow)
    }
    function runStage() {
        if (Date.now() - started > stageLimitMs) {
            check("stage " + stage + " completed", false, true)
            finish()
            return
        }
        if (stage === "view") {
            Flea.ViewState.changeKey("view", current.view)
            next("settle")
        } else if (stage === "settle") {
            body.focusPane(0)
            if (pane.path !== fixture && !pane.listInFlight) { pane.open(fixture); return }
            if (!settled()) return
            pane.contextMenu().close()
            pane.setCursor(0)
            pane.listArea.forceActiveFocus()
            heldItem = pane.visibleItemFor(pressedRow)
            heldPoint = body.mapFromItem(heldItem, heldItem.width / 2, heldItem.height / 2)
            driver.mousePress(body, heldPoint.x, heldPoint.y, current.button, Qt.NoModifier, pointerEventMs)
            beforeLists = pane.backend.listRequests
            // The unsolicited line a foreign write to the folder sends, which PaneWire pays after its burst timer.
            if (current.changed) pane.backend.changed(pane.path)
            next("held")
        } else if (stage === "held") {
            if (current.changed && Date.now() - started < holdMs) return
            if (current.changed) check("the pressed delegate lasts the press", pane.visibleItemFor(pressedRow) === heldItem, true)
            driver.mouseRelease(body, heldPoint.x, heldPoint.y, current.button, Qt.NoModifier, pointerEventMs)
            if (current.button === Qt.RightButton) check("release opens the menu", pane.contextMenu().opened, true)
            else check("release moves the cursor to the pressed row", pane.cursorIndex, pressedRow)
            pane.contextMenu().close()
            next(current.changed ? "paid" : "advance")
        } else if (stage === "paid") {
            if (pane.listInFlight || pane.wire.stale || pane.wire.anchor || pane.backend.listRequests <= beforeLists) return
            check("the re-read is paid after the release", pane.backend.listRequests > beforeLists, true)
            next("advance")
        } else if (stage === "advance") {
            caseIndex += 1
            if (caseIndex === cases.length) finish()
            else next("view")
        }
    }

    FloatingWindow {
        id: window
        implicitWidth: 1000
        implicitHeight: 800
        Flea.WindowBody { id: body; host: window }
        Item { anchors.fill: parent; TestEvent { id: driver } }
    }
    Timer { interval: root.pollMs; repeat: true; running: !root.finished; onTriggered: root.advance() }
}
