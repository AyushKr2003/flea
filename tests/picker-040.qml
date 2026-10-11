import QtQuick
import QtTest
import Quickshell
import "flea" as Flea
import "flea/js/Keymap.js" as Keymap

// Drive the real picker and its real backend, with native Qt key events.
ShellRoot {
    id: root
    property var pickerShell: null
    property var win: null
    property var keys: null
    property string scenario: Quickshell.env("FLEA_PICKER_HUNT_CASE")
    property int stage: 0
    property double stamp: Date.now()
    property int failures: 0
    property int checks: 0
    // The picker's path logic, whose backend counts every listing the typed lines ask for.
    property var logic: null
    property int listings: 0
    property int listingsBefore: 0
    // Rows lines that start past row 0, so a typed file that walked its folder window by window shows here.
    property int walked: 0
    readonly property int pollIntervalMs: 20
    readonly property int deadlineMs: 8000
    readonly property int settleWaitMs: 1000

    function check(label, got, want) {
        checks++
        var ok = JSON.stringify(got) === JSON.stringify(want)
        if (!ok) failures++
        console.log("PICKER_HUNT " + (ok ? "PASS " : "FAIL ") + label
            + " got=" + JSON.stringify(got) + " expected=" + JSON.stringify(want))
    }
    function verdict() {
        console.log("PICKER_HUNT DONE " + checks + " checks, " + failures + " failed")
    }
    function finish() {
        root.verdict()
        Qt.exit(failures ? 1 : 0)
    }
    function descendants(item) {
        var out = [item]
        for (var i = 0; i < out.length; i++) {
            var kids = out[i].children || []
            for (var j = 0; j < kids.length; j++) out.push(kids[j])
        }
        return out
    }
    function press(key, modifiers) { keys.keyClick(key, modifiers || Qt.NoModifier, -1) }
    // Types through native key events, so the field's own handlers read them.
    function typeText(s) {
        for (var i = 0; i < s.length; i++) {
            var ch = s.charAt(i)
            var code = s.charCodeAt(i)
            if (code >= 97 && code <= 122) press(Qt.Key_A + (code - 97), Qt.NoModifier)
            else if (code >= 65 && code <= 90) press(Qt.Key_A + (code - 65), Qt.ShiftModifier)
            else if (code >= 48 && code <= 57) press(Qt.Key_0 + (code - 48), Qt.NoModifier)
            else if (ch === "/") press(Qt.Key_Slash, Qt.NoModifier)
            else if (ch === ".") press(Qt.Key_Period, Qt.NoModifier)
            else if (ch === "-") press(Qt.Key_Minus, Qt.NoModifier)
            else root.check("typeable path char " + ch, false, true)
        }
    }
    function pathEntry() {
        return root.descendants(win.contentItem).filter(function(item) { return item.pathFrame !== undefined })[0]
    }
    function startFolder() {
        try { return JSON.parse(Quickshell.env("FLEA_PICKER")).folder } catch (e) { return "" }
    }
    function pickerLogic() {
        return root.descendants(win.contentItem).filter(function(item) { return item.leaf !== undefined && item.backend !== undefined })[0]
    }
    function openFields() {
        return root.descendants(win.contentItem).filter(function(item) { return item.activeFocus && typeof item.selectAll === "function" })
    }
    // The field is open, settled, and its Jump's ask has come back through the picker's worker.
    function fieldReady() {
        return Date.now() - root.stamp >= root.settleWaitMs && root.pathEntry().jump !== null && root.pathEntry().jump.answered
            && root.openFields().length === 1
    }
    function typeLine(text) {
        var field = root.openFields()[0]
        field.text = text
        field.cursorPosition = text.length
        root.listingsBefore = root.listings
        root.press(Qt.Key_Return)
    }
    // The topmost item at a window point that draws or takes the pointer, in paint order and past its parent's bounds.
    function topmostAt(item, x, y) {
        if (!item.visible || item.opacity === 0) return null
        var local = item.mapFromItem(null, x, y)
        var inside = local.x >= 0 && local.y >= 0 && local.x < item.width && local.y < item.height
        if (item.clip && !inside) return null
        var kids = Array.prototype.slice.call(item.children || [])
        kids = kids.map(function(kid, at) { return [kid, at] }).sort(function(a, b) { return a[0].z - b[0].z || a[1] - b[1] })
        for (var i = kids.length - 1; i >= 0; i--) { var hit = root.topmostAt(kids[i][0], x, y); if (hit) return hit }
        var paints = (item.color !== undefined && item.color.a > 0) || item.acceptedButtons !== undefined
        return inside && paints ? item : null
    }
    function within(item, ancestor) {
        for (var at = item; at; at = at.parent) if (at === ancestor) return true
        return false
    }
    function parentOf(path) {
        var cut = String(path).lastIndexOf("/")
        return cut <= 0 ? "/" : String(path).substring(0, cut)
    }

    Component.onCompleted: {
        var comp = Qt.createComponent("flea/PickerWindow.qml")
        if (comp.status !== Component.Ready) {
            console.log("PICKER_HUNT FAIL compile " + comp.errorString())
            Qt.exit(1)
            return
        }
        pickerShell = comp.createObject(root)
        win = pickerShell.pickerWin
        keys = Qt.createQmlObject("import QtTest; TestEvent {}", win.contentItem)
    }

    Connections {
        target: root.logic ? root.logic.backend : null
        function onListed() { root.listings++ }
        function onRows(start) { if (start > 0) root.walked++ }
    }

    // The answer writes its reply and then ends this process, so the verdict goes out on the flag, before the write.
    Connections {
        target: root.win
        enabled: root.stage === 9 || root.stage === 26
        function onAnsweredChanged() {
            if (!root.win.answered) return
            root.check("a typed file path answers", root.win.answered, true)
            if (root.stage === 9) root.check("a file lists its folder once", root.listings - root.listingsBefore, 1)
            else root.check("a file before the held rows answers with nothing listed", root.listings - root.listingsBefore, 0)
            root.verdict()
        }
    }

    Timer {
        interval: root.pollIntervalMs
        running: true
        repeat: true
        onTriggered: {
            if (Date.now() - root.stamp > root.deadlineMs) {
                var fellows = win ? root.descendants(win.contentItem).filter(function(item) {
                    return item.activeFocus && typeof item.selectAll === "function"
                }) : []
                var lane = fellows.length === 1 ? fellows[0].text : "fields=" + fellows.length
                var note = win ? win.message : "?"
                root.check("probe completes", "timeout stage " + stage + " path=" + (win ? win.path : "?") + " field=" + lane + " msg=" + note, "complete")
                root.finish()
                return
            }
            if (!win || win.listingState !== "ready" || !win.rows.length) return
            if (stage === 0) {
                if (win.saving && !win.saveReady) return
                var rowIndex = win.rows.findIndex(function(row) { return row.n === "a.txt" })
                if (rowIndex < 0) {
                    root.check("missing row a.txt", rowIndex >= 0, true)
                    root.finish()
                    return
                }
                win.cursorIndex = rowIndex + win.held
                win.focusView()
                if (!win.viewItem().activeFocus) return
                root.check("real cursor is a file", win.rowFor(win.cursorIndex).n, "a.txt")
                if (scenario === "path") {
                    root.check("Ctrl+L maps to pathBar", Keymap.lookup(Qt.Key_L, "l", Qt.ControlModifier, "listing"), "pathBar")
                    root.press(Qt.Key_L, Qt.ControlModifier)
                } else if (scenario === "collision") {
                    win.accept()
                } else {
                    root.press(Qt.Key_L, Qt.ControlModifier)
                }
                root.stage = scenario === "far" ? 21 : scenario === "probe" ? 31 : 1
                root.stamp = Date.now()
                return
            }
            if (stage === 1 && Date.now() - root.stamp > root.settleWaitMs && !win.markRequest) {
                if (scenario === "path") {
                    var fields = root.descendants(win.contentItem).filter(function(item) {
                        return item.activeFocus && typeof item.selectAll === "function"
                    })
                    root.check("Ctrl+L focuses path input", fields.length, 1)
                    // The field is the one ChromeBar draws: 23 px at base size 14, centred in whatever strip holds it.
                    var entry = root.pathEntry()
                    var frame = entry.pathFrame
                    root.check("the field is the chrome's own height", frame.height, Flea.Theme.chromeHeight - 4 * frame.border.width)
                    var above = entry.y + frame.y
                    var below = entry.parent.height - above - frame.height
                    root.check("the field is centred in the strip", Math.abs(above - below) <= 1, true)
                    // The board's numbers at base size 14: a 27 px strip holding the chrome's 23 px field.
                    root.check("base size 14 draws the chrome at 27 px", Flea.Theme.chromeHeight, 27)
                    root.check("the path strip is the board's 27 px", entry.parent.height, 27)
                    root.check("the entry takes the chrome's slot", [entry.y, entry.height], [0, 26])
                    root.check("the field is the board's 23 px", frame.height, 23)
                    root.check("the field sits 2 px under the strip's top", above, 2)
                    root.logic = root.pickerLogic()
                    // A relative climb typed through the same keys the board counts.
                    root.typeText("..")
                    root.press(Qt.Key_Return)
                } else if (scenario === "collision") {
                    var form = root.descendants(win.contentItem).filter(function(item) {
                        return item.fieldItem !== undefined && item.askedName !== undefined
                    })[0]
                    root.check("collision focuses Filename", form.fieldItem.activeFocus, true)
                    root.check("collision selects filename stem", form.fieldItem.selectedText, "a")
                    var labels = form.controls().filter(function(item) { return item.visible }).map(function(item) { return item.name })
                    root.check("collision offers Replace", labels.indexOf("Replace") >= 0, true)
                }
                if (scenario === "collision") { root.finish(); return }
                root.stage = 2
                root.stamp = Date.now()
                return
            }
            // A typed climb lands in the parent folder with the field closed.
            if (stage === 2 && scenario === "path") {
                var start = root.startFolder()
                if (win.path !== root.parentOf(start) || root.pathEntry().editing) return
                root.check("a typed climb lands in the parent", win.path, root.parentOf(start))
                root.check("a typed climb leaves Back the way home", win.history[win.history.length - 1], start)
                root.press(Qt.Key_L, Qt.ControlModifier)
                root.stage = 3
                root.stamp = Date.now()
                return
            }
            // An absolute path is set through the field's own text, since TestEvent drops Shift for letters; Enter goes by key.
            if (stage === 3 && scenario === "path") {
                if (Date.now() - root.stamp < root.settleWaitMs) return
                // The field is not typed into until the Jump's ask has gone through the picker's worker and come back.
                if (!root.pathEntry().jump.answered) return
                var open = root.openFields()
                if (open.length !== 1) return
                // The dropdown opens flush under the strip: its top is the strip's 27 px, never over the strip's rule.
                var dropdown = root.pathEntry().jump.mapToItem(null, 0, 0).y - root.pathEntry().parent.mapToItem(null, 0, 0).y
                root.check("the dropdown opens under the 27 px strip", dropdown, 27)
                // The fixture's one favourite answers a typed name, so the dropdown shows over the listing.
                open[0].text = "sub"
                root.stage = 41
                root.stamp = Date.now()
                return
            }
            // The dropdown hangs below the chrome, so it must stand over the places, header and listing drawn after it.
            if (stage === 41 && scenario === "path") {
                var jumpEntry = root.pathEntry()
                if (!jumpEntry.jumpShown || !jumpEntry.jump.dropItem) return
                var chromeItem = jumpEntry.parent.parent
                var dropItem = jumpEntry.jump.dropItem
                var spot = dropItem.mapToItem(null, dropItem.width / 2, dropItem.height / 2)
                root.check("the dropdown point lies below the chrome", spot.y > chromeItem.mapToItem(null, 0, chromeItem.height).y, true)
                var top = root.topmostAt(win.contentItem, spot.x, spot.y)
                root.check("the dropdown is drawn over the listing", root.within(top, dropItem) ? "dropdown" : String(top), "dropdown")
                root.check("the chrome rises over the listing while the dropdown shows", chromeItem.z > 0, true)
                root.typeLine(root.startFolder())
                root.stage = 4
                root.stamp = Date.now()
                return
            }
            if (stage === 4 && scenario === "path") {
                var home = root.startFolder()
                if (win.path !== home || root.pathEntry().editing) return
                root.check("a typed folder path navigates", win.path, home)
                root.check("a typed folder lists once", root.listings - root.listingsBefore, 1)
                root.check(": maps to pathBar", Keymap.lookup(Qt.Key_Colon, ":", Qt.NoModifier, "listing"), "pathBar")
                root.press(Qt.Key_Colon, Qt.NoModifier)
                root.stage = 5
                root.stamp = Date.now()
                return
            }
            // A path that names nothing lists nothing: the field stays open over the folder and the status line says why.
            if (stage === 5 && scenario === "path") {
                if (Date.now() - root.stamp < root.settleWaitMs) return
                var typing = root.openFields()
                if (typing.length !== 1) return
                typing[0].text = root.startFolder() + "/nothing-here.txt"
                root.listingsBefore = root.listings
                root.press(Qt.Key_Return)
                root.stage = 6
                root.stamp = Date.now()
                return
            }
            if (stage === 6 && scenario === "path") {
                if (Date.now() - root.stamp < root.settleWaitMs) return
                var again = root.openFields()
                root.check("a missing path keeps the field open", again.length, 1)
                root.check("a missing path lists nothing", root.listings - root.listingsBefore, 0)
                root.check("a missing path stays in its folder", win.path, root.startFolder())
                root.check("a missing path says why", win.message, root.startFolder() + "/nothing-here.txt does not exist or cannot be reached.")
                if (again.length !== 1) { root.finish(); return }
                // The dialog's filter is Text: a png in this very folder is refused with nothing listed.
                again[0].text = root.startFolder() + "/p.png"
                again[0].cursorPosition = again[0].text.length
                root.listingsBefore = root.listings
                root.press(Qt.Key_Return)
                root.stage = 7
                root.stamp = Date.now()
                return
            }
            if (stage === 7 && scenario === "path") {
                if (Date.now() - root.stamp < root.settleWaitMs) return
                var filtered = root.openFields()
                root.check("a filtered file keeps the field open", filtered.length, 1)
                root.check("a filtered file in this folder lists nothing", root.listings - root.listingsBefore, 0)
                root.check("a filtered file says why", win.message, "p.png is hidden by the file filter or the hidden files setting.")
                if (filtered.length !== 1) { root.finish(); return }
                // The same refusal one folder down: its folder lists once, then the filter judges.
                filtered[0].text = root.startFolder() + "/sub/c.png"
                filtered[0].cursorPosition = filtered[0].text.length
                root.listingsBefore = root.listings
                root.press(Qt.Key_Return)
                root.stage = 8
                root.stamp = Date.now()
                return
            }
            if (stage === 8 && scenario === "path") {
                if (Date.now() - root.stamp < root.settleWaitMs || win.path !== root.startFolder() + "/sub" || win.listingState !== "ready") return
                var sibling = root.openFields()
                root.check("a filtered file in a sibling folder keeps the field open", sibling.length, 1)
                root.check("a filtered file lists its folder once", root.listings - root.listingsBefore, 1)
                root.check("a filtered file in a sibling folder says why", win.message, "c.png is hidden by the file filter or the hidden files setting.")
                if (sibling.length !== 1) { root.finish(); return }
                // A file the filter accepts answers the open dialog, Enter by key, one listing away.
                sibling[0].text = root.startFolder() + "/a.txt"
                sibling[0].cursorPosition = sibling[0].text.length
                root.listingsBefore = root.listings
                root.stage = 9
                root.stamp = Date.now()
                root.press(Qt.Key_Return)
                return
            }
            // A file the filter refuses, in a folder of several windows: located by name, with no window walked and the view kept at its top.
            if (stage === 21) {
                if (!root.fieldReady()) return
                root.logic = root.pickerLogic()
                root.typeLine(root.startFolder() + "/big/zz.png")
                root.stage = 22
                root.stamp = Date.now()
                return
            }
            if (stage === 22) {
                if (Date.now() - root.stamp < root.settleWaitMs || win.path !== root.startFolder() + "/big" || win.listingState !== "ready") return
                root.check("the big folder holds more rows than one window", win.total > win.windowSize, true)
                root.check("a filtered file in a big folder lists its folder once", root.listings - root.listingsBefore, 1)
                root.check("a filtered file in a big folder says why", win.message, "zz.png is hidden by the file filter or the hidden files setting.")
                root.check("a filtered file walks no window", root.walked, 0)
                root.check("a filtered file leaves the view at its top", win.held, 0)
                root.press(Qt.Key_Escape)
                root.stage = 23
                root.stamp = Date.now()
                return
            }
            // End takes the held window to the tail, past the first row the next typed line names.
            if (stage === 23) {
                if (root.pathEntry().editing || !win.viewItem().activeFocus) return
                root.press(Qt.Key_End)
                root.stage = 24
                root.stamp = Date.now()
                return
            }
            if (stage === 24) {
                if (win.cursorIndex !== win.total - 1 || !win.rowFor(win.total - 1) || win.held === 0) return
                root.check("End holds the tail and not the first row", win.rowFor(0), null)
                root.press(Qt.Key_L, Qt.ControlModifier)
                root.stage = 25
                root.stamp = Date.now()
                return
            }
            if (stage === 25) {
                if (!root.fieldReady()) return
                root.typeLine(root.startFolder() + "/big/f000.txt")
                root.stage = 26
                root.stamp = Date.now()
                return
            }
            // A save dialog refuses a typed file through the backend's folder-type mark, and says the backend's sentence.
            if (stage === 31) {
                if (!root.fieldReady()) return
                root.logic = root.pickerLogic()
                root.typeLine(root.startFolder() + "/b.txt")
                root.stage = 32
                root.stamp = Date.now()
                return
            }
            if (stage === 32) {
                if (Date.now() - root.stamp < root.settleWaitMs) return
                root.check("a typed file in a save dialog says the backend's refusal", win.message, "This item is not the requested file type.")
                root.check("a refused file answers nothing", win.answered, false)
                root.check("the refusal ends the probe and leaves no mark request", [win.pathProbe, win.markRequest, win.acceptMarks], [0, 0, false])
                root.check("a refused file keeps the field open", root.openFields().length, 1)
                root.check("a refused file lists nothing", root.listings - root.listingsBefore, 0)
                root.finish()
            }
        }
    }
}
