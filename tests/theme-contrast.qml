//@ pragma ShellId flea-theme-contrast-test

import QtQuick
import Quickshell
import "flea" as Flea
import "flea/js/Contrast.js" as Contrast
import "flea/js/Tags.js" as Tags
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
    // Alpha tolerance for a drawn wash against its role, and the step under it that must already fall short of the floor.
    readonly property real alphaEpsilon: 0.0001
    readonly property real alphaBelow: 0.02
    // glass.lua's blur brightness: Hyprland dims the blurred backdrop to this share before the translucent ground composes over it.
    readonly property real blurBrightness: 0.75
    readonly property var backdrops: [{ name: "white", level: 1 }, { name: "black", level: 0 }]
    readonly property int glassSteps: 255
    // The lowest 8-bit glass alpha every palette passes at and above, taken over the whole sweep.
    property int glassFloor: 0
    readonly property var sampleRow: ({ n: "contrast.txt", i: "text-x-generic", p: 420, d: false, s: 13, m: 1758835200, t: false, k: 0, v: 0 })

    property int checks: 0
    // Palettes whose lit Red swatch differs from its plain one: only there can the lit swatch check tell the two apart.
    property int litSwatchDiffers: 0
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
            Flea.DialogButton { id: secondaryButton; label: "Cancel" }
            Flea.MenuRow { id: litNamedRow; width: 400; current: true; entry: ({ label: "Convert", glyph: "image", action: "convert", labelColor: Flea.Theme.color.foreground }) }
            Flea.MenuRow { id: litTagRow; width: 400; current: true; entry: ({ label: "Red", glyph: "tag", action: "tag", tagRow: ({ swatch: "Red", fallback: false, state: Tags.APPLIED, digit: "1" }) }) }
            Flea.MenuRow { id: pickedRow; width: 400; picked: true; entry: ({ label: "Name", glyph: "file", action: "name" }) }
            Flea.MenuRow { id: restingRow; width: 400; entry: ({ label: "Copy", glyph: "copy", action: "copy", hint: "y" }) }
        }
    }

    // The fill of the first tag swatch under a row.
    function swatchOf(item) {
        var stack = [item]
        while (stack.length > 0) {
            var node = stack.pop()
            if (node.swatch !== undefined && node.tagColors !== undefined) return String(node.color)
            for (var i = 0; i < node.children.length; i++) stack.push(node.children[i])
        }
        return ""
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
    // The first item named for a glyph that carries a colour: the ink the row draws that mark in.
    function glyphDrawn(item, glyph) {
        var stack = [item]
        while (stack.length > 0) {
            var o = stack.pop()
            if (o.name === glyph && o.color !== undefined) return o
            for (var i = 0; i < o.children.length; i++) stack.push(o.children[i])
        }
        return null
    }
    // The ground a wash draws over a surface: the colour's own alpha times the item's opacity (Contrast.parse drops the alpha of #AARRGGBB).
    function groundOf(wash, surface) {
        return Contrast.hexOf(Contrast.over(String(wash.color), wash.color.a * wash.opacity, surface))
    }

    // The ground a glass plane draws at 8-bit alpha a over the dimmed backdrop, as a hex.
    function glassGround(plane, a, backdrop) {
        var g = Math.round(shell.glassSteps * backdrop.level * shell.blurBrightness) / shell.glassSteps
        return Contrast.hexOf(Contrast.over(String(plane), a / shell.glassSteps, Contrast.hexOf([g, g, g])))
    }
    // The least ratio muted and metadata text reach on either plane over either backdrop, and where it is lowest.
    function glassWorst(c, a) {
        var worst = { ratio: Infinity, at: "" }
        var roles = [["muted text", c.muted], ["metadata text", c.metadata]], planes = [["background", c.background], ["surface", c.surface]]
        for (var r = 0; r < roles.length; r++)
            for (var p = 0; p < planes.length; p++)
                for (var b = 0; b < shell.backdrops.length; b++) {
                    var got = Contrast.ratio(String(roles[r][1]), shell.glassGround(planes[p][1], a, shell.backdrops[b]))
                    if (got < worst.ratio) worst = { ratio: got, at: roles[r][0] + " on the " + planes[p][0] + " over " + shell.backdrops[b].name }
                }
        return worst
    }
    // Muted text sits near 4.5 on the opaque ground, so no translucent ground holds it: the floor over white is 255/255 for 16 palettes (RESULT, 2026-10-12). A palette's recorded floor only moves down, when a look lifts the ink on glass.
    readonly property var glassFloors: ({ "catppuccin": 253, "catppuccin-latte": 255, "ethereal": 240, "everforest": 255, "flexoki-light": 255,
        "gruvbox": 255, "hackerman": 255, "kanagawa": 255, "last-horizon": 253, "lumon": 255, "lupine": 255, "matte-black": 253, "miasma": 255,
        "nord": 255, "osaka-jade": 255, "retro-82": 255, "ristretto": 255, "rose-pine": 255, "solitude": 255, "tokyo-night": 255,
        "vantablack": 249, "white": 254, "cool-dawn": 232, "sunset": 253 })
    function glassSweep(name, c) {
        // Walk down from opaque while every step still passes; the step before the first miss is this palette's floor.
        var floor = shell.glassSteps
        while (floor > 0 && shell.glassWorst(c, floor - 1).ratio >= Flea.Theme.textContrast) floor--
        var worst = shell.glassWorst(c, floor)
        shell.log("floor " + name + " " + floor + "/255 (" + (Math.round(floor / shell.glassSteps * 1000) / 1000) + "), lowest ratio there " + (Math.round(worst.ratio * 100) / 100) + " " + worst.at)
        shell.glassFloor = Math.max(shell.glassFloor, floor)
        shell.atLeast(name, "glass ink at opaque", "both planes over both backdrops", shell.glassWorst(c, shell.glassSteps).ratio, Flea.Theme.textContrast)
        var recorded = shell.glassFloors[name]
        shell.check(name + " glass floor " + floor + " is at or under the recorded " + recorded, recorded !== undefined && floor <= recorded, true)
    }

    function sweep(entry) {
        var c = Flea.Theme.color, rgba = Probe.rgba, name = entry.name
        Flea.Theme.applyColors(entry.body)
        var bg = String(c.background), surface = String(c.surface), fg = String(c.foreground)
        // The ground a lit menu row draws on: the wash the row itself draws, over the card's surface.
        var wash = Probe.find(litRow, "menuWash")
        shell.check(name + " lit row draws its wash", wash !== null && wash.visible, true)
        var lit = wash === null ? surface : shell.groundOf(wash, surface)
        shell.atLeast(name, "muted text", "background", Contrast.ratio(String(c.muted), bg), Flea.Theme.textContrast)
        shell.atLeast(name, "muted text", "surface", Contrast.ratio(String(c.muted), surface), Flea.Theme.textContrast)
        shell.atLeast(name, "metadata text", "background", Contrast.ratio(String(c.metadata), bg), Flea.Theme.textContrast)
        shell.atLeast(name, "metadata text", "surface", Contrast.ratio(String(c.metadata), surface), Flea.Theme.textContrast)
        shell.atLeast(name, "muted frame", "background", Contrast.ratio(String(c.mutedFrame), bg), Flea.Theme.frameContrast)
        // The cursor is one fill, pointer and keyboard alike: at least a graphical object off the menu surface, and the label, glyph and hints read on it.
        shell.atLeast(name, "cursor wash", "surface", Contrast.ratio(lit, surface), Flea.Theme.frameContrast)
        shell.check(name + " cursor wash is never under the hover wash", Flea.Theme.washCursor >= Flea.Theme.washHover, true)
        shell.atLeast(name, "lit row label", "wash", Contrast.ratio(String(c.labelLit), lit), Flea.Theme.textContrast)
        shell.atLeast(name, "lit row glyph", "wash", Contrast.ratio(String(c.markLit), lit), Flea.Theme.frameContrast)
        shell.atLeast(name, "lit row hint", "wash", Contrast.ratio(String(c.mutedLit), lit), Flea.Theme.textContrast)
        shell.atLeast(name, "lit row danger label", "wash", Contrast.ratio(String(c.errorLit), lit), Flea.Theme.textContrast)
        // The error ink is never the quieter of the two beside a caption, on each ground it draws on.
        shell.atLeast(name, "error against the caption", "background", Contrast.ratio(String(c.error), bg), Contrast.ratio(String(c.muted), bg))
        shell.atLeast(name, "status error against the caption", "surface", Contrast.ratio(String(c.errorOnSurface), surface), Contrast.ratio(String(c.muted), surface))
        shell.atLeast(name, "lit danger label against the hint", "wash", Contrast.ratio(String(c.errorLit), lit), Contrast.ratio(String(c.mutedLit), lit))
        // The lit row draws no frame object at all; the fill is its whole cue.
        shell.check(name + " lit row draws no cursor frame", Probe.find(litRow, "menuCursorFrame") === null, true)
        // A Tags flyout row on the cursor wash: its box edge and every swatch stand 3:1 off the wash, and the row draws the lit swatch colours.
        var tagBox = litTagRow.tagItem !== null && litTagRow.tagItem.children.length > 0 ? litTagRow.tagItem.children[0] : null
        shell.atLeast(name, "lit tag row box edge", "wash", tagBox ? Contrast.ratio(String(tagBox.border.color), lit) : 0, Flea.Theme.frameContrast)
        var swatches = Object.keys(Flea.Theme.tag.menuLitColors)
        for (var k = 0; k < swatches.length; k++)
            shell.atLeast(name, "tag swatch " + swatches[k], "wash", Flea.Theme.tag.menuLitColors[swatches[k]] ? Contrast.ratio(String(Flea.Theme.tag.menuLitColors[swatches[k]]), lit) : 99, Flea.Theme.frameContrast)
        if (Flea.Theme.tag.menuLitColors.Red && String(Flea.Theme.tag.menuLitColors.Red) !== String(Flea.Theme.tag.menuColors.Red)) shell.litSwatchDiffers += 1
        shell.check(name + " a lit tag row draws the lit swatch colours", litTagRow.tagItem !== null && (!Flea.Theme.tag.menuLitColors.Red || shell.swatchOf(litTagRow) === String(Flea.Theme.tag.menuLitColors.Red)), true)
        // Not gated: the picked row's fill beside the cursor wash, both over the surface, for the ruling on a pick list.
        var pickedWash = Probe.find(pickedRow, "menuWash")
        if (pickedWash !== null) shell.log("info " + name + " picked fill over cursor wash " + (Math.round(Contrast.ratio(shell.groundOf(pickedWash, surface), lit) * 1000) / 1000) + " (picked fill on surface " + (Math.round(Contrast.ratio(shell.groundOf(pickedWash, surface), surface) * 1000) / 1000) + ", cursor wash on surface " + (Math.round(Contrast.ratio(lit, surface) * 1000) / 1000) + ")")
        var hint = shell.textDrawn(litRow, "enter"), label = shell.textDrawn(litRow, "Open"), danger = shell.textDrawn(litDangerRow, "Move to Trash")
        // The wash and the glyph as the lit row draws them, so a row left on the hover alpha or the unlifted mark is red even where the roles pass.
        var drawnAlpha = wash === null ? 0 : wash.color.a * wash.opacity
        shell.check(name + " lit row wash draws the cursor alpha", Math.abs(drawnAlpha - Flea.Theme.washCursor) < shell.alphaEpsilon, true)
        shell.check(name + " cursor alpha is the least that stands off the surface", drawnAlpha - Flea.Theme.washHover < shell.alphaEpsilon || Contrast.ratio(Contrast.hexOf(Contrast.over(fg, drawnAlpha - shell.alphaBelow, surface)), surface) < Flea.Theme.frameContrast, true)
        var glyph = shell.glyphDrawn(litRow, "folder-open")
        shell.check(name + " lit row glyph draws the lifted ink", glyph ? rgba(glyph.color) : "none", rgba(c.markLit))
        shell.check(name + " lit row label draws the lifted ink", label ? rgba(label.color) : "none", rgba(c.labelLit))
        var named = shell.textDrawn(litNamedRow, "Convert")
        shell.check(name + " lit row naming its own label ink draws the lifted ink", named ? rgba(named.color) : "none", rgba(c.labelLit))
        shell.check(name + " lit row hint draws the lifted ink", hint ? rgba(hint.color) : "none", rgba(c.mutedLit))
        shell.check(name + " lit row danger label draws the lifted ink", danger ? rgba(danger.color) : "none", rgba(c.errorLit))
        // A secondary dialog button's rest frame is the frame role; the sunset fixture sets a muted that the frame and text lifts take apart, so a frame left on muted is red there.
        shell.check(name + " secondary dialog button frame draws mutedFrame", Probe.read(secondaryButton).frameColor, rgba(c.mutedFrame))
        if (name === "sunset") shell.check("sunset: the frame role and the text role differ", rgba(c.mutedFrame) !== rgba(c.muted), true)
        // A resting list row draws its metadata cells in the lifted ink and its file glyph in the unlifted step, so no glyph moves.
        shell.check(name + " resting row metadata ink", rgba(restRow.cellInk), rgba(c.metadata))
        shell.check(name + " resting row file glyph", rgba(restRow.markColor()), rgba(c.metadataFrame))
        shell.glassSweep(name, c)
    }

    function run() {
        var inside = shell.rootDir.length > 0 && (Quickshell.env("HOME") || "").indexOf(shell.rootDir + "/") === 0
        shell.check("sandbox: HOME lies under the harness root", inside, true)
        if (!inside) { shell.finish(); return }
        shell.check("the sweep reads the 22 stock palettes and two fixtures", Palettes.PALETTES.length, shell.paletteCount)
        shell.check("a wash ground keeps the colour's own alpha", shell.groundOf({ color: Qt.rgba(1, 1, 1, 0.5), opacity: 0.5 }, "#000000"), "#404040")
        for (var i = 0; i < Palettes.PALETTES.length; i++)
            shell.sweep(Palettes.PALETTES[i])
        shell.check("some palette lifts its lit Red swatch, so the lit swatch check can go red", shell.litSwatchDiffers > 0, true)
        var want = Math.round(Flea.Glass.glassAlpha * shell.glassSteps)
        shell.log("floor all palettes " + shell.glassFloor + "/255 (" + (Math.round(shell.glassFloor / shell.glassSteps * 1000) / 1000) + "), glass alpha " + want + "/255")
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
