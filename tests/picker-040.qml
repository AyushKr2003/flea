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
    }

    // The answer writes its reply and then ends this process, so the verdict goes out on the flag, before the write.
    Connections {
        target: root.win
        enabled: root.stage === 9
        function onAnsweredChanged() {
            if (!root.win.answered) return
            root.check("a typed file path answers", root.win.answered, true)
            root.check("a file lists its folder once", root.listings - root.listingsBefore, 1)
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
                }
                root.stage = 1
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
            // An absolute folder path: set through the field's own text, then Enter
            // through keys. Per-char typing cannot carry case here: TestEvent
            // drops Shift for letters (the climb above proves key delivery).
            if (stage === 3 && scenario === "path") {
                if (Date.now() - root.stamp < root.settleWaitMs) return
                // The field is not typed into until the Jump's ask has gone through the picker's worker and come back.
                if (!root.pathEntry().jump.answered) return
                var open = root.openFields()
                if (open.length !== 1) return
                // The dropdown opens flush under the strip: its top is the strip's 27 px, never over the strip's rule.
                var dropdown = root.pathEntry().jump.mapToItem(null, 0, 0).y - root.pathEntry().parent.mapToItem(null, 0, 0).y
                root.check("the dropdown opens under the 27 px strip", dropdown, 27)
                open[0].text = root.startFolder()
                open[0].cursorPosition = open[0].text.length
                root.listingsBefore = root.listings
                root.press(Qt.Key_Return)
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
            }
        }
    }
}
