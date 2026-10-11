//@ pragma ShellId flea-listprebuild-test

import QtQuick
import Quickshell
import QtQml.Models
import "flea" as Flea

// listprebuild: quiet turns prebuild parked rows for the next landing, which adopts them with 0 built.
// No parked row within the first landing's hold, the pool fills after it, a later landing is not held, and a refill parks every row it takes.
// The driver converges: about 1 s after each change it has stopped or still parks a row on every wake, and no hold wakes it every 16 ms.
ShellRoot {
    id: root

    property var failures: []
    property bool finished: false
    property var keyTimes: []
    property double firstCountAt: -1
    property int createdBefore: 0
    property int ticksBefore: 0
    property int wakesBefore: 0
    property int parkedBefore: 0
    property string phase: "start"
    property double phaseAt: 0
    property string settleName: ""
    property string settleNext: ""
    property var settleSnap: null
    property double deadline: 0

    function pad(i) { var n = String(i); while (n.length < 4) n = "0" + n; return n }
    function rowsFor(prefix, count) {
        var out = []
        for (var i = 0; i < count; i++)
            out.push({ n: prefix + root.pad(i) + ".txt", d: false, i: "text-plain", p: 420, s: 0, m: 1758835200, t: false, k: 0, v: 0 })
        return out
    }
    property var parentRows: [{ n: "big", d: true, i: "folder", p: 493, s: 0, m: 1758835200, t: false, k: 0, v: 0 }]

    Component {
        id: backendStub
        QtObject {
            signal peeked(string path, bool hidden, int total, var rows, bool readFailed, int mode, bool hiddenLast, int first)
            property int dirDev: 0
            property string sortBy: "name"
            property bool sortDesc: false
            function peek(path, size, hidden) {}
            function thumb(rows, cacheOnly) {}
            function thumbcancel(rows) {}
            function dirsize(rows) {}
            function dirsizecancel() {}
            function window(start, count) {}
            function askMeta(index, text, media, archive) { return 0 }
        }
    }

    Component {
        id: paneStub
        QtObject {
            property string path: "/probe"
            property var rows: []
            property var shown: null
            readonly property int shownTotal: shown === null ? total : shown.length
            property int total: 0
            property int held: 0
            property int cursorIndex: 0
            property int renamingIndex: -1
            property int renameRequest: 0
            property string renameError: ""
            property bool renamePending: false
            property int selectionVersion: 0
            property bool paneFocused: true
            property bool dualMode: false
            property bool showHidden: false
            property var trash: ({ opened: false })
            property var clipboard: ({ paths: [], moving: false })
            property var thumbState: ({ file: {}, order: [] })
            property var dirSizeState: ({ file: {}, order: [] })
            property var kindNames: []
            property string searchMode: ""
            property string searchQuery: ""
            property string recentMode: ""
            property string filterQuery: ""
            property var selectionBand: null
            property int previewIndex: -1
            property bool storageKnown: true
            property string storageClass: ""
            property bool listInFlight: false
            property string listingState: "ready"
            property string pendingSelect: ""
            property bool pendingMenu: false
            property double inputAt: 0
            property int visibleRows: 43
            property int cacheRows: 2
            property int firstSettleMs: 70
            property int settleMs: 120
            property int coalesceMs: 16
            property int refetchMargin: 25
            property int buffer: 150
            property int windowSize: 35
            property var backend: null
            property var sidebar: null
            property var listArea: null
            function join(base, name) { return String(base) + "/" + String(name) }
            function rowFor(index) { var o = index - held; return (o >= 0 && o < rows.length) ? rows[o] : null }
            function isSelected(index) { return false }
            function selectedIndices() { return [] }
            function selectionCount() { return 0 }
            function thumbFor(index) { return "" }
            function setCursor(index, mode) {}
            function slowClickWasSole(index) { return false }
            function pressSlowClick() {}
            function cancelSlowClick() {}
            function armSlowClick() {}
            function commitRename(newName) {}
            function open(path) {}
            function openFile(path) {}
            function focusRequested() {}
        }
    }
    Component { id: menuStub; QtObject { function close() {} function openBackground(point) {} } }

    property var stubPane: paneStub.createObject(root, { backend: backendStub.createObject(root) })

    FloatingWindow {
        implicitWidth: 2536
        implicitHeight: 1389
        color: "black"
        Loader {
            id: viewLoader
            width: 2536
            height: 1381
            sourceComponent: listView
        }
    }
    Component { id: listView; Flea.List { width: 2536; height: 1381; pane: root.stubPane; menu: menuStub.createObject(root) } }

    function view() { return viewLoader.item }
    function delegates() {
        var out = [], v = root.view()
        if (!v || !v.contentItem) return out
        var kids = v.contentItem.children
        for (var i = 0; i < kids.length; i++)
            if (kids[i].listingIndex !== undefined) out.push(kids[i])
        return out
    }
    function parkedDelegates() {
        var n = 0, all = root.delegates()
        for (var i = 0; i < all.length; i++)
            if (all[i].prebuilt === true) n += 1
        return n
    }

    function land(path, total, rows) {
        var p = root.stubPane
        p.listInFlight = true
        p.total = 0
        p.held = 0
        p.rows = []
        p.cursorIndex = 0
        p.listingState = "loading"
        p.rows = rows
        p.total = total
        p.path = path
        p.listingState = "ready"
        p.listInFlight = false
    }

    function checkViewport(prefix) {
        var v = root.view(), p = root.stubPane
        for (var i = 0; i < p.visibleRows; i++) {
            var it = v.itemAtIndex(i)
            if (!it) { root.failures.push("landing: viewport row " + i + " has no delegate"); return }
            if (!it.live || !it.visible) { root.failures.push("landing: viewport row " + i + " is not live and drawn"); return }
            var want = prefix + root.pad(i) + ".txt"
            if (!it.row || it.row.n !== want) { root.failures.push("landing: viewport row " + i + " shows " + (it.row ? it.row.n : "null")); return }
        }
    }

    // A key keeps the tick count beside its time, so a tick in the key's own millisecond counts only if it ran after the key.
    function press() {
        root.stubPane.inputAt = Date.now()
        root.keyTimes.push({ at: root.stubPane.inputAt, tick: root.view().prebuildTickAt.length })
    }
    function checkKeys() {
        var ticks = root.view().prebuildTickAt || []
        for (var k = 0; k < root.keyTimes.length; k++)
            for (var i = root.keyTimes[k].tick; i < ticks.length; i++)
                if (ticks[i] - root.keyTimes[k].at < 16)
                    root.failures.push("key: a tick ran " + (ticks[i] - root.keyTimes[k].at) + " ms after a key")
    }

    function go(next) { root.phase = next; root.phaseAt = Date.now() }
    function elapsed() { return Date.now() - root.phaseAt }
    function full(rows) { return root.view().model.warmRows - rows }
    // About 1 s after the change, a 150 ms window must hold no wake or a parked row for every wake.
    function settle(name, next) { root.settleName = name; root.settleNext = next; root.settleSnap = null; root.go("settle") }
    function holdStart() { var v = root.view(); root.wakesBefore = v.prebuildWakes; root.parkedBefore = v.parkedCount }
    // A hold may wake the driver once to park it and once to end it, never on every 16 ms turn.
    function holdCheck(name) {
        var v = root.view(), wakes = v.prebuildWakes - root.wakesBefore
        if (wakes > 3) root.failures.push(name + ": " + wakes + " wakes in " + Math.round(root.elapsed()) + " ms of the hold, want at most 3")
        else console.log("LISTPREBUILD " + name + " hold " + wakes + " wakes in " + Math.round(root.elapsed()) + " ms")
        if (v.parkedCount > root.parkedBefore) root.failures.push(name + ": parked " + (v.parkedCount - root.parkedBefore) + " rows inside the hold")
    }
    // Waits for the pool to reach want, or fails once the deadline passes.
    function waitFull(name, want, next) {
        var v = root.view()
        if (v.parkedCount === want) { root.go(next); return true }
        if (Date.now() > root.deadline) { root.failures.push(name + ": parked=" + v.parkedCount + " want=" + want + " after " + Math.round(root.elapsed()) + " ms"); root.go(next); return true }
        return false
    }

    function finish() {
        if (root.finished) return
        root.finished = true
        if (root.failures.length > 0) console.log("LISTPREBUILD FAIL " + root.failures.slice(0, 10).join("; "))
        else console.log("LISTPREBUILD DONE warmRows=" + root.view().model.warmRows + " parked=" + root.view().parkedCount)
        Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }

    Timer { id: key2; interval: 8; repeat: false; onTriggered: root.press() }

    Timer {
        interval: 40
        running: true
        repeat: true
        onTriggered: {
            var v = root.view(), p = root.stubPane
            if (!v || root.finished) return
            if (root.firstCountAt < 0 && v.prebuildCountAt !== undefined && v.prebuildCountAt >= 0)
                root.firstCountAt = v.prebuildCountAt
            if (root.phase === "start") {
                if (v.prebuildTickAt === undefined || v.parkedCount === undefined || v.createdCount === undefined || v.prebuildWakes === undefined) {
                    root.failures.push("prebuild: the view has no parked pool or wake count")
                    root.finish()
                    return
                }
                root.holdStart()
                root.land("/probe", 1, root.parentRows)
                root.go("hold")
            } else if (root.phase === "hold") {
                // (g) The first landing's hold: no parked row and no 16 ms wakes before it ends.
                var holdMs = v.prebuildHoldMs
                if (root.firstCountAt < 0 || Date.now() - root.firstCountAt < holdMs - 120) return
                if (Date.now() - root.firstCountAt >= holdMs) root.failures.push("hold: the hold ended before the check ran")
                root.holdCheck("first")
                if (root.parkedDelegates() > 0) root.failures.push("hold: " + root.parkedDelegates() + " parked rows within the hold after the first landing")
                root.go("keys")
            } else if (root.phase === "keys") {
                if (v.prebuildTickAt.length >= 2) {
                    root.press()
                    key2.restart()
                    root.deadline = Date.now() + 2000
                    root.go("fill")
                }
            } else if (root.phase === "fill") {
                // (b) A 1-row folder with no larger one before fills its pool after the hold, then the driver stops.
                if (!root.waitFull("fill", root.full(1), "idle")) return
            } else if (root.phase === "idle") {
                var all = root.delegates(), live = 0
                for (var j = 0; j < all.length; j++) {
                    if (all[j].live) { live += 1; continue }
                    if (!all[j].prebuilt || all[j].visible) root.failures.push("idle: a pooled row is drawn")
                }
                console.log("LISTPREBUILD idle warmRows=" + v.model.warmRows + " parked=" + v.parkedCount + " live=" + live)
                if (live !== 1) root.failures.push("idle: " + live + " live delegates, want 1")
                root.checkKeys()
                if (Date.now() - root.firstCountAt < v.prebuildHoldMs)
                    root.failures.push("pool: filled " + Math.round(Date.now() - root.firstCountAt) + " ms after the first landing, inside the hold")
                else console.log("LISTPREBUILD pool filled " + Math.round(Date.now() - root.firstCountAt) + " ms after the first landing")
                root.settle("b", "big")
            } else if (root.phase === "big") {
                root.createdBefore = v.createdCount
                root.land("/probe/big", 1000, root.rowsFor("f_", 1000))
                if (v.createdCount !== root.createdBefore) root.failures.push("landing: built " + (v.createdCount - root.createdBefore) + " delegates, want 0")
                if (v.parkedCount > 4) root.failures.push("landing: parked=" + v.parkedCount + ", the viewport did not adopt the pool")
                root.checkViewport("f_")
                root.ticksBefore = v.prebuildTickAt.length
                root.go("after")
            } else if (root.phase === "after") {
                if (root.elapsed() < 300) return
                if (v.createdCount !== root.createdBefore) root.failures.push("after: " + (v.createdCount - root.createdBefore) + " delegates built in the 300 ms after the landing")
                if (v.prebuildTickAt.length !== root.ticksBefore) root.failures.push("after: a prebuild tick ran in the 300 ms after the landing")
                // (a) 1000 rows, then a 1-row folder: no new hold, and the refill parks every row it takes from the pool.
                root.land("/probe", 1, root.parentRows)
                root.ticksBefore = v.prebuildTickAt.length
                root.go("rehold")
            } else if (root.phase === "rehold") {
                if (v.prebuildCountAt !== root.firstCountAt) { root.failures.push("rehold: prebuildCountAt moved on the second landing, the pool holds again"); root.firstCountAt = v.prebuildCountAt }
                if (root.elapsed() < 500) return
                if (v.prebuildTickAt.length <= root.ticksBefore) root.failures.push("rehold: no prebuild tick within 500 ms after the second landing")
                else console.log("LISTPREBUILD rehold ticks resumed " + (v.prebuildTickAt.length - root.ticksBefore) + " ticks within 500 ms after the second landing")
                root.deadline = Date.now() + 1500
                root.go("refill")
            } else if (root.phase === "refill") {
                if (!root.waitFull("refill", root.full(1), "refilled")) return
            } else if (root.phase === "refilled") {
                var rows = root.delegates(), stray = 0, low = -1, high = -1
                for (var r = 0; r < rows.length; r++) {
                    if (rows[r].DelegateModel.inPersistedItems === true && !rows[r].prebuilt) stray += 1
                    if (rows[r].prebuilt) { low = low < 0 ? rows[r].index : Math.min(low, rows[r].index); high = Math.max(high, rows[r].index) }
                }
                if (stray > 0) root.failures.push("refill: " + stray + " persisted rows are not parked")
                if (low !== 1 || high !== v.model.warmRows - 1) root.failures.push("refill: parked rows " + low + ".." + high + ", want 1.." + (v.model.warmRows - 1))
                root.settle("a", "back")
            } else if (root.phase === "back") {
                // (e) Back to the large folder after (a) adopts the refill with 0 built and wants nothing more.
                root.createdBefore = v.createdCount
                var before = root.delegates().length
                root.land("/probe/big", 1000, root.rowsFor("g_", 1000))
                if (v.createdCount !== root.createdBefore) root.failures.push("refill: the next landing built " + (v.createdCount - root.createdBefore) + " delegates, want 0")
                else console.log("LISTPREBUILD refill adopted with 0 built, " + before + " delegates before the landing")
                root.checkViewport("g_")
                root.settle("e", "short")
            } else if (root.phase === "short") {
                // (c) A folder shorter than warmRows parks only the rows past its own.
                root.land("/probe/short", 10, root.rowsFor("s_", 10))
                root.deadline = Date.now() + 1500
                root.go("shortfill")
            } else if (root.phase === "shortfill") {
                if (!root.waitFull("short", root.full(10), "shortsettle")) return
            } else if (root.phase === "shortsettle") {
                root.settle("c", "warm")
            } else if (root.phase === "warm") {
                // (f) Search warm held for 1 s holds the driver, which refills once warm ends.
                root.holdStart()
                v.model.warm = true
                root.parkedBefore = v.parkedCount
                root.go("warmheld")
            } else if (root.phase === "warmheld") {
                if (root.elapsed() < 1000) return
                root.holdCheck("warm")
                v.model.warm = false
                root.deadline = Date.now() + 1500
                root.go("warmfill")
            } else if (root.phase === "warmfill") {
                if (!root.waitFull("warm", root.full(10), "warmsettle")) return
            } else if (root.phase === "warmsettle") {
                root.settle("f", "rename")
            } else if (root.phase === "rename") {
                // A rename open across a landing holds the driver, which refills once the rename closes.
                root.land("/probe", 1, root.parentRows)
                p.renamingIndex = 999
                root.holdStart()
                root.go("renameheld")
            } else if (root.phase === "renameheld") {
                if (root.elapsed() < 1000) return
                root.holdCheck("rename")
                p.renamingIndex = -1
                root.deadline = Date.now() + 1500
                root.go("renamefill")
            } else if (root.phase === "renamefill") {
                if (!root.waitFull("rename", root.full(1), "renamesettle")) return
            } else if (root.phase === "renamesettle") {
                root.settle("rename", "flight")
            } else if (root.phase === "flight") {
                // A listing left in flight holds the driver, which refills once the listing lands.
                root.land("/probe/short", 10, root.rowsFor("s_", 10))
                root.land("/probe", 1, root.parentRows)
                p.listInFlight = true
                root.holdStart()
                root.go("flightheld")
            } else if (root.phase === "flightheld") {
                if (root.elapsed() < 1000) return
                root.holdCheck("flight")
                p.listInFlight = false
                root.deadline = Date.now() + 1500
                root.go("flightfill")
            } else if (root.phase === "flightfill") {
                if (!root.waitFull("flight", root.full(1), "flightsettle")) return
            } else if (root.phase === "flightsettle") {
                root.settle("flight", "hide")
            } else if (root.phase === "hide") {
                // (d) Hidden drops the pool and never wakes the driver; shown again refills it.
                v.visible = false
                root.holdStart()
                root.go("hidden")
            } else if (root.phase === "hidden") {
                if (root.elapsed() < 300) return
                if (v.parkedCount !== 0) root.failures.push("hide: parked=" + v.parkedCount + ", want 0")
                else console.log("LISTPREBUILD hide dropped the pool")
                if (v.prebuildWakes - root.wakesBefore > 1) root.failures.push("hide: " + (v.prebuildWakes - root.wakesBefore) + " wakes while hidden")
                v.visible = true
                root.deadline = Date.now() + 2000
                root.go("showfill")
            } else if (root.phase === "showfill") {
                if (!root.waitFull("show", root.full(1), "showsettle")) return
            } else if (root.phase === "showsettle") {
                root.settle("d", "done")
            } else if (root.phase === "settle") {
                if (root.settleSnap === null) {
                    if (root.elapsed() < 1000) return
                    root.settleSnap = { at: Date.now(), wakes: v.prebuildWakes, parked: v.parkedCount }
                    return
                }
                if (Date.now() - root.settleSnap.at < 150) return
                var dw = v.prebuildWakes - root.settleSnap.wakes, dp = v.parkedCount - root.settleSnap.parked
                console.log("LISTPREBUILD spin " + root.settleName + " want=" + v.prebuildWant + " parked=" + v.parkedCount + " alive=" + root.delegates().length
                            + " wakes=" + dw + " tickAge=" + (v.prebuildWakeAt < 0 ? -1 : Math.round(Date.now() - v.prebuildWakeAt)))
                if (dw > 0 && dp < dw) root.failures.push("spin " + root.settleName + ": " + dw + " wakes parked " + dp + " rows in 150 ms, 1 s after the change")
                root.go(root.settleNext)
            } else if (root.phase === "done") {
                root.finish()
            }
        }
    }

    Timer {
        interval: 45000
        running: true
        onTriggered: { root.failures.push("timeout in phase " + root.phase); root.finish() }
    }
    Component.onCompleted: Flea.ViewState.setTextSize({ mode: 14 })
}
