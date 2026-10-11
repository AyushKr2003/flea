import QtQuick
import qs.Commons

// The bulk card's old-names column: one still row per selected name.
Column {
    required property var oldNames
    // The dialog's own half-width gap and stack gap, bound by the card so both halves stay equal.
    property int columnGap: 14
    property int headGap: 4
    width: (parent.width - columnGap) / 2
    spacing: headGap
    Text {
        text: "OLD NAMES"
        color: Theme.color.muted
        font.family: Theme.font.family
        font.pixelSize: Theme.font.caption
        textFormat: Text.PlainText
    }
    Column {
        width: parent.width
        spacing: 0
        Repeater {
            model: oldNames
            delegate: Text {
                required property var modelData
                required property int index
                width: parent.width
                height: Theme.fileRowHeight
                verticalAlignment: Text.AlignVCenter
                text: modelData
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: Theme.color.muted
                font.family: Theme.font.family
                font.pixelSize: Theme.font.body
            }
        }
    }
}
