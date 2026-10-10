import QtQuick
import "." as Flea

// One crumb's drop target: the floor's own receiver, naming the crumb, with a frame inside the crumb's own advance so it never reaches the "/" either side.
Flea.DropInto {
    id: root

    required property var crumb
    anchors.fill: parent
    enabled: root.crumb.inputLive && root.pane !== null
    refuseLoading: root.pane ? root.pane.listInFlight === true : true
    // The crumb names an ancestor of the listing, so the listing's own device is the rule's guess.
    destDev: root.pane && root.pane.backend ? (root.pane.backend.dirDev || 0) : 0
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
