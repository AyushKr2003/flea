//@ pragma ShellId flea-dialog-board-test

import QtQuick
import QtTest
import Quickshell
import "flea" as Flea
import "flea/js/TextSize.js" as TextSize
import "qml-probe.js" as QmlProbe

// tests/dialog-board.sh's harness, DialogButtons040's and Archives040's critic findings on the shipped files: the check boxes draw no stray ground, the Trash strip's Back and Up are ChromeButtons, and OpenWith's search field sits where the board puts it.
ShellRoot {
    id: shell

    // The reference text size, where the board's numbers are measured (DialogButtons040 at x 1250: rule 818, field 837 to 866, eyebrow ink 898).
    readonly property int pinnedSize: 14
    readonly property int boardRuleToField: 18
    readonly property int boardFieldToEyebrowInk: 31
    readonly property real pressScale: 0.96
    // Two lines are on the same rows when their tops are within half a pixel, and the colour no theme role owns tells accentFrame from accent.
    readonly property real rowTolerance: 0.5
    readonly property color sentinel: "#ff00ff"
    property color accentFrameWas: "transparent"
    // Quiet ticks (the watched values unchanged) before a step is read; a count of frames, never time.
    readonly property int settleTicks: 4
    readonly property int tickMs: 16
    readonly property int outerTimeoutS: Number(Quickshell.env("DIALOGBOARD_TIMEOUT_S")) || 60
    readonly property int capShare: 2
    // The long-error step's length: well past two wrapped lines at any dialog width.
    readonly property int longErrorChars: 300
    readonly property int msPerSecond: 1000
    readonly property double startedAt: Date.now()
    readonly property int capMs: shell.outerTimeoutS * shell.msPerSecond / shell.capShare
    readonly property int noDelay: 0
    // The pointer parks here, clear of both strip controls, and presses are released far outside so no tap fires.
    readonly property int parkX: 700
    readonly property int parkY: 150
    readonly property int releaseOutside: -40
    readonly property int trashRows: 3
    readonly property int milli: 1000
    readonly property string sandboxRoot: Quickshell.env("DIALOGBOARD_ROOT") || ""

    property int checks: 0
    property var failures: []
    property int step: 0
    property int quiet: 0
    property string lastWatch: ""
    property bool acted: false
    property var script: []
    property int backRequests: 0
    property int upActivations: 0
    property var read: ({})

    // Up's own signal, counted where it fires: a dead Up wires no handler, so the view's Back count alone could never see it.
    Connections {
        target: view.upItem
        function onActivated() { shell.upActivations += 1 }
    }

    function log(line) { QmlProbe.log("DIALOGBOARD", line) }
    function check(name, actual, expected) { QmlProbe.checkLoud(shell, name, actual, expected) }
    function finish() {
        QmlProbe.logDone(shell)
        QmlProbe.stepPastEnd(shell)
        Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }
    function rgba(c) {
        return [c.r, c.g, c.b, c.a].map(function (v) { return Math.round(v * shell.milli) / shell.milli }).join(",")
    }
    function round3(v) { return Math.round(v * shell.milli) / shell.milli }
    function isType(o, name) {
        var s = String(o)
        return s.indexOf(name) === 0 || s.indexOf("QQuick" + name) === 0
    }
    // Every item under (and including) root the predicate accepts, depth first.
    function findAll(root, accept) {
        var out = []
        var stack = [root]
        while (stack.length > 0) {
            var o = stack.pop()
            if (accept(o)) out.push(o)
            var kids = (o && o.children !== undefined) ? o.children : []
            for (var i = 0; i < kids.length; i++) stack.push(kids[i])
        }
        return out
    }
    // The tops, in card coordinates and read top to bottom, of the name lines the card draws: its still Text rows or its TextInput fields.
    function namesIn(card, editable) {
        var names = ["IMG_4120.HEIC", "IMG_4121.MOV", "notes.txt"]
        var lines = shell.findAll(card, function (o) {
            return shell.isType(o, "TextInput") === editable && (editable || shell.isType(o, "Text")) && names.indexOf(o.text) >= 0
        })
        return lines.map(function (o) { return o.mapToItem(card, 0, 0).y }).sort(function (a, b) { return a - b })
    }
    function underRoot(path) {
        return shell.sandboxRoot.length > 0 && path.indexOf(shell.sandboxRoot + "/") === 0 && path.split("/").indexOf("..") < 0
    }

    // The colours a surface may paint: every role the theme owns, so a ground the product chose is never mistaken for Qt's default.
    function themedColours() {
        var roles = {}
        for (var key in Flea.Theme.color) {
            var value = Flea.Theme.color[key]
            if (value !== null && typeof value === "object" && value.r !== undefined) roles[shell.rgba(value)] = key
        }
        return roles
    }
    // The rectangles between a check box and its card that paint something the theme does not own, or Qt's own default fill.
    function strayGrounds(box, card) {
        var roles = shell.themedColours()
        var stray = []
        for (var o = box.parent; o; o = o.parent) {
            var painted = shell.isType(o, "Rectangle") && o.visible && o.width > 0 && o.height > 0 && o.color.a > 0
            if (painted && (shell.rgba(o.color) === shell.rgba(defaultFill.color) || roles[shell.rgba(o.color)] === undefined))
                stray.push(String(o).split("(")[0] + " " + shell.rgba(o.color))
            if (o === card) break
        }
        return stray
    }
    function checkBoxes(card) {
        return shell.findAll(card, function (o) { return shell.isType(o, "CheckBox") && o.value !== undefined })
    }
    // The off box draws its frame only: its own rectangle is transparent, so the dialog's ground is the interior.
    function offInterior(box) {
        var inner = box.children[0]
        return { value: box.value, filled: inner.color.a }
    }

    function measureCheckBoxes(label, card, expected) {
        var boxes = shell.checkBoxes(card)
        shell.check(label + ": the card hosts " + expected + " check box", boxes.length, expected)
        for (var i = 0; i < boxes.length; i++) {
            shell.check(label + ": the off box's interior is the dialog's ground, no stray fill above it",
                        shell.strayGrounds(boxes[i], card), [])
            shell.check(label + ": the off box draws its frame only", shell.offInterior(boxes[i]), { value: "off", filled: 0 })
        }
    }

    // Where OpenWith's search field sits against its title rule and its first eyebrow's ink, in the card's own coordinates.
    function searchGeometry() {
        var card = openWith.cardItem
        var field = openWith.fieldItem.parent
        var rule = openWith.titleRuleItem
        var row = openWith.applicationsItem.itemAtIndex(0)
        var eyebrow = shell.findAll(row, function (o) { return shell.isType(o, "Text") && o.text === openWith.rows[0].eyebrow })[0]
        var ruleBottom = rule.mapToItem(card, 0, rule.height).y
        var fieldTop = field.mapToItem(card, 0, 0).y
        var fieldBottom = field.mapToItem(card, 0, field.height).y
        var inkTop = eyebrow.mapToItem(card, 0, 0).y + eyebrow.baselineOffset + capInk.tightBoundingRect.y
        return { ruleToField: shell.round3(fieldTop - ruleBottom), fieldToInk: Math.round(inkTop - fieldBottom) }
    }

    // One dialog's status slot steps: one card height and one button row at rest, busy and short errors; a 300-character error is drawn whole and grows only the card.
    function slotSteps(d) {
        var rest, slot, longError = new Array(shell.longErrorChars + 1).join("e")
        // The card height, and Cancel's and the primary's x and width in the card's coordinates.
        var geometry = function () {
            var c = d.cancel.mapToItem(d.card, 0, 0)
            var p = d.primary.mapToItem(d.card, 0, 0)
            return { card: shell.round3(d.card.height), buttons: [c.x, d.cancel.width, p.x, d.primary.width].map(shell.round3) }
        }
        var line = function (text) { return shell.findAll(d.card, function (o) { return shell.isType(o, "Text") && o.text === text })[0] }
        var check = function (state, grows) {
            var now = geometry()
            if (!grows)
                shell.check(d.name + " slot " + state + ": the card height is the rest height", now.card, rest.card)
            shell.check(d.name + " slot " + state + ": Cancel and the primary keep their rest x and width", now.buttons, rest.buttons)
        }
        var steps = [
            { name: "slot-" + d.name + "-rest", act: d.open, record: function () { rest = geometry() } },
            { name: "slot-" + d.name + "-busy", act: function () { d.busy(true) }, record: function () {
                check("busy", false)
                // The busy word sits in the status slot in muted ink, found by its text so a slot that stays blank finds nothing, and the primary keeps its rest label.
                var busy = line(d.busyText)
                shell.check(d.name + " slot busy: the status reads " + d.busyText + " in muted ink and the primary keeps " + d.restLabel,
                            [busy ? [busy.text, shell.rgba(busy.color)] : null, d.primary.label], [[d.busyText, shell.rgba(Flea.Theme.color.muted)], d.restLabel])
            } },
            { name: "slot-" + d.name + "-error", act: function () { d.busy(false); d.error(d.oneLine) }, record: function () {
                check("error", false)
                slot = line(d.oneLine).height
            } }
        ]
        // A fixed sentence that takes both slot lines at this dialog's width still keeps the card.
        if (d.twoLines)
            steps.push({ name: "slot-" + d.name + "-two", act: function () { d.error(d.twoLines) }, record: function () {
                check("two-line error", false)
                var two = line(d.twoLines)
                shell.check(d.name + " slot two-line error: the line draws two lines whole", [two.lineCount, two.height >= two.implicitHeight], [2, true])
            } })
        steps.push({ name: "slot-" + d.name + "-long", act: function () { d.error(longError) }, record: function () {
            check("long error", true)
            var whole = line(longError)
            var growth = shell.round3(d.card.height - rest.card)
            shell.check(d.name + " slot long error: the whole error is drawn, past two lines", [whole.lineCount > 2, whole.truncated, whole.height >= whole.implicitHeight], [true, false, true])
            shell.check(d.name + " slot long error: the card grows by the status line's growth only", [growth > 0, growth], [true, shell.round3(whole.height - slot)])
            d.close()
        } })
        return steps
    }

    // The mark a strip control draws, in the strip's coordinates, with the opacity and ink it reaches the screen with.
    function mark(item) {
        var glyph = shell.findAll(item, function (o) { return shell.isType(o, "Glyph") })[0]
        var centre = glyph.mapToItem(view.stripItem, glyph.width / 2, glyph.height / 2)
        var opacity = 1
        for (var o = glyph; o && o !== view.stripItem; o = o.parent) opacity *= o.opacity
        return { size: shell.round3(glyph.markSize), x: shell.round3(centre.x), y: shell.round3(centre.y),
                 ink: shell.rgba(glyph.color), opacity: shell.round3(opacity) }
    }
    function hasHand(item) { return item.data.some(function (o) { return o.cursorShape === Qt.PointingHandCursor }) }

    function centre(item) { return { x: item.width / 2, y: item.height / 2 } }
    function park() { driver.mouseMove(stripHost, shell.parkX, shell.parkY, shell.noDelay, Qt.NoButton, Qt.NoModifier) }
    function hoverOn(item) { var c = shell.centre(item); driver.mouseMove(item, c.x, c.y, shell.noDelay, Qt.NoButton, Qt.NoModifier) }
    function pressOn(item) { var c = shell.centre(item); driver.mousePress(item, c.x, c.y, Qt.LeftButton, Qt.NoModifier, shell.noDelay) }
    function releaseOff(item) { driver.mouseRelease(item, shell.releaseOutside, shell.releaseOutside, Qt.LeftButton, Qt.NoModifier, shell.noDelay) }

    FloatingWindow {
        id: window
        implicitWidth: 900
        implicitHeight: 720
        color: "#303030"

        Item {
            id: stripHost
            width: 800
            height: 300
            Flea.TrashView {
                id: view
                opened: true
                total: shell.trashRows
                onBackRequested: shell.backRequests += 1
            }
        }

        Item {
            id: dialogHost
            y: 0
            width: parent.width
            height: parent.height
            Flea.OpenWithDialog { id: openWith }
            Flea.ConvertDialog { id: convert }
            Flea.ArchiveCompressDialog { id: compress }
            Flea.BulkRenameDialog { id: bulk }
        }
        // The flasher's running step, off screen in the card-free corner, with a transfer half done.
        Flea.FlashStepRow { id: flashRow; y: 640; width: 600; running: true; transfer: ({ share: 0.5, headText: "Writing to Stick", byteText: [], running: true }) }

        // Qt's own default fill, read off a bare rectangle so no ancestor may wear it.
        Rectangle { id: defaultFill; visible: false; width: 1; height: 1 }
        TextMetrics {
            id: capInk
            font.family: Flea.Theme.font.family
            font.pixelSize: Flea.Theme.font.caption
            font.bold: true
            text: "R"
        }
        // The holder ConvertDialog.open reads: a source, a list area to hand focus back to, and a backend that answers nothing.
        Item {
            id: holder
            property var convertSource: ({ name: "photo.png", path: "/dialog-board/photo.png", menuId: "dialog-board" })
            property Item listArea: Item {}
            property QtObject backend: QtObject {
                signal convertChecked(var message)
                signal convertStarted(int id, int requestId, var source)
                signal convertDone(int id, bool ok, string path, string err, int requestId, var source, bool collision)
                signal failed(string where, var input, string message, string mode)
                function convertImage() {}
                readonly property var archiveFormats: ["7z", "zip"]
            }
        }
        Item { id: parking; y: 700; width: 10; height: 10; focus: true }

        TestEvent { id: driver }
    }

    // The watched values, so a step is read once layout, the delegates and the press scale have stopped moving.
    function watch() {
        var row = openWith.applicationsItem.itemAtIndex(0)
        return JSON.stringify([view.backItem.scale, view.upItem.scale, openWith.cardItem.height, openWith.listHeight,
                               row ? row.y : -1, convert.cardItem.height, compress.cardItem.height, bulk.cardItem.height])
    }

    function buildScript() {
        shell.script = [
            { name: "open-openwith", act: function () {
                openWith.open("openWith", 1, "", parking)
                openWith.receive({ op: "applications", id: 1, ok: true, path: "/dialog-board/notes.txt", kind: "Plain text document",
                                   mime: "text/plain",
                                   applications: [{ id: "a.desktop", label: "Alpha", icon: "a", default: true }],
                                   installed: [{ id: "a.desktop", label: "Alpha", icon: "a" }, { id: "b.desktop", label: "Beta", icon: "b" }] })
            }, record: function () {
                shell.check("the harness draws at the reference text size", Flea.Theme.baseSize, shell.pinnedSize)
                shell.measureCheckBoxes("openwith", openWith.cardItem, 1)
                var geometry = shell.searchGeometry()
                shell.check("openwith: the search field sits 18 px under the title rule (board)", geometry.ruleToField, shell.boardRuleToField)
                shell.check("openwith: the first eyebrow's ink sits 31 px under the field (board)", geometry.fieldToInk, shell.boardFieldToEyebrowInk)
                shell.check("openwith: the card opens on the search field, cursor on the first app", [openWith.focusPart, openWith.fieldItem.focus, openWith.cursor].join(), "0,true,0")
                shell.check("openwith: the title rule starts at the content edge", Math.round(openWith.titleRuleItem.mapToItem(openWith.cardItem, 0, 0).x), Flea.Theme.spacing.rowPaddingX)
                shell.check("openwith: the header draws the esc hint", shell.findAll(openWith.cardItem, function (o) { return shell.isType(o, "EscapeHint") && o.visible }).length, 1)
                var fades = shell.findAll(openWith.cardItem, function (o) { return shell.isType(o, "Rectangle") && o.gradient })
                shell.check("openwith: every fade stays inside the card frame", fades.filter(function (o) { var x = o.mapToItem(openWith.cardItem, 0, 0).x; return x < Flea.Theme.spacing.hairline || x + o.width > openWith.cardItem.width - Flea.Theme.spacing.hairline }).length + "/" + (fades.length > 0), "0/true")
                openWith.close()
            } },
            { name: "open-convert", act: function () { convert.open("photo.png", holder) }, record: function () {
                shell.measureCheckBoxes("convert", convert.cardItem, 1)
                convert.opened = false
            } },
            // Archives040 c5: the compress card's Encrypt box, unchecked, shows the card's ground and no white wrapper.
            { name: "open-compress", act: function () {
                compress.open({ paths: ["/dialog-board/notes.txt"], menuId: 0 }, "dialog-board", holder)
                compress.encryptNames = false
            }, record: function () {
                shell.measureCheckBoxes("compress", compress.cardItem, 1)
                compress.close()
            } },
            // LAYOUT-02: each old name sits on the same rows as its new name, so the two columns share one top inset.
            { name: "open-bulkrename", act: function () {
                bulk.open(["/dialog-board/IMG_4120.HEIC", "/dialog-board/IMG_4121.MOV", "/dialog-board/notes.txt"], holder)
            }, record: function () {
                var olds = shell.namesIn(bulk.cardItem, false), news = shell.namesIn(bulk.cardItem, true)
                shell.check("bulkrename: the card draws three old names and three new names", [olds.length, news.length], [3, 3])
                shell.check("bulkrename: each old name's top is its new name's top, in card coordinates",
                            olds.map(function (top, i) { return Math.abs(top - news[i]) <= shell.rowTolerance ? 0 : shell.round3(top - news[i]) }), [0, 0, 0])
                bulk.close()
            } },
            // FIELDS-24: the fill is the track's sibling, so the track's quarter opacity never reaches it.
            { name: "flasher-run", act: function () { shell.accentFrameWas = Flea.Theme.color.accentFrame; Flea.Theme.color.accentFrame = shell.sentinel }, record: function () {
                try {
                    var bars = shell.findAll(flashRow, function (o) { return shell.isType(o, "Rectangle") && o.height === flashRow.barHeight })
                    var track = bars.filter(function (o) { return shell.rgba(o.color) === shell.rgba(Flea.Theme.color.muted) })[0]
                    var fill = bars.filter(function (o) { return o !== track })[0]
                    var effective = 1
                    for (var up = fill; up; up = up.parent) effective *= up.opacity
                    shell.check("flasher: the fill is not a descendant of the track", shell.findAll(track, function (o) { return o === fill }).length, 0)
                    shell.check("flasher: the fill's effective opacity is 1", shell.round3(effective), 1)
                    shell.check("flasher: the fill takes accentFrame and not accent", [shell.rgba(fill.color), shell.rgba(Flea.Theme.color.accent) !== shell.rgba(fill.color)], [shell.rgba(shell.sentinel), true])
                    shell.check("flasher: a half-done transfer fills half the track", shell.round3(fill.width / track.width), 0.5)
                } finally { Flea.Theme.color.accentFrame = shell.accentFrameWas }
            } },
            // Each dialog's ground and card report the pointer, so one that crosses them onto a row takes the cursor on its first move.
            { name: "pointer-openwith", act: function () {
                openWith.open("openWith", 2, "", parking)
                openWith.receive({ op: "applications", id: 2, ok: true, path: "/dialog-board/notes.txt", kind: "Plain text document",
                                   mime: "text/plain", applications: [{ id: "a.desktop", label: "Alpha", icon: "a", default: true }],
                                   installed: [{ id: "a.desktop", label: "Alpha", icon: "a" }, { id: "b.desktop", label: "Beta", icon: "b" }] })
                shell.park()
            }, record: function () {
                var target = openWith.cursor === 0 ? 1 : 0
                shell.hoverOn(openWith.applicationItem(target))
                shell.check("openwith: a pointer from the ground takes the row it reaches on its first move", openWith.cursor, target)
                openWith.close()
            } },
            { name: "pointer-convert", act: function () { convert.open("photo.png", holder); shell.park() }, record: function () {
                var target = convert.cursor === 0 ? 1 : 0
                shell.hoverOn(convert.formatItem(target))
                shell.check("convert: a pointer from the ground takes the row it reaches on its first move", convert.cursor, target)
                convert.opened = false
            } },
            { name: "strip-rest", act: function () { parking.forceActiveFocus(); shell.park() }, record: function () {
                var back = view.backItem
                var up = view.upItem
                var hit = Flea.Theme.hitMin
                var size = shell.round3(Math.min(Flea.Theme.chromeMarkSize, hit, view.stripItem.height))
                // ChromeButton centres its mark on whole pixels in the rows above the strip's rule, as the bar's own Back and Up do, so the hand-built mark's half pixel rounds.
                var middle = shell.round3(Math.round((view.stripItem.height - Flea.Theme.spacing.hairline - size) / 2) + size / 2)
                var left = Flea.Theme.spacing.rowPaddingX
                var onePlusGap = hit + Flea.Theme.spacing.gap
                shell.check("strip: Back is the one chrome control", shell.isType(back, "ChromeButton"), true)
                shell.check("strip: Up is the one chrome control", shell.isType(up, "ChromeButton"), true)
                shell.check("strip: Back's mark is where the hand-built one drew it, foreground and opaque",
                            shell.mark(back), { size: size, x: shell.round3(left + hit / 2), y: middle, ink: shell.rgba(Flea.Theme.color.foreground), opacity: 1 })
                shell.check("strip: Up's mark is where the hand-built one drew it, muted and at the disabled opacity",
                            shell.mark(up), { size: size, x: shell.round3(left + onePlusGap + hit / 2), y: middle, ink: shell.rgba(Flea.Theme.color.muted),
                                              opacity: Flea.Theme.disabledOpacity })
                shell.check("strip: Back is the pointing hand over its hit box", shell.hasHand(back), true)
                shell.check("strip: Back is live and Up is dead by design", [back.enabled, up.enabled], [true, false])
                shell.check("strip: the keyboard reaches neither mark, so no ring is ever drawn", [!!back.activeFocusOnTab, !!up.activeFocusOnTab], [false, false])
                shell.check("strip: accessible names and the button role are kept",
                            [back.Accessible.name, up.Accessible.name, back.Accessible.role === Accessible.Button, up.Accessible.role === Accessible.Button, up.Accessible.ignored],
                            ["Back", "Up unavailable in Trash", true, true, false])
                shell.check("strip: the mark rows keep their hit width, so the title and count do not move",
                            [back.width, up.width, back.height], [hit, hit, view.stripItem.height])
            } },
            { name: "up-inert", act: function () { shell.hoverOn(view.upItem); driver.mouseClick(view.upItem, view.upItem.width / 2, view.upItem.height / 2, Qt.LeftButton, Qt.NoModifier, shell.noDelay) },
              record: function () { shell.check("strip: a click on the dead Up never activates it", [shell.upActivations, shell.backRequests], [0, 0]) } },
            { name: "back-pressed", act: function () { shell.hoverOn(view.backItem); shell.pressOn(view.backItem) }, record: function () {
                shell.check("strip: Back takes the 0.96 press", view.backItem.scale, shell.pressScale)
            } },
            { name: "back-released-outside", act: function () { shell.releaseOff(view.backItem); shell.park() }, record: function () {
                shell.check("strip: a press released outside does not go Back, and the scale comes home", [shell.backRequests, view.backItem.scale], [0, 1])
            } },
            { name: "back-click", act: function () { driver.mouseClick(view.backItem, view.backItem.width / 2, view.backItem.height / 2, Qt.LeftButton, Qt.NoModifier, shell.noDelay) },
              record: function () { shell.check("strip: a click on Back goes back", shell.backRequests, 1) } }
        ].concat(shell.slotSteps({ name: "convert", card: convert.cardItem, cancel: convert.cancelItem, primary: convert.submitItem,
                                    open: function () { convert.open("photo.png", holder) }, busy: function (on) { convert.busy = on },
                                    error: function (text) { convert.errorText = text }, oneLine: "The converter wrote nothing.",
                                    busyText: "Converting…", restLabel: "Convert",
                                    twoLines: "Backend stopped; conversion outcome unknown. Check the output.",
                                    close: function () { convert.errorText = ""; convert.opened = false } }),
                  shell.slotSteps({ name: "openwith", card: openWith.cardItem, cancel: openWith.closeItem, primary: openWith.submitItem,
                                    open: function () {
                                        openWith.open("openWith", 7, "", parking)
                                        openWith.receive({ op: "applications", id: 7, ok: true, path: "/dialog-board/notes.txt", kind: "Plain text document",
                                                           mime: "text/plain", applications: [{ id: "a.desktop", label: "Alpha", icon: "a", default: true }],
                                                           installed: [{ id: "a.desktop", label: "Alpha", icon: "a" }] })
                                    }, busy: function (on) { openWith.committing = on },
                                    error: function (text) { openWith.errorText = text }, oneLine: "The application could not be opened.",
                                    busyText: "Opening…", restLabel: "Open",
                                    twoLines: "Backend stopped; the application outcome is unknown. Check the application and try opening the file again from the list.",
                                    close: function () { openWith.close() } }))
    }

    // The sandbox proof first: every path the product resolves lies under the marked root before anything is assigned.
    function pinned() {
        var home = Quickshell.env("HOME") || ""
        var paths = [["HOME", home], ["the state file ViewState reads", Flea.ViewState.store.path], ["the view's home", view.home]]
        var ok = true
        for (var i = 0; i < paths.length; i++) {
            var inside = shell.underRoot(paths[i][1])
            shell.check("sandbox: " + paths[i][0] + " lies under the harness root", inside, true)
            if (!inside) ok = false
        }
        return ok
    }

    Timer {
        interval: shell.tickMs
        repeat: true
        running: true
        onTriggered: shell.advance()
    }

    function advance() {
        if (Date.now() - shell.startedAt > shell.capMs) {
            shell.failures.push("the harness did not finish")
            shell.log("FAIL the harness did not finish at step " + shell.step)
            shell.finish()
            return
        }
        if (shell.step > shell.script.length) return
        if (shell.script.length === 0) {
            if (!shell.pinned()) { shell.finish(); return }
            // Assigned only once every path is proved under the root, because the store may write on assignment.
            Flea.ViewState.state = { display: { textSize: { mode: TextSize.nearest(shell.pinnedSize) } } }
            shell.buildScript()
            return
        }
        if (shell.step === shell.script.length) { shell.finish(); return }
        var current = shell.script[shell.step]
        if (!shell.acted) {
            current.act()
            shell.acted = true
            shell.quiet = 0
            shell.lastWatch = ""
            return
        }
        var now = shell.watch()
        shell.quiet = now === shell.lastWatch ? shell.quiet + 1 : 0
        shell.lastWatch = now
        if (shell.quiet < shell.settleTicks) return
        current.record()
        shell.acted = false
        shell.step += 1
    }
}
