import QtQuick
import "." as Flea

// A 0.4.0 dialog card's header (MergeFolders, RunFile, Unlock): DialogTitle, the boards' air, then a hairline rule.
Item {
    id: root

    property alias text: title.text
    readonly property bool truncated: title.truncated

    // The boards draw 8 px of air under the title at their 13 px reference body.
    readonly property real boardAir: 8
    readonly property real referenceBody: 13
    implicitHeight: title.implicitHeight + Math.round(root.boardAir * Theme.font.bodySmall / root.referenceBody) + Theme.spacing.hairline

    Flea.DialogTitle {
        id: title
        width: parent.width
    }

    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: Theme.spacing.hairline
        color: Theme.color.muted
        opacity: 0.4
    }
}
