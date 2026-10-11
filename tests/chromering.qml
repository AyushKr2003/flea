//@ pragma ShellId flea-chromering-test

import QtQuick
import Quickshell
import qs.Commons
import "flea" as Flea
import "button-probe.js" as Probe

// tests/chromering.sh's harness: the real ui/ChromeButton.qml, whose foreground hairline frame ButtonSystem040 A draws only for the keyboard, on every mark and every theme.
ShellRoot {
    id: root

    // Qt Quick needs the window mapped and a frame laid out before a size is read.
    readonly property int layoutMs: 300
    readonly property int ringBoard: 24
    // The keyboard frame is one hairline in the foreground on every theme.
    readonly property int boardStop: 14
    // Theme's own ratios: the strip is this share of a row, and a row is its line box (1.8 x bodySmall) plus the padding above and below.
    readonly property real chromeRowRatio: 0.72
    readonly property real lineBoxRatio: 1.8
    // Every stop the Display section offers, from the smallest strip to the largest.
    readonly property var stops: [9, 10, 11, 12, 14, 16, 20]
    // The ask strip answers are measured after a settle tick, since Row and text relayout lag the size switch.
    readonly property var stripSizes: [12, 14, 16]
    property int stripIdx: 0
    property bool stripSettled: false
    property int checks: 0
    property var failures: []

    function check(label, actual, expected) {
        root.checks += 1
        if (actual === expected) {
            console.log("CHROMERING ok " + label)
            return
        }
        root.failures.push(label)
        console.log("CHROMERING FAIL " + label + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected))
    }
    function quit() { Quickshell.execDetached(["kill", String(Quickshell.processId)]) }
    function report() {
        if (root.failures.length === 0)
            console.log("CHROMERING PASS " + root.checks + " checks")
        root.quit()
    }

    FloatingWindow {
        implicitWidth: 320
        implicitHeight: 200
        color: Flea.Theme.color.background

        Row {
            spacing: 12
            Flea.ChromeButton { id: rest; glyph: "x" }
            Flea.ChromeButton { id: hot; glyph: "x"; keyboardFocused: true }
            // The picker's answer in its strip: a strip DialogButton keeps the inset.
            Flea.DialogButton { id: answer; label: "Answer"; inStrip: true }
            Flea.ChromeButton { id: off; glyph: "x"; keyboardFocused: true; enabled: false }
            Flea.ChromeButton { id: muted; glyph: "x"; keyboardFocused: true; restingColor: Flea.Theme.color.muted }
            Flea.ChromeButton { id: lit; glyph: "x"; active: true; keyboardFocused: true }
        }

        // A strip that draws its rule in the hit box's last row, as the PDF and Markdown Quick Look strips do.
        Item {
            id: strip
            y: 60
            width: 120
            height: Flea.Theme.chromeHeight
            Rectangle { id: stripRule; anchors.bottom: parent.bottom; width: parent.width; height: Flea.Theme.spacing.hairline; color: Flea.Theme.color.foreground }
            Row {
                spacing: 12
                Flea.ChromeButton { id: ruled; glyph: "x"; keyboardFocused: true; ruleRows: Flea.Theme.spacing.hairline }
                Flea.ChromeButton { id: bare; glyph: "x"; keyboardFocused: true }
            }
        }

        // A ruled strip mark beside the Network form's focused field, whose accent frame the mark must not take.
        Row {
            y: 100
            spacing: 12
            Flea.ChromeButton { id: lined; glyph: "x"; keyboardFocused: true; ruleRows: Flea.Theme.spacing.hairline }
            Flea.DialogField { id: field; width: 80; label: "Host" }
        }

        // The real picker ask strip with its answers, whose frames must clear the strip rule.
        Item {
            id: pickerHost
            y: 140
            width: 800
            height: 160
            Flea.PickerChrome {
                id: pchrome
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                picker: mockPicker
            }
        }
    }

    // The picker's own face as PickerChrome reads it, copied from tests/button-members.qml.
    QtObject {
        id: mockPicker
        property var req: ({ mode: "open", title: "Choose file", app: "", accept: "", multiple: false, filters: [{ label: "Images" }] })
        property color edge: "#444444"
        property var marks: []
        property bool canAccept: true
        property var history: ["/a"]
        property bool backendUnavailable: false
        property bool submitting: false
        property bool recent: false
        property bool answered: false
        property string path: "/home/x/y"
        property string home: "/home/x"
        property bool showHidden: false
        property bool listingFailed: false
        property int filterIndex: 0
        property string viewMode: "list"
        function stepFocus(from, back) {}
        function control(name, item, available) { return { name: name } }
    }

    Timer {
        interval: root.layoutMs
        running: true
        repeat: false
        onTriggered: root.run()
    }

    Timer {
        id: pickerTimer
        interval: 200
        running: false
        repeat: true
        onTriggered: root.pickerStep()
    }

    // A button with no ring item answers "no ring" for every ring read, so the build before the ring fails on the board's words and not on a TypeError.
    function ringRead(button, read) { return button.ringItem ? read(button.ringItem) : "no ring" }
    function markRead(button, read) { return button.markItem ? read(button.markItem) : "no mark" }
    // What a stop must draw, from the Omarchy tokens the product scales: the icon token over the base size, and the strip off the row's line box.
    function wantMark(stop) { return Math.round(Style.font.icon * stop / Style.font.baseSize) }
    // Board stop 14: 27 band less two 3 insets leaves 21 room, trimmed to the 16 glyph parity is 20.
    readonly property string boardRing: "20x20"
    function wantStrip(stop) {
        var row = Math.round(Flea.Theme.font.bodySmall * root.lineBoxRatio) + 2 * Flea.Theme.spacing.rowPaddingY
        return Math.round(row * root.chromeRowRatio)
    }
    function stopState(stop) { Flea.ViewState.load(JSON.stringify({ display: { textSize: { mode: stop } } })) }

    // Every read is synchronous on the settled layout; hover and press have no reader here because the ring never depends on them.
    function run() {
        var shown = function (ring) { return ring.visible }
        root.stopState(root.boardStop)
        check("the hit box is at least the 24 board square", hot.implicitWidth >= root.ringBoard, true)
        check("a resting mark draws no ring", ringRead(rest, shown), false)
        check("a keyboard-focused mark draws its ring", ringRead(hot, shown), true)
        check("the ring is the inset-sized square at the board's size", ringRead(hot, function (ring) { return ring.width + "x" + ring.height }), root.boardRing)
        check("the frame is one hairline", ringRead(hot, function (ring) { return ring.border.width }), Flea.Theme.spacing.hairline)
        check("the frame is the foreground", ringRead(hot, function (ring) { return String(ring.border.color) }), String(Flea.Theme.color.foreground))
        check("the ring has no fill", ringRead(hot, function (ring) { return ring.color.a }), 0)
        check("a disabled mark draws no ring", ringRead(off, shown), false)
        check("a disabled mark mutes its glyph", markRead(off, function (mark) { return String(mark.color) }), String(Flea.Theme.color.muted))
        check("a muted resting mark inks in the foreground under the ring", markRead(muted, function (mark) { return String(mark.color) }), String(Flea.Theme.color.foreground))
        check("an active mark still takes the ring", ringRead(lit, shown), true)
        check("a resting mark inks in the foreground", markRead(rest, function (mark) { return String(mark.color) }), String(Flea.Theme.color.foreground))
        var marks = {}
        var strips = {}
        for (var i = 0; i < root.stops.length; i++) {
            root.stopState(root.stops[i])
            var tag = "stop " + root.stops[i] + " "
            var inside = function (ring) {
                return ring.x >= 0 && ring.y >= 0 && ring.x + ring.width <= hot.width && ring.y + ring.height <= hot.height }
            var centre = function (ring) {
                return (ring.x * 2 + ring.width) + "," + (ring.y * 2 + ring.height) }
            var markCentre = markRead(hot, function (mark) { return (mark.x * 2 + mark.width) + "," + (mark.y * 2 + mark.height) })
            check(tag + "the ring stays inside the hit box", ringRead(hot, inside), true)
            check(tag + "the ring keeps the control inset above and below", ringRead(hot, function (ring) { return ring.y >= Flea.Theme.chromeControlInset && hot.height - ring.y - ring.height >= Flea.Theme.chromeControlInset }), true)
            check(tag + "the ring shares the glyph's centre, so both sit on whole pixels together", ringRead(hot, centre), markCentre)
            check(tag + "the glyph keeps the chrome mark size under the ring", markRead(hot, function (mark) { return mark.width }), Flea.Theme.chromeMarkSize)
            check(tag + "the mark is the icon token scaled to the stop", markRead(hot, function (mark) { return mark.width }), root.wantMark(root.stops[i]))
            check(tag + "the hit box is as wide as the larger of the 24 floor and the mark", hot.width, Math.max(root.ringBoard, root.wantMark(root.stops[i])))
            check(tag + "the hit box is the strip's height off the row", hot.height, root.wantStrip(root.stops[i]))
            var ruledRing = ringRead(ruled, function (ring) { return ring.y + "," + (ring.y + ring.height) })
            var rows = ruledRing.split(",")
            check(tag + "a ring over a strip rule keeps the inset above it", Number(rows[0]) >= Flea.Theme.chromeControlInset, true)
            check(tag + "a ring over a strip rule keeps the inset between it and the rule", stripRule.y - Number(rows[1]) >= Flea.Theme.chromeControlInset, true)
            check(tag + "a strip answer keeps the inset above it", answer.frameY >= Flea.Theme.chromeControlInset, true)
            check(tag + "a strip answer keeps the inset between it and the rule", answer.height - Flea.Theme.spacing.hairline - answer.frameY - answer.frameHeight >= Flea.Theme.chromeControlInset, true)
            check(tag + "over a strip rule the ring and the glyph still share a centre", ringRead(ruled, centre), markRead(ruled, function (mark) { return (mark.x * 2 + mark.width) + "," + (mark.y * 2 + mark.height) }))
            marks[root.wantMark(root.stops[i])] = true
            strips[root.wantStrip(root.stops[i])] = true
        }
        root.stopState(root.boardStop)
        check("a ring over a strip rule is still the inset-sized square", ringRead(ruled, function (ring) { return ring.width + "x" + ring.height }), root.boardRing)
        check("the stops draw more than one mark size", Object.keys(marks).length > 1, true)
        check("the stops draw more than one hit box height", Object.keys(strips).length > 1, true)
        root.stripIdx = 0
        root.stripSettled = false
        pickerTimer.running = true
    }

    // One size per two ticks: switch, then read the settled ask strip.
    function pickerStep() {
        if (root.stripIdx >= root.stripSizes.length) {
            pickerTimer.running = false
            stripMarks()
            report()
            return
        }
        var size = root.stripSizes[root.stripIdx]
        if (!root.stripSettled) {
            root.stopState(size)
            root.stripSettled = true
            return
        }
        root.stripSettled = false
        root.stripIdx += 1
        root.pickerChecks(size)
    }

    // Each ask answer frame ends at least the control inset above the drawn strip rule.
    function pickerChecks(size) {
        var items = pchrome.focusItems()
        var names = ["cancel", "accept"]
        for (var k = 0; k < 2; k++) {
            var ans = items[k]
            var buttons = ans.parent
            var ask = buttons.parent
            var ruleTop = ask.height - Flea.Theme.spacing.hairline
            for (var i = 0; i < ask.children.length; i++) {
                var c = ask.children[i]
                if (c.height === Flea.Theme.spacing.hairline && c.width === ask.width) { ruleTop = c.y; break }
            }
            var frameBottom = buttons.y + ans.y + ans.frameY + ans.frameHeight
            check("stop " + size + " the picker " + names[k] + " frame keeps the inset above the strip rule",
                ruleTop - frameBottom >= Flea.Theme.chromeControlInset, true)
        }
    }

    // One theme's keyboard frame on a strip mark: the foreground hairline every mark draws, never the focused field's accent line.
    function stripReads(name) {
        // A stroke reads as "width colour", one string, because check compares with ===.
        var stroke = function (ring) { return ring.border.width + " " + Probe.rgba(ring.border.color) }
        var foregroundLine = Flea.Theme.spacing.hairline + " " + Probe.rgba(Flea.Theme.color.foreground)
        check(name + "a strip mark frames itself in the foreground hairline as every mark does", ringRead(lined, stroke), foregroundLine)
        check(name + "a strip mark frames itself as the bare mark beside it does", ringRead(lined, stroke), ringRead(bare, stroke))
        // The same mark read with the keyboard on it and at rest, so a frame drawn without the keyboard fails here on each theme.
        var shown = ringRead(lined, function (ring) { return ring.visible })
        lined.keyboardFocused = false
        var resting = ringRead(lined, function (ring) { return ring.visible })
        lined.keyboardFocused = true
        check(name + "a strip mark draws its frame only for the keyboard", shown + " " + resting, "true false")
        check(name + "a strip mark keeps the inset-sized square", ringRead(lined, function (ring) { return ring.width + "x" + ring.height }), root.boardRing)
        check(name + "a strip mark inks as every framed mark does", markRead(lined, function (mark) { return String(mark.color) }), markRead(ruled, function (mark) { return String(mark.color) }))
    }

    // The preview strips' marks frame themselves as every chrome mark does; no mark carries an accent focus line, whatever the field beside it draws.
    function stripMarks() {
        root.stopState(root.boardStop)
        check("a chrome mark has no focus line to set", lined.focusLine === undefined, true)
        field.takeFocus()
        Flea.Theme.applyColors(Probe.COLOURED_THEME)
        check("the pinned theme's accent has a hue", Flea.Theme.color.accentHasHue, true)
        var stroke = function (item) { return item.border.width + " " + Probe.rgba(item.border.color) }
        check("the field holds the keyboard, so its frame is the accent hairline", [field.focused, stroke(field.input.parent)].join(" "),
              "true " + Flea.Theme.spacing.hairline + " " + Probe.rgba(Flea.Theme.color.accent))
        check("a strip mark's frame is not the focused field's accent line", ringRead(lined, stroke) !== stroke(field.input.parent), true)
        stripReads("coloured: ")
        lined.enabled = false
        check("a disabled strip mark draws no frame", ringRead(lined, function (ring) { return ring.visible }), false)
        lined.enabled = true
        Flea.Theme.applyColors(Probe.KANAGAWA_THEME)
        check("the hueless theme's accent has no hue", Flea.Theme.color.accentHasHue, false)
        stripReads("hueless: ")
    }
}
