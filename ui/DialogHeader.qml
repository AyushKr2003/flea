import QtQuick
import "." as Flea

// A dialog card's header as the 0.4.0 boards draw it (MergeFolders, RunFile, Unlock): the title with esc on the right,
// 8 px of air at the boards' 13 px reference, then a hairline rule across the card.
Item {
    id: root

    property alias text: title.text
    readonly property bool truncated: title.truncated

    implicitHeight: title.implicitHeight + Math.round(8 * Theme.font.bodySmall / 13) + Theme.spacing.hairline

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
