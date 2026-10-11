//@ pragma ShellId flea-framegap-test

import QtQuick
import Quickshell
import "flea" as Flea
import "flea/js/Settings.js" as Settings
import "framegap.js" as Gap
import "button-probe.js" as Probe

// tests/framegap.sh's harness: every framed control in the real dialogs, cards, rows and panels keeps Theme.chromeControlInset from the nearest rule and from its host's edge, at three text stops, at rest and with focus on every control.
ShellRoot {
    id: root

    readonly property var stops: [12, 14, 16]
    // Frames a step waits after an act, so layout, delegates and the card fades have settled before a read.
    readonly property int settleTicks: 6
    readonly property int tickMs: 16
    readonly property int windowWidth: 1000
    readonly property int windowHeight: 900
    readonly property int sideHostWidth: 600
    // One copy in flight, as the transfer card and the Flash step read it.
    readonly property var inFlight: ({ id: 1, moving: false, n: 2, index: 1, name: "a.txt", running: true, done: 0, bytes: 1024, total: 4096, moved: 0, writing: false, drive: "" })

    property var plan: []
    property int at: 0
    property int wait: 0
    property int checks: 0
    property int failed: 0
    property var seen: ({})

    function log(line) { console.log("FRAMEGAP " + line) }
    function finish() {
        var hosts = Object.keys(root.seen).sort()
        root.log("HOSTS " + hosts.length + " " + hosts.join(","))
        if (root.failed === 0) root.log("PASS " + root.checks + " checks")
        root.log("DONE checks=" + root.checks + " failed=" + root.failed)
        root.at = root.plan.length + 1
        Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }
    function stopState(stop) { Flea.ViewState.load(JSON.stringify({ display: { textSize: { mode: stop } } })) }

    // Each host is measured on its card, its own root where it has no card.
    function hosts() {
        return [["OpenWithDialog", openWith.cardItem], ["ConvertDialog", convert.cardItem], ["ArchiveCompressDialog", compress.cardItem],
                ["ArchivePasswordDialog", password.cardItem], ["FatNamesConfirm", fat.cardItem], ["TrashConfirm", trash.cardItem],
                ["CollideConfirm", collide.cardItem], ["BulkRenameDialog", bulk.cardItem], ["MenuActionDialog", menuAction.cardItem],
                ["UnlockDialog", unlock.cardItem], ["NetworkDialog", network.cardItem], ["RunCard", runCard.cardItem],
                ["KeymapSheet", sheet.cardItem], ["TransferCard", transfer], ["FlashStepRow", flashRow], ["MediaStrip", framedStrip],
                ["MediaStrip unframed", bareStrip]]
    }

    function measure(name, host, state, stop) {
        root.seen[name] = true
        var rows = Gap.rows(name, host, Flea.Theme.spacing.hairline, Flea.Theme.chromeControlInset, state, stop)
        for (var i = 0; i < rows.length; i++) {
            var r = rows[i]
            root.checks += 1
            var line = [r.host, r.owner, r.name, r.frame, r.box, r.state, r.stop, r.side, r.rule, r.edge, r.inset].join("\t")
            root.log("ROW " + line)
            if (!r.under) continue
            root.failed += 1
            root.log("FAIL " + line)
        }
    }

    // Focus on every control at once: a set member current, every check box filled and focused, every mark under the keyboard.
    function focusAll() {
        var roots = root.hosts().map(function (h) { return h[1] }).concat([settings.cardItem])
        roots.forEach(function (top) {
            var stack = [top]
            while (stack.length > 0) {
                var o = stack.pop()
                var kids = o.children !== undefined ? o.children : []
                for (var i = 0; i < kids.length; i++) stack.push(kids[i])
                var type = Gap.typeOf(o)
                if (type === "DialogButton") { o.focused = true; if (o.setMember) o.current = true }
                else if (type === "CheckBox") { o.value = "on"; o.focused = true }
                else if (type === "ChromeButton") o.keyboardFocused = true
            }
        })
    }

    function buildPlan() {
        var plan = [function () {
            Flea.Theme.applyColors(Probe.COLOURED_THEME)
            openWith.open("openWith", 1, "", parking)
            openWith.receive({ op: "applications", id: 1, ok: true, path: "/framegap/notes.txt", kind: "Plain text document", mime: "text/plain",
                               applications: [{ id: "a.desktop", label: "Alpha", icon: "a", default: true }],
                               installed: [{ id: "a.desktop", label: "Alpha", icon: "a" }, { id: "b.desktop", label: "Beta", icon: "b" }] })
            convert.open("photo.png", holder)
            compress.open({ paths: ["/framegap/notes.txt"], menuId: 0 }, "framegap", holder)
            password.open({ path: "/framegap/locked.7z", dest: "/framegap" }, holder, "")
            fat.open("Some names change on this drive", [{ old: "a:b.txt", new: "a_b.txt", d: false, i: "" }], "The drive cannot store these characters.")
            trash.open({ token: 1, all: true, count: 3, bytes: 4096 })
            collide.open("1 item already exists here", [{ n: "a.txt", d: false, i: "" }], "", true)
            bulk.open(["/framegap/a.txt", "/framegap/b.txt"], parking)
            menuAction.open("newFile", 1, "/framegap", parking)
            unlock.openFor("/dev/sdb1", "Backup", 500000000000, "crypto_LUKS", "2")
            network.open()
            runCard.open({ path: "/framegap/tool.sh", raw: '{"ask":"run","kind":"script","size":9420,"handlerId":"","handlerName":"","dev":"8","ino":"9","mtimeS":"11","mtimeNs":"12","target":"/framegap/tool.sh"}' }, null)
            sheet.open(sheetHolder)
            // A typed query shows the sheet's own field frame.
            sheet.query = "copy"
            settings.open(null)
        }]
        var states = ["rest", "focus"]
        states.forEach(function (state) {
            if (state === "focus") plan.push(root.focusAll)
            root.stops.forEach(function (stop) {
                plan.push(function () { root.stopState(stop) })
                plan.push(function () { root.hosts().forEach(function (h) { root.measure(h[0], h[1], state, stop) }) })
                Settings.SECTIONS.forEach(function (section) {
                    plan.push(function () { settings.showSection(section.id) })
                    plan.push(function () {
                        if (state === "focus") root.focusAll()
                        root.measure("SettingsPanel " + section.id, settings.cardItem, state, stop)
                    })
                })
            })
        })
        root.plan = plan
    }

    Timer {
        interval: root.tickMs
        repeat: true
        running: root.at <= root.plan.length
        onTriggered: {
            if (root.wait > 0) { root.wait -= 1; return }
            if (root.plan.length === 0) { root.buildPlan(); return }
            if (root.at === root.plan.length) { root.finish(); return }
            root.plan[root.at]()
            root.at += 1
            root.wait = root.settleTicks
        }
    }

    FloatingWindow {
        implicitWidth: root.windowWidth
        implicitHeight: root.windowHeight
        color: Flea.Theme.color.background

        Item {
            anchors.fill: parent
            Flea.OpenWithDialog { id: openWith }
            Flea.ConvertDialog { id: convert }
            Flea.ArchiveCompressDialog { id: compress }
            Flea.ArchivePasswordDialog { id: password }
            Flea.FatNamesConfirm { id: fat }
            Flea.TrashConfirm { id: trash }
            Flea.CollideConfirm { id: collide }
            Flea.BulkRenameDialog { id: bulk }
            Flea.MenuActionDialog { id: menuAction }
            Flea.UnlockDialog { id: unlock }
            Flea.NetworkDialog { id: network }
            Flea.RunCard { id: runCard }
            Flea.KeymapSheet { id: sheet; anchors.fill: parent }
            Flea.SettingsPanel { id: settings; anchors.fill: parent }
        }

        // The cards and strips a window hosts outside a dialog, each at the width its host gives it.
        Column {
            x: root.windowWidth - root.sideHostWidth
            width: root.sideHostWidth
            Flea.TransferCard { id: transfer; transfer: root.inFlight }
            Flea.FlashStepRow { id: flashRow; width: parent.width; transfer: root.inFlight; words: ({ erase: "Erase Backup", action: "Flash" }); live: true; cursor: true }
            Flea.MediaStrip { id: framedStrip; width: parent.width; duration: 60000 }
            Flea.MediaStrip { id: bareStrip; width: parent.width; duration: 60000; framed: false }
        }

        // The holders the dialogs read: a source, a list area, a backend that answers nothing, and the sheet's pane.
        Item {
            id: holder
            property var convertSource: ({ name: "photo.png", path: "/framegap/photo.png", menuId: "framegap" })
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
        Item {
            id: sheetHolder
            property bool dualMode: false
            property string home: "/framegap"
            property var sidebar: null
            property bool listInFlight: false
            property var cursorRow: ({ n: "a.txt", d: false })
            property var context: ({})
            function sheetMenuAction(action) {}
            function checkShebang() {}
            function message(text, sticky) {}
            function contextMenu() { return { listingContext: function () { return sheetHolder.context } } }
        }
        Item { id: parking; width: 10; height: 10; focus: true }
    }
}
