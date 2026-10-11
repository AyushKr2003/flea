//@ pragma ShellId flea-listprebuild-test

import QtQuick
import Quickshell
import QtQml.Models
import "flea" as Flea

// listprebuild: quiet turns prebuild parked rows for the next landing, which adopts them with 0 built.
// No parked row within the first landing's hold, the pool fills after it, a later landing is not held, and a refill parks every row it takes.
ShellRoot {
    id: root

    property var failures: []
    property bool finished: false
    property int step: 0
    property var keyTimes: []
    property bool keysDone: false
    property bool supported: true
    property var before: []
    property bool landed: false
    property int createdBefore: 0
    property int ticksBefore: 0
    property double watchStart: 0
    property bool watching: false
    property bool hid: false
    property double firstCountAt: -1
    property bool holdChecked: false
    property int secondTicksBefore: 0
    property double secondWatchStart: 0
    property bool secondWatching: false
    property bool restampSeen: false
    property bool refilling: false

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

    function finish() {
        if (root.finished) return
        root.finished = true
        if (root.failures.length > 0) console.log("LISTPREBUILD FAIL " + root.failures.slice(0, 8).join("; "))
        else console.log("LISTPREBUILD DONE warmRows=" + root.view().model.warmRows + " parked=" + root.view().parkedCount)
        Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }

    Timer { id: key2; interval: 8; repeat: false; onTriggered: root.press() }

    Timer {
        interval: 120
        running: true
        repeat: true
        onTriggered: {
            var v = root.view()
            if (!v) return
            if (root.firstCountAt < 0 && v.prebuildCountAt !== undefined && v.prebuildCountAt >= 0)
                root.firstCountAt = v.prebuildCountAt
            if (root.step === 0) {
                root.land("/probe", 1, root.parentRows)
            } else if (!root.supported) {
                root.finish()
                return
            } else if (v.prebuildTickAt === undefined || v.parkedCount === undefined || v.createdCount === undefined) {
                root.supported = false
                root.failures.push("prebuild: the view has no parked pool")
                root.before = root.delegates()
                root.land("/probe/big", 1000, root.rowsFor("f_", 1000))
                var n = 0, after = root.delegates()
                for (var i = 0; i < after.length; i++) if (root.before.indexOf(after[i]) < 0) n += 1
                root.failures.push("landing: built " + n + " delegates, want 0")
                root.finish()
                return
            } else if (!root.holdChecked && !root.landed && root.firstCountAt >= 0 && Date.now() - root.firstCountAt >= 150) {
                // (a) Inside the hold after the first non-empty landing: no parked rows yet.
                // Runs before any landing, so a missing hold cannot hide behind the adopted pool.
                root.holdChecked = true
                var holdMs = (v.prebuildHoldMs === undefined) ? 1000 : v.prebuildHoldMs
                if (Date.now() - root.firstCountAt < holdMs) {
                    if (v.parkedCount !== 0) root.failures.push("hold: parked=" + v.parkedCount + " within the hold after the first landing")
                    var held = root.parkedDelegates()
                    if (held > 0) root.failures.push("hold: " + held + " parked rows within the hold after the first landing")
                    else if (v.parkedCount === 0) console.log("LISTPREBUILD hold no parked rows " + Math.round(Date.now() - root.firstCountAt) + " ms after the first landing")
                } else {
                    root.failures.push("hold: the hold ended before the check ran")
                }
            } else if (!root.keysDone) {
                if (v.prebuildTickAt.length >= 2) {
                    root.press()
                    key2.restart()
                    root.keysDone = true
                }
            } else if (!root.landed) {
                var want = v.model.warmRows - 1
                if (v.parkedCount === want) {
                    var all = root.delegates(), live = 0
                    for (var j = 0; j < all.length; j++) {
                        if (all[j].live) { live += 1; continue }
                        if (!all[j].prebuilt || all[j].visible) root.failures.push("idle: a pooled row is drawn")
                    }
                    console.log("LISTPREBUILD idle warmRows=" + v.model.warmRows + " parked=" + v.parkedCount + " live=" + live)
                    if (live !== 1) root.failures.push("idle: " + live + " live delegates, want 1")
                    root.checkKeys()
                    // (b) The pool fills only after the hold has ended.
                    if (root.firstCountAt >= 0 && Date.now() - root.firstCountAt < v.prebuildHoldMs)
                        root.failures.push("pool: filled " + Math.round(Date.now() - root.firstCountAt) + " ms after the first landing, inside the hold")
                    else console.log("LISTPREBUILD pool filled " + Math.round(Date.now() - root.firstCountAt) + " ms after the first landing")
                    root.createdBefore = v.createdCount
                    root.land("/probe/big", 1000, root.rowsFor("f_", 1000))
                    if (v.createdCount !== root.createdBefore) root.failures.push("landing: built " + (v.createdCount - root.createdBefore) + " delegates, want 0")
                    if (v.parkedCount > 4) root.failures.push("landing: parked=" + v.parkedCount + ", the viewport did not adopt the pool")
                    root.checkViewport("f_")
                    root.landed = true
                    root.ticksBefore = v.prebuildTickAt.length
                    root.watchStart = Date.now()
                    root.watching = true
                }
            } else if (root.watching) {
                if (Date.now() - root.watchStart >= 300) {
                    root.watching = false
                    if (v.createdCount !== root.createdBefore) root.failures.push("after: " + (v.createdCount - root.createdBefore) + " delegates built in the 300 ms after the landing")
                    if (v.prebuildTickAt.length !== root.ticksBefore) root.failures.push("after: a prebuild tick ran in the 300 ms after the landing")
                    // (c) A second landing right after the hold: small again, so the pool wants rows.
                    // It must not hold again: ticks resume without a new 1000 ms wait.
                    root.land("/probe", 1, root.parentRows)
                    root.secondTicksBefore = v.prebuildTickAt.length
                    root.secondWatchStart = Date.now()
                    root.secondWatching = true
                }
            } else if (root.secondWatching) {
                if (v.prebuildCountAt !== root.firstCountAt && !root.restampSeen) {
                    root.restampSeen = true
                    root.failures.push("rehold: prebuildCountAt moved on the second landing, the pool holds again")
                }
                if (Date.now() - root.secondWatchStart >= 500) {
                    root.secondWatching = false
                    if (v.prebuildTickAt.length <= root.secondTicksBefore)
                        root.failures.push("rehold: no prebuild tick within 500 ms after the second landing")
                    else console.log("LISTPREBUILD rehold ticks resumed " + (v.prebuildTickAt.length - root.secondTicksBefore) + " ticks within 500 ms after the second landing")
                    root.refilling = true
                }
            } else if (root.refilling) {
                // (d) The refill after a shrink parks every row it takes, pooled ones too, and the next landing adopts it with 0 built.
                if (v.parkedCount === v.model.warmRows - 1) {
                    root.refilling = false
                    var rows = root.delegates(), stray = 0, low = -1, high = -1
                    for (var r = 0; r < rows.length; r++) {
                        if (rows[r].DelegateModel.inPersistedItems === true && !rows[r].prebuilt) stray += 1
                        if (rows[r].prebuilt) { low = low < 0 ? rows[r].index : Math.min(low, rows[r].index); high = Math.max(high, rows[r].index) }
                    }
                    if (stray > 0) root.failures.push("refill: " + stray + " persisted rows are not parked")
                    if (low !== 1 || high !== v.model.warmRows - 1) root.failures.push("refill: parked rows " + low + ".." + high + ", want 1.." + (v.model.warmRows - 1))
                    root.createdBefore = v.createdCount
                    root.land("/probe/big", 1000, root.rowsFor("g_", 1000))
                    if (v.createdCount !== root.createdBefore) root.failures.push("refill: the next landing built " + (v.createdCount - root.createdBefore) + " delegates, want 0")
                    else console.log("LISTPREBUILD refill adopted with 0 built, " + rows.length + " delegates before the landing")
                    root.checkViewport("g_")
                    v.visible = false
                    root.hid = true
                }
            } else if (root.hid) {
                if (v.parkedCount !== 0) root.failures.push("hide: parked=" + v.parkedCount + ", want 0")
                else console.log("LISTPREBUILD hide dropped the pool")
                root.finish()
                return
            }
            if (root.step > 200) { root.failures.push("timeout at step " + root.step); root.finish(); return }
            root.step += 1
        }
    }

    Timer {
        interval: 30000
        running: true
        onTriggered: { root.failures.push("timeout at step " + root.step); root.finish() }
    }
    Component.onCompleted: Flea.ViewState.setTextSize({ mode: 14 })
}
