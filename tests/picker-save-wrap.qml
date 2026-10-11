//@ pragma ShellId flea-picker-save-wrap-test
import QtQuick
import Quickshell
import "flea" as Flea

// The real PickerSave's collision line wraps at name joints or spaces at large text sizes, inside its column.
ShellRoot {
    id: root
    readonly property var sizes: [14, 18]
    // Dots and one underscore, no spaces or hyphens: only the joints under test can break the name.
    readonly property string longName: "quarterly.report.june_2026.final.export.reviewed.pdf"
    readonly property string shortName: "export.txt"
    readonly property string tail: " already exists here · review before continuing"
    readonly property string zwsp: String.fromCharCode(8203)
    readonly property real epsilon: 1
    property var stages: []
    property int stageIndex: -1
    property int ticks: 0
    property int checks: 0
    property var failures: []
    property real shortImplicit: 0

    Flea.PickerSave {
        id: saveCard
        picker: fakePicker
        width: 280
        maximumHeight: 2000
    }

    QtObject {
        id: fakePicker
        property bool saving: true
        property bool submitting: false
        property string path: "/tmp"
        property string saveName: "export.txt"
        property string saveError: ""
        property bool saveCollision: true
        property var req: ({ name: "export.txt" })
        function stepFocus() {}
        function control() { return null }
        function cancel() {}
        function accept() {}
    }

    // Text exposes no per-char geometry, so a read-only TextEdit mirrors the status line exactly.
    TextEdit {
        id: mirror
        opacity: 0
        enabled: false
        readOnly: true
        textFormat: TextEdit.PlainText
        text: saveCard.statusItem.text
        width: saveCard.statusItem.width
        wrapMode: saveCard.statusItem.wrapMode
        font.family: saveCard.statusItem.font.family
        font.pixelSize: saveCard.statusItem.font.pixelSize
    }

    // The same short message without joints, so one-line draws prove pixel-identical.
    Text {
        id: reference
        opacity: 0
        enabled: false
        textFormat: Text.PlainText
        text: root.shortName + root.tail
        width: saveCard.statusItem.width
        wrapMode: saveCard.statusItem.wrapMode
        font.family: saveCard.statusItem.font.family
        font.pixelSize: saveCard.statusItem.font.pixelSize
    }

    function check(cond, label) {
        root.checks++
        if (!cond) {
            root.failures.push(label)
            console.log("PICKERSAVEWRAP FAIL " + label)
        }
    }

    function rows() {
        var text = mirror.text
        var groups = []
        for (var i = 0; i < text.length; i++) {
            var y = Math.round(mirror.positionToRectangle(i).y)
            if (groups.length === 0 || groups[groups.length - 1].y !== y)
                groups.push({ y: y, start: i, end: i })
            else
                groups[groups.length - 1].end = i
        }
        return { text: text, groups: groups }
    }

    function widest() {
        var text = mirror.text
        var far = 0
        for (var i = 0; i < text.length; i++) {
            var r = mirror.positionToRectangle(i)
            far = Math.max(far, r.x + r.width)
        }
        return far
    }

    function checkWrap() {
        var line = saveCard.statusItem
        check(mirror.lineCount === line.lineCount, "mirror follows the status line")
        check(line.lineCount >= 2, "the long name wraps at this width")
        var seen = rows()
        var bad = ""
        for (var g = 0; g + 1 < seen.groups.length; g++) {
            var last = seen.text[seen.groups[g].end]
            var next = seen.text[seen.groups[g].end + 1]
            if (last !== " " && last !== root.zwsp && last !== "-" && next !== " ")
                bad += "row" + g + " ends " + JSON.stringify(last) + " before " + JSON.stringify(next) + "; "
        }
        check(bad === "", "rows end at word joints" + (bad === "" ? "" : ": " + bad))
        check(widest() <= line.width + root.epsilon, "paint stays inside the column")
        check(line.height + 0.5 >= line.implicitHeight, "the row follows the text, unclipped")
        check(line.implicitHeight > root.shortImplicit, "the row grows past its short baseline")
    }

    function applyStage() {
        var stage = root.stages[root.stageIndex]
        saveCard.width = stage.width
        Flea.ViewState.setTextSize({ mode: stage.size })
        fakePicker.saveName = stage.name
    }

    function runStage() {
        var stage = root.stages[root.stageIndex]
        var line = saveCard.statusItem
        if (stage.kind === "record") {
            root.shortImplicit = line.implicitHeight
            return
        }
        if (stage.kind === "wrap") {
            checkWrap()
            return
        }
        check(line.lineCount === 1 && reference.lineCount === 1, "the short name fits one line wide")
        check(Math.abs(line.contentWidth - reference.contentWidth) < 0.5, "one-line draw is pixel-identical")
    }

    Component.onCompleted: {
        var out = []
        for (var s = 0; s < root.sizes.length; s++) {
            out.push({ kind: "record", size: root.sizes[s], width: 280, name: root.shortName })
            out.push({ kind: "wrap", size: root.sizes[s], width: 280, name: root.longName })
            out.push({ kind: "wide", size: root.sizes[s], width: 840, name: root.shortName })
        }
        root.stages = out
    }

    Timer {
        interval: 50
        running: true
        repeat: true
        onTriggered: {
            if (root.stages.length === 0)
                return
            if (root.stageIndex === -1) {
                root.stageIndex = 0
                root.applyStage()
                root.ticks = 0
                return
            }
            root.ticks++
            if (root.ticks < 4)
                return
            root.runStage()
            root.ticks = 0
            root.stageIndex++
            if (root.stageIndex >= root.stages.length) {
                if (root.failures.length === 0)
                    console.log("PICKERSAVEWRAP PASS " + root.checks + " checks")
                console.log("PICKERSAVEWRAP DONE checks=" + root.checks + " failed=" + root.failures.length)
                Quickshell.execDetached(["kill", String(Quickshell.processId)])
            } else {
                root.applyStage()
            }
        }
    }
}
