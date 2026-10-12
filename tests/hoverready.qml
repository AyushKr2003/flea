import QtQuick
import "js/sourcefixture.js" as Source

// Shared grid hover: one HoverHandler on the view sets one index, every tile reads it.
// No tile builds its own handler, and the highlight hides under the band while the tip stays.
Item {
    id: root
    property int checked: 0
    property int failed: 0
    function check(label, actual, expected) {
        root.checked++
        if (actual !== expected) {
            root.failed++
            console.log("FAIL " + label + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected))
        }
    }
    // Code only: comments name the removed handlers and must not count as builds.
    function countOf(text, marker) {
        var code = text.split("\n").map(function (line) { return line.split("//")[0] }).join("\n")
        return code.split(marker).length - 1
    }

    // Three tiles sharing one index, the delegate's two bindings in the same shape.
    property int shared: -1
    property bool bandClear: true
    property var live: [true, true, true]
    function raw(i) { return root.live[i] && root.shared === i }
    function light(i) { return root.raw(i) && root.bandClear }
    function litCount() {
        var n = 0
        for (var i = 0; i < 3; i++) if (root.light(i)) n++
        return n
    }

    Component.onCompleted: {
        var tile = Source.source("ui/GridTile.qml")
        var area = Source.source("ui/GridArea.qml")
        root.check("tile builds no handler", root.countOf(tile, "HoverHandler"), 0)
        root.check("tip reads the shared hover", tile.indexOf("root.hovered && root.captionElided()") >= 0, true)
        root.check("tip reads no local handler", tile.indexOf("hover.hovered") >= 0, false)
        root.check("tile carries the band guard", tile.indexOf("property bool hoverShown") >= 0, true)
        root.check("wash honors the guard", tile.indexOf("(root.hovered && root.hoverShown) ? Style.hoverFill") >= 0, true)
        root.check("lift honors the guard", tile.indexOf("(root.hovered && root.hoverShown) || root.selected") >= 0, true)
        root.check("view holds one shared handler", root.countOf(area, "HoverHandler"), 1)
        root.check("view names the shared probe", area.indexOf("id: hoverProbe") >= 0, true)
        root.check("view holds one hover index", area.indexOf("property int hoveredIndex") >= 0, true)
        root.check("probe resolves by position", area.indexOf("root.indexAt(x + root.contentX, y + root.contentY)") >= 0, true)
        root.check("probe clears on leave", area.indexOf("if (!hovered) root.hoveredIndex = -1") >= 0, true)
        root.check("tile reads the shared index", area.indexOf("hovered: cell.live && root.hoveredIndex === cell.index") >= 0, true)
        root.check("tile guards on the band", area.indexOf("hoverShown: root.pane.selectionBand === null") >= 0, true)
        root.check("rest lights none", root.litCount(), 0)
        for (var i = 0; i < 3; i++) {
            root.shared = i
            root.check("move lights exactly one", root.litCount(), 1)
            root.check("move lights this one", root.light(i), true)
        }
        root.bandClear = false
        root.shared = 1
        root.check("band hides the highlight", root.litCount(), 0)
        root.check("band keeps the tip source", root.raw(1), true)
        root.bandClear = true
        root.live[1] = false
        root.check("pooled tile stays dark", root.light(1), false)
        root.check("peer still lights", root.litCount(), 0)
        root.live = [true, true, true]
        root.shared = 2
        root.check("reuse lights the peer", root.light(2), true)
        console.log("hoverready: " + root.checked + " checks, " + root.failed + " failed")
        Qt.quit()
    }
}
