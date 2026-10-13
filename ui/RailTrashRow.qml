import QtQuick
import "." as Flea
import "js/Drag.js" as DragOps
import "js/TrashDrop.js" as TrashDrop

// The rail's Trash row: the SidebarRow every place draws, plus a drop target that trashes the rows a
// drag from this window carries, see ui/js/TrashDrop.js. It lives here rather than inline in
// ui/Sidebar.qml, whose rows are indexed by group and whose file sits at its recorded ceiling.
SidebarRow {
    id: root

    required property var rail
    readonly property int railIndex: root.index + root.rail.homeLead.length + root.rail.recentEntries.length + root.rail.homeRest.length
    readonly property var pane: root.rail.navigationPane
    // Exposed so ui/PaneRail.qml keeps an overlay rail up while a drag rests on this row.
    readonly property bool dragOver: target.containsDrag

    // The held location and keyboard frame keep the rail's bindings; a drag resting here draws the frame too.
    lit: root.railIndex === root.rail.litIndex
    cursor: target.containsDrag || (root.rail.cursorDrawn && root.railIndex === root.rail.cursorIndex)
    focused: root.rail.focused
    onActivated: root.rail.activate(root.railIndex)
    onMenuRequested: function (idx, pos) { root.rail.openRailMenu(root.railIndex, pos) }

    Flea.FileDrag {
        id: feedback
        pane: root.pane
    }

    DropArea {
        id: target
        anchors.fill: parent
        keys: [DragOps.ROWS_MIME]
        onEntered: function (drag) {
            var marker = drag.getDataAsString(DragOps.ROWS_MIME)
            if (!root.pane || !TrashDrop.accepts(marker, drag.urls, root.pane.path)) {
                drag.accepted = false
                return
            }
            feedback.feedback = DragOps.feedbackFor(marker, drag.urls, "")
            feedback.say(TrashDrop.line(marker, drag.urls, root.pane.path))
        }
        onExited: feedback.leaveTarget()
        onDropped: function (drop) {
            if (TrashDrop.drop(root.pane, drop.getDataAsString(DragOps.ROWS_MIME), drop.urls))
                drop.accept(Qt.CopyAction)
            feedback.leaveTarget()
        }
    }
}
