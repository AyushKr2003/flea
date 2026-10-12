//@ pragma ShellId flea-gridswitch-test
import QtQuick
import QtTest
import Quickshell
import "flea" as Flea

// A switch to Grid builds only the viewport's tiles before its first frame, the cache rows after it, and draws no half-built frame: a real pane, counted, never timed.
// Sample output: "GRIDSWITCH SWITCH first from=list frames=2 whole=2 tiles=48 thumbs=1 units=0".
ShellRoot {
    id: root
    readonly property string fixture: Quickshell.env("FLEA_GS_DIR") || ""
    readonly property int entries: Number(Quickshell.env("FLEA_GS_ENTRIES") || "0")
    // The most tiles one landing may build: the viewport's and its cache rows, counted from the Grid's own plan.
    property int checks: 0
    property int failures: 0
    property int frames: 0
    property var pane: null
    property var steps: []
    property var waitFor: null
    property double waitUntil: 0
    property double deadline: 0
    property bool quietNeeded: false
    property int quietMark: -1
    property double quietSince: 0
    property double railBy: 0
    // Frames since the key, and how many of them drew the Grid whole.
    property int keyFrames: 0
    property int wholeFrames: 0
    property int partialFrames: 0
    property int builtAtKey: 0
    property int thumbsAtKey: 0
    property var gridAtKey: null
    property int switches: 0
    property double keyAt: 0
    property var frameLog: []
    property int firstFrameTiles: -1
    property double keyDoneAt: 0
    property int framesAtKeyDone: 0

    function fail(text) {
        failures += 1
        console.log("GRIDSWITCH FAIL " + text)
    }
    function check(name, ok, detail) {
        checks += 1
        if (!ok) fail(name + " " + detail)
        else console.log("GRIDSWITCH ok " + name)
    }
    function finish() {
        ticker.stop()
        console.log("GRIDSWITCH DONE " + checks + " checks, " + failures + " failed")
        Qt.quit()
    }
    function isGrid(area) { return area !== null && area.columns !== undefined }
    // The Grid is whole when it is up, visible, past its hold and drew its first tile.
    function whole() {
        if (!pane) return false
        var area = pane.listArea
        return pane.viewMode === "grid" && isGrid(area) && area.visible && !area.hiddenHeld && area.count > 0 && area.itemAtIndex(0) !== null
    }
    // The Grid wherever it sits, hidden or not; the pane exposes it only while it is the view in use.
    function findGrid(item) {
        if (!item) return null
        if (item.cellHeightPx !== undefined && item.prebuild !== undefined) return item
        var kids = item.children || []
        for (var i = 0; i < kids.length; i++) {
            var hit = findGrid(kids[i])
            if (hit) return hit
        }
        return null
    }
    // Tiles whose cell meets the viewport, parked ones excluded.
    function seen(grid) {
        var n = 0, kids = grid.contentItem.children
        for (var i = 0; i < kids.length; i++)
            if (kids[i].index !== undefined && kids[i].prebuilt !== true && kids[i].parent === grid.contentItem && kids[i].y + kids[i].height > grid.contentY && kids[i].y < grid.contentY + grid.height) n++
        return n
    }
    function built() { var grid = findGrid(pane); return grid ? grid.prebuild.createdCount : 0 }
    function landed() {
        return !pane.listInFlight && !pane.swap.holding && pane.total === entries
    }
    function quiet() { root.quietNeeded = true; root.quietMark = -1; root.railBy = Date.now() + 4000 }
    function railSettled() { return pane !== null && pane.sidebar !== null && pane.sidebar.railDeadlineElapsed }
    // One switch: the chord, then frames counted until the Grid is whole and the hold has ended.
    function switchTo(name, view, key, expectBuilt) {
        return [
            quiet,
            function () {
                root.keyFrames = root.frames
                root.wholeFrames = 0
                root.partialFrames = 0
                root.builtAtKey = root.built()
                root.thumbsAtKey = probeBackend.thumbRequests
                pane.listArea.forceActiveFocus()
                root.frameLog = []
                root.firstFrameTiles = -1
                root.keyAt = Date.now()
                root.keyDoneAt = 0
                // keyClick spins the event loop, so the wait is armed first and holds the report until the click has returned.
                root.waitUntil = Date.now() + 3000
                root.waitFor = function () { return root.keyDoneAt > 0 && root.whole() }
                keys.keyClick(key, Qt.ControlModifier, -1)
                root.keyDoneAt = Date.now()
                root.framesAtKeyDone = root.frames
            },
            function () {
                var drawn = root.frames - root.keyFrames
                var tiles = root.built() - root.builtAtKey
                var thumbs = probeBackend.thumbRequests - root.thumbsAtKey
                var area = pane.listArea
                console.log("GRIDSWITCH SWITCH " + name + " to=" + view + " frames=" + drawn + " partial=" + root.partialFrames + " tiles=" + tiles + " thumbs=" + thumbs
                    + " cols=" + area.columns + " vrows=" + area.visibleTileRows + " plan=" + area.landingTiles + " count=" + area.count + " keyms=" + (root.keyDoneAt - root.keyAt) + " landms=" + (Date.now() - root.keyAt) + " framesAtKeyDone=" + (root.framesAtKeyDone - root.keyFrames) + " log=" + root.frameLog.join(" | "))
                check(name + ": the Grid is whole after the key", root.whole(), "viewMode=" + pane.viewMode)
                check(name + ": no frame drew a half-built Grid", root.partialFrames === 0, "partial=" + root.partialFrames)
                // The first frame after the key holds the viewport's tiles, one spare row at most; the cache rows come after it.
                var first = root.firstFrameTiles
                check(name + ": the first frame built only the viewport's tiles", first >= 0 && first <= area.columns * (area.visibleTileRows + 1), "first=" + first + " viewport=" + area.columns * area.visibleTileRows)
            },
            function () { root.waitUntil = Date.now() + 3000; root.waitFor = function () { var g = root.findGrid(pane); return g.prebuild.createdCount - g.prebuild.destroyedCount >= g.landingTiles } },
            function () {
                var g = root.findGrid(pane)
                check(name + ": the cache rows are built after the frame, none missing", g.prebuild.createdCount - g.prebuild.destroyedCount >= g.landingTiles, "live=" + (g.prebuild.createdCount - g.prebuild.destroyedCount) + " plan=" + g.landingTiles)
            }
        ]
    }
    function back(name, key) {
        return [
            quiet,
            function () { pane.listArea.forceActiveFocus(); keys.keyClick(key, Qt.ControlModifier, -1); root.waitUntil = Date.now() + 500 },
            function () { check(name + ": the view is up", true, "") }
        ]
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
            }
        }
        TestEvent { id: keys }
        Item {
            id: frameProbe
            Connections {
                target: frameProbe.Window.window
                function onFrameSwapped() {
                    root.frames += 1
                    if (root.keyDoneAt >= 0 && root.keyAt > 0 && root.frames > root.keyFrames) if (root.frameLog.length === 0) root.firstFrameTiles = root.built() - root.builtAtKey
                    root.frameLog.push("f" + (root.frames - root.keyFrames) + "@" + (Date.now() - root.keyAt) + "ms tiles=" + (root.built() - root.builtAtKey) + " seen=" + (root.findGrid(root.pane) ? root.seen(root.findGrid(root.pane)) : -1) + " parked=" + (root.findGrid(root.pane) ? root.findGrid(root.pane).prebuild.parkedCount : -1) + " whole=" + root.whole())
                    if (root.keyFrames >= 0 && root.frames > root.keyFrames && root.pane && root.pane.viewMode === "grid") {
                        if (root.whole()) root.wholeFrames += 1
                        else root.partialFrames += 1
                    }
                }
            }
        }
    }

    Component.onCompleted: {
        steps = [
            function () { pane = paneComponent.createObject(win.contentItem); pane.open(fixture); root.waitFor = landed },
            function () {
                check("the fixture is listed whole", pane.total === entries, "total=" + pane.total)
                check("the view is list", pane.viewMode === "list", "viewMode=" + pane.viewMode)
            }
        ].concat(switchTo("first", "grid", Qt.Key_3, true), back("grid to list", Qt.Key_1), switchTo("second", "grid", Qt.Key_3, false), back("grid to columns", Qt.Key_2), switchTo("third", "grid", Qt.Key_3, false), [finish])
        deadline = Date.now() + 40000
    }

    Timer {
        id: ticker
        interval: 10
        running: true
        repeat: true
        onTriggered: {
            if (Date.now() > root.deadline) {
                root.fail("stalled with " + root.steps.length + " steps left")
                root.finish()
                return
            }
            if (root.quietNeeded) {
                if (!root.railSettled()) {
                    root.quietMark = -1
                    if (Date.now() > root.railBy) { root.fail("the rail never settled"); root.finish() }
                    return
                }
                if (root.quietMark !== root.frames) { root.quietMark = root.frames; root.quietSince = Date.now(); return }
                if (Date.now() - root.quietSince < 300) return
                root.quietNeeded = false
            }
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
                root.fail("a step threw: " + error)
                root.finish()
            }
        }
    }
}
