//@ pragma ShellId flea-gridcaption-test

import QtQuick
import QtTest
import Quickshell
import "flea" as Flea
import "flea/js/GridGeometry.js" as GridGeometry
import "flea/js/Density.js" as Density

// GridTile caption geometry at text sizes 12 and 14 (the old slot must fail at 14), the caption alone at rest, the drop label added under a drag, the hover tip.
ShellRoot {
    id: root

    // The native witness name, so GridNames wraps and elides exactly the failing caption.
    readonly property string longName: "long-grid-caption-with-enough-words-to-wrap-and-truncate-after-two-complete-lines.txt"
    readonly property var fileRow: ({ n: root.longName, i: "text-x-generic", p: 0, d: false, s: 1, m: 0, t: false, v: 0 })
    // Wraps to two lines at 14 and still shows whole, so hovering it builds no tip.
    readonly property var wholeRow: ({ n: "a-wrapped-whole-name.txt", i: "text-x-generic", p: 0, d: false, s: 1, m: 0, t: false, v: 0 })

    // The real cell height GridArea gives a tile, so bottom<=height means the window contains it.
    function cellH() {
        return GridGeometry.cellHeightFor(Flea.ViewState.thumbnailPixels, Flea.Theme.spacing.gap,
            Math.ceil(Flea.Theme.grid.captionHeight),
            Density.gridPadY(Flea.Theme.spacing.rowPaddingX, Flea.ViewState.density))
    }

    Column {
        Flea.GridTile { id: normalTile; width: 147; height: root.cellH(); row: root.fileRow }
        Flea.GridTile { id: dropTile; width: 147; height: root.cellH(); row: root.fileRow; dropTarget: true }
    }

    // A pointer reaches a tile only in a window, so the truncated-name tip is driven on this one.
    FloatingWindow {
        implicitWidth: 400
        implicitHeight: 400
        Flea.GridTile { id: hoverTile; width: 147; height: root.cellH(); row: root.fileRow }
        Flea.GridTile { id: wholeTile; y: 200; width: 147; height: root.cellH(); row: root.wholeRow }
        TestEvent { id: pointer }
    }

    property int phase: 0
    property var failures: []

    // Each phase lands a turn after the last write, so the relayout it measures has settled.
    Timer {
        id: stepper
        interval: 700
        running: true
        repeat: true
        onTriggered: root.step()
    }

    function check(cond, label) {
        if (!cond)
            root.failures.push(label)
    }

    // Text items under a tile, each laid out when built whether drawn or not.
    function texts(item) {
        var found = [], stack = [item]
        while (stack.length > 0) {
            var o = stack.pop()
            if (o !== item && String(o).indexOf("QQuickText") === 0) found.push(o)
            for (var i = 0; i < o.children.length; i++) stack.push(o.children[i])
        }
        return found
    }

    function measure(base, withNegative) {
        var lineH = Flea.Theme.grid.captionLineHeight
        var cap = normalTile.captionItem
        var ntext = String(cap.text)
        console.log("GRIDCAPTION MEASURE base=" + base + " tile=normal lines=" + cap.lineCount + " textHeight=" + cap.contentHeight + " slotHeight=" + cap.height + " bottom=" + (cap.y + cap.height) + " tileHeight=" + normalTile.height)
        root.check(cap.lineCount === 2, "base " + base + " normal lines " + cap.lineCount)
        root.check(ntext.slice(-4) === ".txt", "base " + base + " normal tail " + ntext.slice(-12))
        root.check(ntext.indexOf("…") >= 0, "base " + base + " normal no ellipsis")
        root.check(cap.contentHeight <= cap.height, "base " + base + " normal textHeight " + cap.contentHeight + " over slot " + cap.height)
        root.check(cap.y + cap.height <= normalTile.height, "base " + base + " normal bottom past tile")
        if (withNegative)
            root.check(cap.contentHeight > 2 * lineH, "base " + base + " old slot already contained it")
        var dcap = dropTile.captionItem
        console.log("GRIDCAPTION MEASURE base=" + base + " tile=drop lines=" + dcap.lineCount + " textHeight=" + dcap.contentHeight + " slotHeight=" + dcap.height + " bottom=" + (dcap.y + dcap.height) + " tileHeight=" + dropTile.height)
        root.check(dcap.lineCount === 1, "base " + base + " drop lines " + dcap.lineCount)
        root.check(dcap.contentHeight <= dcap.height, "base " + base + " drop textHeight " + dcap.contentHeight + " over slot " + dcap.height)
        root.check(dcap.y + dcap.height <= dropTile.height, "base " + base + " drop bottom past tile")
        var rest = root.texts(normalTile), drop = root.texts(dropTile)
        root.check(rest.length === 1 && rest[0] === cap, "base " + base + " a resting tile lays out " + rest.length + " Texts, want its caption alone")
        root.check(drop.length === 2 && drop.indexOf(dcap) >= 0, "base " + base + " a drop-target tile lays out " + drop.length + " Texts, want its caption and drop label")
        root.check(drop.some(function (t) { return t.text === "move here" }), "base " + base + " a drop-target tile labels no move")
    }

    // Texts under a tile carrying the whole name; only the hover tip does, the caption is wrapped and elided.
    function tips(item) {
        return root.texts(item).filter(function (t) { return t.text === root.longName })
    }

    // The offscreen pointer can start over the first tile, so it is moved off both tiles before each rest check.
    function park() {
        pointer.mouseMove(hoverTile, hoverTile.width + 100, hoverTile.height / 2, 0, Qt.NoButton, Qt.NoModifier)
    }

    function hoverCaption() {
        var cap = hoverTile.captionItem
        root.check(cap.text.replace(/\n/g, "") !== root.longName, "the hover tile caption shows the whole name, so no tip can build")
        root.check(root.texts(hoverTile).length === 1, "a resting hover tile lays out " + root.texts(hoverTile).length + " Texts, want its caption alone")
        pointer.mouseMove(hoverTile, cap.x + cap.width / 2, cap.y + cap.height / 2, 0, Qt.NoButton, Qt.NoModifier)
    }

    // The tile's own HoverHandler, so a check can tell "hovered, no tip" from "never hovered".
    function hoverReached(tile) {
        for (var i = 0; i < tile.data.length; i++)
            if (String(tile.data[i]).indexOf("HoverHandler") >= 0)
                return tile.data[i].hovered
        return false
    }

    function hoverWhole() {
        var cap = wholeTile.captionItem
        root.check(cap.lineCount === 2 && cap.text.replace(/\n/g, "") === root.wholeRow.n, "the whole tile caption is not the whole name on two lines: " + cap.lineCount + " " + JSON.stringify(cap.text))
        pointer.mouseMove(wholeTile, cap.x + cap.width / 2, cap.y + cap.height / 2, 0, Qt.NoButton, Qt.NoModifier)
    }

    // The tip builds on hover, shows the whole name unelided, and its frame fits its text inside the cap.
    function measureTip() {
        var found = root.tips(hoverTile)
        root.check(found.length === 1, "hovering a truncated caption built " + found.length + " tips")
        if (found.length !== 1)
            return
        var tip = found[0], frame = tip.parent, gap = Flea.Theme.spacing.gap
        var cap = Flea.Theme.grid.minCellWidth * 2
        console.log("GRIDCAPTION TIP width=" + frame.width + " height=" + frame.height + " cap=" + cap + " lines=" + tip.lineCount + " textWidth=" + tip.implicitWidth + " textHeight=" + tip.implicitHeight)
        root.check(!tip.truncated && tip.lineCount >= 1, "the tip elides the name")
        root.check(frame.visible && frame.width > 0 && frame.width <= cap, "the tip width " + frame.width + " is outside (0, " + cap + "]")
        root.check(frame.width === Math.min(tip.implicitWidth + 2 * gap, cap), "the tip width " + frame.width + " does not follow its text " + tip.implicitWidth)
        root.check(frame.height > 0 && frame.height === tip.implicitHeight + gap, "the tip height " + frame.height + " does not follow its text " + tip.implicitHeight)
        root.check(tip.contentHeight <= frame.height && tip.contentWidth <= tip.width, "the tip text overflows its frame")
    }

    function step() {
        if (root.phase === 0)
            Flea.ViewState.setTextSize({ mode: 12 })
        else if (root.phase === 1)
            root.measure(12, false)
        else if (root.phase === 2)
            Flea.ViewState.setTextSize({ mode: 14 })
        else if (root.phase === 3)
            root.measure(14, true)
        else if (root.phase === 4 || root.phase === 7)
            root.park()
        else if (root.phase === 5)
            root.hoverCaption()
        else if (root.phase === 6)
            root.measureTip()
        else if (root.phase === 8)
            root.check(root.tips(hoverTile).length === 0 && root.texts(hoverTile).length === 1, "the tip outlived the hover: " + root.texts(hoverTile).length + " Texts")
        else if (root.phase === 9)
            root.hoverWhole()
        else if (root.phase === 10)
            root.check(root.hoverReached(wholeTile) && root.texts(wholeTile).length === 1, "hovering a whole caption built a tip or never reached it: " + root.hoverReached(wholeTile) + " " + root.texts(wholeTile).length + " Texts")
        else
            root.report()
        root.phase++
    }

    function report() {
        stepper.running = false
        if (root.failures.length === 0)
            console.log("GRIDCAPTION PASS base=12,14 normal=2lines drop=1line texts=1,2 tip=built,gone")
        for (var f = 0; f < root.failures.length; f++)
            console.log("GRIDCAPTION FAIL " + root.failures[f])
        Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }
}
