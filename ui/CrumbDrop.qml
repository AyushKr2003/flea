import QtQuick
import "." as Flea
import "js/DropDev.js" as DropDev
import "js/Search.js" as Search

// One crumb's drop target: the floor's own receiver, naming the crumb, with a frame inside the crumb's own advance so it never reaches the "/" either side.
Flea.DropInto {
    id: root

    required property var crumb
    anchors.fill: parent
    enabled: root.crumb.inputLive && root.pane !== null
    refuseLoading: root.pane ? root.pane.listInFlight === true : true
    // The listing under the drag, whose path and device the plain-drop rule reads.
    readonly property string listingPath: root.pane ? Search.baseOf(root.pane) : ""
    // Unknown while the listed reply is still out, because dirDev is then the directory just left.
    readonly property int listingDev: root.pane && root.pane.backend && !root.pane.listInFlight ? (root.pane.backend.dirDev || 0) : 0
    // A plain drop moves on the source volume and copies across it; an unread mount table copies.
    destDev: DropDev.resolveDestDev(root.dest, root.listingPath, root.listingDev,
        root.pane && root.pane.networkService ? root.pane.networkService.mountPoints : null)
    onContainsDragChanged: root.crumb.dropTarget = root.containsDrag

    Rectangle {
        anchors.fill: parent
        visible: root.containsDrag
        color: Theme.color.accent
        opacity: 0.08
        border.width: Theme.spacing.hairline
        border.color: Theme.color.accent
    }
}
