//@ pragma ShellId flea-theme-contrast-test

import QtQuick
import Quickshell
import "flea" as Flea
import "flea/js/Contrast.js" as Contrast
import "button-probe.js" as Probe
import "qml-probe.js" as QmlProbe
import "palettes.js" as Palettes

// tests/theme-contrast.sh's harness: each palette is applied to the real Theme, and the text, frame and lit-row roles it derives are held to their floors.
ShellRoot {
    id: shell

    // Quiet ticks, a count of frames and never time, before the window is up and the rows are built.
    readonly property int settleTicks: 4
    readonly property int tickMs: 16
    readonly property int outerTimeoutS: Number(Quickshell.env("BUTTONSYS_TIMEOUT_S")) || 60
    readonly property int capShare: 2
    readonly property int msPerSecond: 1000
    readonly property double startedAt: Date.now()
    readonly property int capMs: shell.outerTimeoutS * shell.msPerSecond / shell.capShare
    readonly property string rootDir: Quickshell.env("BUTTONSYS_ROOT") || ""
    // The palettes tests/theme-contrast.sh reads: the 22 stock themes and the Cool Dawn and Sunset fixtures.
    readonly property int paletteCount: 24
    readonly property var sampleRow: ({ n: "contrast.txt", i: "text-x-generic", p: 420, d: false, s: 13, m: 1758835200, t: false, k: 0, v: 0 })

    property int checks: 0
    property int ticks: 0
    property var failures: []

    function log(line) { QmlProbe.log("THEMECONTRAST", line) }
    function check(name, actual, expected) { QmlProbe.checkLoud(shell, name, actual, expected) }
    function finish() {
        QmlProbe.logDone(shell)
        Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }
    // One line per palette and role: the ground, the ratio and the floor, so a red line names all four.
    function atLeast(theme, role, ground, got, floor) {
        shell.checks += 1
        var line = theme + " " + role + " on " + ground + " " + (Math.round(got * 1000) / 1000) + " >= " + floor
        if (got >= floor) {
            shell.log("ok " + line)
            return
        }
        shell.failures.push(line)
        shell.log("FAIL " + line)
    }

    FloatingWindow {
        id: window
        implicitWidth: 800
        implicitHeight: 400
        color: "#303030"

        Column {
            Flea.Row { id: restRow; width: 800; row: shell.sampleRow; kindNames: []; hiddenCols: []; clipMark: "" }
            Flea.MenuRow { id: litRow; width: 400; current: true; entry: ({ label: "Open", glyph: "folder-open", action: "open", hint: "enter" }) }
            Flea.MenuRow { id: litDangerRow; width: 400; current: true; entry: ({ label: "Move to Trash", glyph: "trash", action: "trash", danger: true, hint: "d" }) }
            Flea.MenuRow { id: restingRow; width: 400; entry: ({ label: "Copy", glyph: "copy", action: "copy", hint: "y" }) }
        }
    }

    // The first Text under an item carrying a string.
    function textDrawn(item, text) {
        var stack = [item]
        while (stack.length > 0) {
            var o = stack.pop()
            if (o.text === text) return o
            for (var i = 0; i < o.children.length; i++) stack.push(o.children[i])
        }
        return null
    }
    // The row's own frame, by its object name, with the inset it keeps and whether it shows.
    function frameOf(row) {
        var f = Probe.find(row, "menuCursorFrame")
        if (f === null) return { count: 0 }
        return { count: 1, color: Probe.rgba(f.border.color), width: f.border.width, visible: f.visible,
                 margins: [f.anchors.leftMargin, f.anchors.rightMargin, f.anchors.topMargin, f.anchors.bottomMargin] }
    }

    function sweep(entry) {
        var c = Flea.Theme.color, rgba = Probe.rgba, name = entry.name
        Flea.Theme.applyColors(entry.body)
        var bg = String(c.background), surface = String(c.surface), fg = String(c.foreground)
        // The ground a lit menu row draws on: the foreground wash over the surface.
        var lit = Contrast.hexOf(Contrast.over(fg, Flea.Theme.washHover, surface))
        shell.atLeast(name, "muted text", "background", Contrast.ratio(String(c.muted), bg), Flea.Theme.textContrast)
        shell.atLeast(name, "muted text", "surface", Contrast.ratio(String(c.muted), surface), Flea.Theme.textContrast)
        shell.atLeast(name, "metadata text", "background", Contrast.ratio(String(c.metadata), bg), Flea.Theme.textContrast)
        shell.atLeast(name, "metadata text", "surface", Contrast.ratio(String(c.metadata), surface), Flea.Theme.textContrast)
        shell.atLeast(name, "muted frame", "background", Contrast.ratio(String(c.mutedFrame), bg), Flea.Theme.frameContrast)
        shell.atLeast(name, "foreground cursor frame", "surface", Contrast.ratio(fg, surface), Flea.Theme.frameContrast)
        shell.atLeast(name, "lit row hint", "wash", Contrast.ratio(String(c.mutedLit), lit), Flea.Theme.textContrast)
        shell.atLeast(name, "lit row danger label", "wash", Contrast.ratio(String(c.errorLit), lit), Flea.Theme.textContrast)
        // The lit row draws one hairline frame in the foreground, the chrome control inset inside its footprint (past a card's border rule at the sides); a resting row draws none.
        var frame = shell.frameOf(litRow), inset = Flea.Theme.chromeControlInset, side = inset + Flea.Theme.spacing.hairline
        shell.check(name + " lit row frame colour, width and margins", [frame.count, frame.color, frame.width, frame.margins, frame.visible],
                    [1, rgba(c.foreground), Flea.Theme.spacing.hairline, [side, side, inset, inset], true])
        shell.check(name + " resting row frame is hidden", shell.frameOf(restingRow).visible, false)
        var hint = shell.textDrawn(litRow, "enter"), danger = shell.textDrawn(litDangerRow, "Move to Trash")
        shell.check(name + " lit row hint draws the lifted ink", hint ? rgba(hint.color) : "none", rgba(c.mutedLit))
        shell.check(name + " lit row danger label draws the lifted ink", danger ? rgba(danger.color) : "none", rgba(c.errorLit))
        // A resting list row draws its metadata cells in the lifted ink and its file glyph in the unlifted step, so no glyph moves.
        shell.check(name + " resting row metadata ink", rgba(restRow.cellInk), rgba(c.metadata))
        shell.check(name + " resting row file glyph", rgba(restRow.markColor()), rgba(c.metadataFrame))
    }

    function run() {
        var inside = shell.rootDir.length > 0 && (Quickshell.env("HOME") || "").indexOf(shell.rootDir + "/") === 0
        shell.check("sandbox: HOME lies under the harness root", inside, true)
        if (!inside) { shell.finish(); return }
        shell.check("the sweep reads the 22 stock palettes and two fixtures", Palettes.PALETTES.length, shell.paletteCount)
        for (var i = 0; i < Palettes.PALETTES.length; i++)
            shell.sweep(Palettes.PALETTES[i])
        shell.finish()
    }

    Timer {
        interval: shell.tickMs
        repeat: true
        running: true
        onTriggered: {
            if (Date.now() - shell.startedAt > shell.capMs) {
                shell.failures.push("the harness did not finish")
                shell.log("FAIL the harness did not finish")
                shell.finish()
                running = false
                return
            }
            shell.ticks += 1
            if (shell.ticks === shell.settleTicks) { running = false; shell.run() }
        }
    }
}
