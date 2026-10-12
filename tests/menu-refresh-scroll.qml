//@ pragma ShellId flea-menu-refresh-scroll-test

import QtQuick
import Quickshell
import "flea" as Flea

// tests/menu-refresh-scroll.sh's harness: a provider refresh that rebuilds the rows of a scrolled menu keeps the open flyout's row in view.
ShellRoot {
    id: shell

    property var failures: []
    property int ticks: 0
    property int phase: 0

    function log(line) { console.log("MENUREFRESH " + line) }
    function quit() { Quickshell.execDetached(["kill", String(Quickshell.processId)]) }
    function check(name, cond, detail) {
        if (!cond) shell.failures.push(name + " got " + detail)
    }
    function findFirst(item, name) {
        var stack = [item]
        while (stack.length > 0) {
            var o = stack.pop()
            if (o !== item && String(o).indexOf(name) >= 0) return o
            var kids = (o && o.children !== undefined) ? o.children : []
            for (var i = 0; i < kids.length; i++) stack.push(kids[i])
        }
        return null
    }

    FloatingWindow {
        implicitWidth: 640
        implicitHeight: 480
        color: "#303030"

        Flea.ContextMenu {
            id: menu
            anchors.fill: parent
            rowIsFile: true
            workArea: Qt.rect(0, 0, 640, 300)
        }
    }

    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: shell.advance()
    }

    // One step per tick so the Column lays out between steps, as it does between a click and the key that follows.
    function advance() {
        shell.ticks += 1
        var main = menu.frameItem ? shell.findFirst(menu.frameItem, "CardScroll") : null
        if (shell.phase === 0 && shell.ticks >= 2) {
            Flea.ViewState.state = { menu: { hidden: [] } }
            shell.phase = 1
            shell.ticks = 0
        } else if (shell.phase === 1 && shell.ticks >= 3) {
            menu.openAt(Qt.point(20, 20))
            shell.phase = 2
            shell.ticks = 0
        } else if (shell.phase === 2 && shell.ticks >= 3) {
            shell.check("copy-opens", menu.openSubmenuFor("copyAs") && menu.openSubmenuRow >= 0, "no Copy as row")
            shell.phase = 3
            shell.ticks = 0
        } else if (shell.phase === 3 && shell.ticks >= 3) {
            // A provider answer inserts a row while the flyout is open.
            shell.check("scrolled", main.contentY > 0, String(main.contentY))
            menu.taildropInstalled = true
            menu.taildropPeers = [{ id: "p", label: "Peer" }]
            menu.providersSettled()
            shell.phase = 4
            shell.ticks = 0
        } else if (shell.phase === 4 && shell.ticks >= 3) {
            var copyRow = menu.itemFor(menu.openSubmenuRow)
            var at = copyRow.mapToItem(main, 0, 0).y
            shell.check("row-in-band", at >= 0 && at + copyRow.height <= main.height, "y=" + at + " contentY=" + main.contentY)
            // The flyout follows the row through heldOffset, so the two agree on where the row stands.
            var rowOff = copyRow.mapToItem(menu.frameItem, 0, 0).y - Flea.Theme.spacing.rowPaddingY
            shell.check("flyout-beside", menu.heldOffset === rowOff, menu.heldOffset + "/" + rowOff)
            if (shell.failures.length === 0)
                shell.log("PASS contentY=" + main.contentY + " rowY=" + at)
            else
                for (var i = 0; i < shell.failures.length; i++)
                    shell.log("FAIL " + shell.failures[i])
            shell.log("DONE failures=" + shell.failures.length)
            shell.phase = 5
            shell.quit()
        }
    }
}
