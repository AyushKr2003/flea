import QtQuick
import "." as Flea

// One crumb's drop target: the floor's own receiver, naming the crumb, with a frame inside the crumb's own advance so it never reaches the "/" either side.
Flea.DropInto {
    id: root

    required property var crumb
    anchors.fill: parent
    enabled: root.crumb.inputLive && root.pane !== null
    refuseLoading: root.pane ? root.pane.listInFlight === true : true
    // The crumb's own device, asked once per destination, 0 until the answer lands, which copies.
    destDev: 0
    onContainsDragChanged: root.crumb.dropTarget = root.containsDrag

    // The peek wire answers any path's device without touching the listing: one first-0 peek per
    // destination, asked at creation and again if the crumb is reused for another path.
    property string asked: ""
    function askDev() {
        if (root.dest === root.asked) return
        root.asked = root.dest
        root.destDev = 0
        if (root.dest.length > 0 && root.pane && root.pane.backend) root.pane.backend.peek(root.dest, 0, false, false, undefined)
    }
    onDestChanged: root.askDev()
    Component.onCompleted: root.askDev()
    // Only a first-0 reply for this destination lands; columns and repairs ask other counts.
    function landDev(path, first, readFailed, dev) {
        if (first !== 0 || path !== root.dest) return
        root.destDev = readFailed ? 0 : Number(dev) || 0
    }
    Connections {
        target: root.pane ? root.pane.backend : null
        function onPeeked(path, hidden, total, rows, readFailed, mode, hiddenLast, first, dev) { root.landDev(path, first, readFailed, dev) }
    }

    Rectangle {
        anchors.fill: parent
        visible: root.containsDrag
        color: Theme.color.accent
        opacity: 0.08
        border.width: Theme.spacing.hairline
        border.color: Theme.color.accent
    }
}
