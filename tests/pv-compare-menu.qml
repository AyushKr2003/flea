//@ pragma ShellId flea-pv-compare-menu-test
import QtQuick
import Quickshell
import "flea/js/Compare.js" as Compare

// The real pane, menu snapshot and Compare activation over marks farther apart than one held window.
ShellRoot {
    id: root
    readonly property int rowCount: 5002
    readonly property int farIndex: 4800
    readonly property int pollMs: 20
    readonly property int stepBudgetMs: 20000
    readonly property int typeMask: 0o170000
    readonly property int regularKind: 0o100000
    readonly property int linkKind: 0o120000
    readonly property string fixture: Quickshell.env("PVCMP_DIR") + "/marks"
    property int step: -2
    property int checks: 0
    property int failures: 0
    property double started: Date.now()
    property bool finished: false

    function pane() { return body.item.currentPane }
    function check(label, actual, expected) {
        checks++
        var ok = JSON.stringify(actual) === JSON.stringify(expected)
        if (!ok) failures++
        console.log("PVCMP " + (ok ? "PASS " : "FAIL ") + label + " got=" + JSON.stringify(actual) + " expected=" + JSON.stringify(expected))
    }
    function advance() { step++; started = Date.now() }
    function finish() {
        if (finished) return
        finished = true
        console.log("PVCMP DONE " + checks + " checks, " + failures + " failed")
        if (body.item) body.item.quitBackends()
        quitter.start()
    }
    function row() {
        return pane().contextMenu().entries.filter(function (entry) { return entry.action === "compare" })[0] || null
    }
    function openMenu() { pane().contextMenu().openAt(Qt.point(400, 200)) }
    function tick() {
        if (finished) return
        if (Date.now() - started > stepBudgetMs) {
            if (body.item) {
                var p = pane(), look = body.item.quickLook
                console.log("PVCMP wait ready=" + p.menuActions.ready + " pending=" + p.menuActions.pendingAction + " activation=" + p.menuActions.pendingActivation
                    + " identity=" + (p.menuActions.identity === p.menuSelectionIdentity()) + " look=" + !!look
                    + (look ? " active=" + look.active + " kind=" + look.kind + " status=" + look.status : ""))
            }
            check("menu path finishes step " + step, false, true)
            finish()
            return
        }
        if (!body.item) return
        var p = pane(), menu = p.contextMenu(), look = body.item.quickLook
        switch (step) {
        case -2:
            if (p.listInFlight || p.listingState !== "ready" || p.total !== rowCount || !p.rowFor(0) || !p.rowFor(1)) return
            p.selectOnly(0)
            p.toggleSelectAt(1)
            openMenu()
            advance()
            return
        case -1:
            if (!p.menuActions.ready) return
            // The initial held window can refill after the snapshot; ask again for its current identity.
            if (p.menuActions.identity !== p.menuSelectionIdentity()) { p.menuActions.snapshot(); return }
            check("both held rows retain regular modes", [p.rowFor(0).p & root.typeMask, p.rowFor(1).p & root.typeMask], [root.regularKind, root.regularKind])
            p.menuActions.selectedKinds = [root.linkKind, root.linkKind]
            check("the ready matching snapshot inspects two links", [p.menuActions.ready, p.menuActions.identity === p.menuSelectionIdentity(), p.menuActions.selectedKinds], [true, true, [root.linkKind, root.linkKind]])
            menu.refreshProviderRows()
            check("inspected links hide Compare over held regular rows", row(), null)
            check("Quick Look is unbuilt before the refused choice", body.item.quickLook === null, true)
            Compare.open(p, [fixture + "/f0000.txt", fixture + "/f0001.txt"])
            check("inspected links block Compare.open over held regular rows", [body.item.quickLook !== null, !!(body.item.quickLook && body.item.quickLook.active)], [false, false])
            menu.close()
            advance()
            return
        case 0:
            if (p.listInFlight || p.listingState !== "ready" || p.total !== rowCount || !p.rowFor(0)) return
            p.selectOnly(0)
            p.setCursor(farIndex)
            advance()
            return
        case 1:
            if (!p.rowFor(farIndex) || p.rowFor(0)) return
            p.toggleSelect()
            check("two regular files are marked more than one window apart", p.selectedIndices().slice().sort(function (a, b) { return a - b }), [0, farIndex])
            check("the first marked file is outside the held rows", p.rowFor(0), null)
            openMenu()
            advance()
            return
        case 2:
            if (!p.menuActions.ready || row() === null) return
            check("the live snapshot resolves both own regular kinds", p.menuActions.selectedKinds, [0o100000, 0o100000])
            check("the drawn menu offers Compare for the unheld mark", row().label, "Compare")
            menu.choose("compare")
            advance()
            return
        case 3:
            if (!look || !look.active || !look.isCompare || !look.surfaceItem() || look.surfaceItem().status !== "compare") return
            check("activation opens the resolved files in listing order", [look.path, look.comparePath], [fixture + "/f0000.txt", fixture + "/f4800.txt"])
            check("the backend compares the unheld pair", look.surfaceItem().patch.indexOf("-row 0\n+row 4800\n") >= 0, true)
            look.close()
            p.selectOnly(rowCount - 2)
            p.toggleSelectAt(rowCount - 1)
            advance()
            return
        case 4:
            if (!p.rowFor(rowCount - 2) || !p.rowFor(rowCount - 1)) return
            openMenu()
            advance()
            return
        case 5:
            if (!p.menuActions.ready) return
            check("symlinks to regular files retain their own kinds", p.menuActions.selectedKinds, [0o120000, 0o120000])
            check("a real symlink pair hides Compare", row(), null)
            menu.close()
            finish()
        }
    }

    FloatingWindow {
        id: window
        implicitWidth: 1300
        implicitHeight: 600
        Loader {
            id: body
            anchors.fill: parent
            source: "file://" + Quickshell.env("PVCMP_UI") + "/WindowBody.qml"
            onLoaded: item.host = window
            onStatusChanged: if (status === Loader.Error) { root.check("WindowBody loads", false, true); root.finish() }
        }
    }
    Timer { interval: root.pollMs; running: true; repeat: true; onTriggered: root.tick() }
    Timer { id: quitter; interval: 200; onTriggered: Qt.exit(root.failures > 0 ? 1 : 0) }
}
