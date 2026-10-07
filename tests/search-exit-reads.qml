//@ pragma ShellId flea-search-exit-reads-test

import QtQuick
import Quickshell
import "flea" as Flea

// While an exit holds the walk every planner refuses the listing that is out, so no row-indexed request leaves.
ShellRoot {
    id: root

    readonly property string mode: Quickshell.env("EXITREADS_MODE")
    property int checks: 0
    property int failures: 0
    property int phase: 0
    property var view: null

    function check(ok, label) {
        root.checks += 1
        if (!ok) {
            root.failures += 1
            console.log("EXITREADS FAIL " + root.mode + " " + label)
        }
    }
    function sentTotal() {
        return root.stubPane.sentThumb.length + root.stubPane.sentDir.length
            + root.stubPane.sentWindow.length + root.stubPane.sentCancel.length
    }
    function finish(note) {
        stepTimer.stop()
        if (note.length > 0) {
            root.failures += 1
            console.log("EXITREADS FAIL " + root.mode + " " + note)
        }
        console.log("EXITREADS MODE " + root.mode + " checks=" + root.checks + " failed=" + root.failures)
        Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }

    Component { id: paneStub; ExitPaneStub {} }
    property var stubPane: paneStub.createObject(root, { mode: root.mode })

    Window {
        id: win
        width: 1000
        height: 700
        visible: true
        Component.onCompleted: {
            var props = { pane: root.stubPane, menu: root.stubPane.menu, width: 1000, height: 619 }
            if (root.mode === "grid")
                root.view = gridComponent.createObject(win.contentItem, props)
            else
                root.view = listComponent.createObject(win.contentItem, props)
            root.stubPane.listArea = root.view
            root.stubPane.standWalk()
            stepTimer.start()
        }
    }
    Component { id: listComponent; Flea.List {} }
    Component { id: gridComponent; Flea.GridArea {} }

    // One scroll plus every planner, the way a restless pointer drives them; the settle and
    // coalesce timers the scroll restarts fire on their own before the next step asserts.
    function drive() {
        root.view.contentY = root.view.contentY + 370
        root.view.requestThumbs()
        root.view.requestDirSizes()
        root.view.requestIfDrifted()
    }
    function step() {
        if (root.phase === 0) {
            drive()
            root.phase = 1
            return
        }
        if (root.phase === 1) {
            check(root.sentTotal() === 0, "held exit sends no row-indexed request, got " + root.sentTotal())
            check(root.stubPane.listInFlight, "the hold is still out while nothing is asked")
            check(root.stubPane.searchMode.length > 0, "the strip stays up over the held rows")
            check(root.stubPane.rows.length > 0 && root.stubPane.rows[0].n === "sub/photo-0.jpg",
                "the held rows are still the walk's")
            root.stubPane.landFolder()
            drive()
            root.phase = 2
            return
        }
        check(root.stubPane.searchMode.length === 0, "the landing closes the strip with its rows")
        check(root.stubPane.rows.length > 0 && root.stubPane.rows[0].n === "photo-0.jpg",
            "the landed rows are the folder's")
        check(root.stubPane.sentThumb.length > 0, "landed folder asks thumbs")
        check(root.stubPane.sentWindow.length > 0, "landed folder asks its window")
        // A tile draws no size, so the grid never asks; the list's own ask is the control.
        if (root.mode !== "grid")
            check(root.stubPane.sentDir.length > 0, "landed folder asks dirsizes")
        finish("")
    }
    Timer {
        id: stepTimer
        interval: 400
        repeat: true
        onTriggered: root.step()
    }
}
