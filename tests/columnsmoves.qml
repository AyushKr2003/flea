//@ pragma ShellId flea-columnsmoves-test
import QtQuick
import QtTest
import Quickshell
import "flea" as Flea
import "flea/js/Nav.js" as Nav
import "columnsframes.js" as Frames

// Every move runs through a real Pane and ColumnsArea; replies and assertions advance by rendered frames.
ShellRoot {
    id: root
    property var pane: null
    readonly property var area: pane ? pane.columnsArea : null
    property int frameNumber: 0
    property int caseIndex: 0
    property int phase: 0
    property int waited: 0
    property var queue: []
    property var samples: []
    property var before: null
    property int failures: 0
    property bool warmed: false
    property bool freezePeeks: false
    readonly property string base: "/fixture/group/a"
    readonly property string railPath: Quickshell.env("HOME")
    readonly property var cases: ["parent-click", "grandparent-click", "third-click", "right", "enter", "left", "back", "chrome-up", "backspace", "rail", "arrow", "parent-file-click"]
    readonly property var dirs: root.makeDirs()

    function rows(names) {
        return names.map(function (n) { return { n: n, d: true, i: "folder", s: 4096, m: 1, p: 16877, k: 0 } })
    }
    function makeDirs() {
        var out = { "/": rows(["fixture"]), "/fixture": rows(["group", "other"]), "/fixture/group": rows(["a", "b", "file"]),
                    "/elsewhere": rows(["rail"]), "/elsewhere/rail": rows(["child", "second"]) }
        for (var path of [base, "/fixture/group/b", "/fixture/other", "/elsewhere/rail"])
            for (var suffix of ["", "/child", "/child/grand", "/child/grand/child", "/second", "/second/child"])
                out[path + suffix] = rows(suffix === "/child" ? ["grand", "second"] : ["child", "second"])
        out["/fixture/group/file"] = [{ n: "data.bin", d: false, i: "application-octet-stream", s: 36, m: 1, p: 33188, k: 1 }]
        out[railPath] = rows(["child", "second"])
        out[railPath + "/child"] = rows(["grand", "second"])
        var at = railPath
        while (at !== "/") {
            var parent = Nav.parentOf(at)
            if (!out[parent]) out[parent] = rows([Nav.leafOf(at)])
            at = parent
        }
        return out
    }

    FloatingWindow {
        id: win
        implicitWidth: 2100
        width: implicitWidth
        implicitHeight: 600
        color: Flea.Theme.color.background
        Item {
            id: host
            anchors.fill: parent
            Rectangle {
                width: 1; height: 1; y: host.height - 1; z: 100
                color: win.color
                NumberAnimation on x { from: 0; to: 1; duration: 1000; loops: Animation.Infinite }
            }
            Connections {
                target: host.Window.window
                function onAfterAnimating() { root.sample(); Qt.callLater(root.advance) }
            }
        }
        TestEvent { id: driver }
    }
    Flea.ChromeBar {
        id: chrome
        parent: host
        anchors { top: parent.top; left: parent.left; right: parent.right }
        path: root.pane ? root.pane.path : ""
        canGoBack: root.pane && root.pane.history.length > 0
        canGoUp: root.pane && root.pane.canGoUp
        viewMode: "columns"
        onBackRequested: root.pane.goBack()
        onUpRequested: root.pane.openParent()
    }
    Flea.Backend {
        id: probeBackend
        function send(one) {
            if (one.c === "list" || one.c === "peek" || one.c === "fsinfo" || one.c === "meta")
                root.queue = root.queue.concat([{ request: one, due: root.frameNumber + (one.c === "peek" ? 2 : 1) }])
        }
    }
    Component {
        id: paneComponent
        Flea.Pane { anchors.fill: parent; anchors.topMargin: chrome.height; backend: probeBackend }
    }

    function pump() {
        var ready = queue.filter(function (one) { return one.due <= root.frameNumber && !(root.freezePeeks && one.request.c === "peek") })
        queue = queue.filter(function (one) { return one.due > root.frameNumber || root.freezePeeks && one.request.c === "peek" })
        for (var item of ready) {
            var one = item.request, all = dirs[one.path] || []
            if (one.c === "list") {
                probeBackend.listed(all.length, 0, 0, one.path, -1, 0)
                probeBackend.rows(0, all, 0, ["Folder", "Data"], root.frameNumber, 0)
            } else if (one.c === "peek") {
                probeBackend.peeked(one.path, one.hidden, all.length, all.map(function (r) { return { n: r.n, d: r.d, i: r.i } }),
                               false, 0, one.hiddenLast, one.first, 2049, true, one.by || "", one.desc === true)
            } else if (one.c === "meta") probeBackend.metaResult({ token: one.token, row: one.row, w: 0, h: 0, ms: 0, rate: 0,
                entries: 0, unpacked: 0, names: [], lines: 0, partial: false, lfailed: false, afailed: false, target: "", targetdir: false, owner: "" })
            else probeBackend.fsInfo("ext4", 1000000, pane.listingPath, "local", true, false)
        }
    }
    function census() { return Frames.census(area) }
    function sample() {
        if (phase !== 3 || !area) return
        var state = census()
        samples.push(state)
        console.log("COLUMNMOVES FRAME " + cases[caseIndex] + " " + JSON.stringify(state))
    }
    function settled() {
        if (!pane || pane.listInFlight || queue.length || !area.thirdReady || !area.shownHasRow) return false
        if (area.cursorIsDir && area.shownChildPath !== area.childPath) return false
        if (!area.cursorIsDir && !area.previewColumn.ready) return false
        var state = census()
        return state.columns.length === area.columnCount - (area.cursorIsDir ? 0 : 1) && state.columns.every(function (col) { return col.rows > 0 })
    }
    function press(item) {
        if (!item) throw new Error("pointer target is missing")
        driver.mousePress(item, 20, item.height / 2, Qt.LeftButton, Qt.NoModifier, 0)
        driver.mouseRelease(item, 20, item.height / 2, Qt.LeftButton, Qt.NoModifier, 0)
    }
    function click(item) { if (!item || !item.row) throw new Error("pointer target has no row"); press(item) }
    function issue() {
        var name = cases[caseIndex]
        before = census(); samples = []; phase = 3; waited = 0
        Flea.ViewState.changeKey("keys", name === "right" || name === "left" ? "mac" : "default")
        pane.focusView = "list"
        area.forceActiveFocus()
        if (name === "parent-click") click(area.parentItemAt(1))
        else if (name === "parent-file-click") click(area.parentItemAt(2))
        else if (name === "grandparent-click") click(area.grandparentItemAt(1))
        else if (name === "third-click") click(area.childItemAt(0))
        else if (name === "right") driver.keyClick(Qt.Key_Right, Qt.NoModifier, 0)
        else if (name === "enter") driver.keyClick(Qt.Key_Return, Qt.NoModifier, 0)
        else if (name === "left") driver.keyClick(Qt.Key_Left, Qt.NoModifier, 0)
        else if (name === "back") press(chrome.buttonFor("arrow-left"))
        else if (name === "chrome-up") press(chrome.buttonFor("arrow-up"))
        else if (name === "backspace") driver.keyClick(Qt.Key_Backspace, Qt.NoModifier, 0)
        else if (name === "rail") press(pane.sidebar.railItemFor(0))
        else driver.keyClick(Qt.Key_Down, Qt.NoModifier, 0)
    }
    function judge() {
        var after = census(), bad = [], readingFrames = 0
        var name = cases[caseIndex], expected = ["left", "back", "chrome-up", "backspace", "arrow"].indexOf(name) >= 0 ? base
            : name === "parent-click" ? "/fixture/group/b" : name === "parent-file-click" ? "/fixture/group/file" : name === "grandparent-click" ? "/fixture/other"
            : name === "third-click" ? base + "/child/grand" : name === "rail" ? railPath : base + "/child"
        if (pane.path !== expected) bad.push("path=" + pane.path + " expected=" + expected)
        if (name === "arrow" && pane.cursorIndex !== 1) bad.push("cursor=" + pane.cursorIndex + " expected=1")
        for (var frame = 0; frame < samples.length; frame++) {
            var state = samples[frame]
            for (var i = 0; i < before.columns.length; i++) {
                // The listing's explicit capped reading state is allowed; an ancestor or third-column hole never is.
                if (i === before.columns.length - 2 && state.loading && state.listing.fellBack) { readingFrames++; continue }
                if (before.columns[i].rows > 0 && after.columns[i] && after.columns[i].rows > 0
                        && (!state.columns[i] || state.columns[i].rows === 0)) bad.push("frame=" + (frame + 1) + " column=" + i + " rows=0")
            }
            if (before.hasThird && after.hasThird && !state.hasThird) bad.push("frame=" + (frame + 1) + " third=empty")
            if (state.hasThird && state.third !== "folder" && !state.preview.row && !state.capturing && !state.holding)
                bad.push("frame=" + (frame + 1) + " preview=empty")
        }
        if (!samples.length) bad.push("no rendered frame sampled")
        if (bad.length) failures++
        console.log("COLUMNMOVES " + (bad.length ? "FAIL " : "PASS ") + cases[caseIndex] + ": every non-empty column stays non-empty; " + (bad.join("; ") || "frames=" + samples.length) + " reading=" + readingFrames)
        caseIndex++; phase = 1; waited = 0
        if (caseIndex === cases.length) {
            if (failures || !area.landing) finish()
            else phase = 4
        }
    }
    function control(ok, label) {
        if (!ok) failures++
        console.log("COLUMNMOVES CONTROL " + (ok ? "PASS " : "FAIL ") + label)
    }
    function finish() { console.log("COLUMNMOVES DONE " + cases.length + " moves, " + failures + " failed"); Qt.quit() }
    function advance() {
        frameNumber++; pump(); waited++
        if (waited > 300) { console.log("COLUMNMOVES FAIL stalled " + cases[caseIndex] + " phase=" + phase); Qt.quit(); return }
        if (phase === 0) {
            Flea.ViewState.state = { view: "columns", keys: "default", columnsLimit: 3 }
            pane = paneComponent.createObject(host)
            phase = 1
        }
        if (phase === 1) {
            Flea.ViewState.changeKey("columnsLimit", cases[caseIndex] === "grandparent-click" ? 4 : 3)
            pane.open(base)
            phase = 2; waited = 0
        } else if (phase === 2 && settled() && waited >= 4) {
            if (!warmed) {
                warmed = true; click(area.parentItemAt(1)); phase = 1; waited = 0
            } else if (["left", "back", "chrome-up", "backspace"].indexOf(cases[caseIndex]) >= 0 && pane.path === base) {
                pane.open(base + "/child"); waited = 0
            } else issue()
        } else if (phase === 3 && settled() && waited >= 5) judge()
        else if (phase === 4) {
            dirs[area.parentPath] = dirs[area.parentPath].concat(rows(["fresh"]))
            area.denials[area.peekKey(area.parentPath)] = 0
            probeBackend.changed(area.parentPath)
            control(queue.some(function (one) { return one.request.c === "peek" && one.request.path === area.parentPath }), "changed re-asks the kept parent")
            pane.open(base)
            phase = 5; waited = 0
        } else if (phase === 5 && settled()) {
            control(area.rowsFor(area.parentPath).some(function (row) { return row.n === "fresh" }), "watching refresh survives a lateral landing and updates in place")
            control(area.deniedMode(area.parentPath) === -1, "successful refresh removes the previous denial")
            freezePeeks = true
            pane.open("/elsewhere/rail")
            phase = 6; waited = 0
        } else if (phase === 6 && !pane.listInFlight) {
            var parent = area.parentItemAt(0)
            control(area.landing.waiting(area.parentPath) && parent && parent.row, "a changed ancestor keeps its old rows")
            area.landing.expire()
            control(area.landing.loading(area.parentPath) && area.rowsFor(area.parentPath).length === 0, "cap replaces old rows with reading")
            freezePeeks = false; phase = 7; waited = 0
        } else if (phase === 7 && !queue.length) {
            control(area.landing.loading(area.parentPath) && area.landing.held[area.parentPath].ready, "a reply inside the reading minimum stays covered")
            area.landing.releaseMinimum()
            control(!area.landing.waiting(area.parentPath) && area.rowsFor(area.parentPath).length > 0, "reading minimum releases the completed ancestor")
            finish()
        }
    }
}
