pragma ComponentBehavior: Bound

import QtQuick
import "js/Tags.js" as Tags

// One row's tag swatches: 14 px squares at 3 px gaps, each carrying its digit in the fallback.
Item {
    id: root
    readonly property int swatchSize: 14
    readonly property int swatchGap: 3
    property var tags: []
    // The item this slot follows on a row, or the caption it sits under on a tile; hug follows a text's own end.
    property Item after: null
    property Item below: null
    property bool hug: false
    visible: root.tags.length > 0
    width: root.tags.length * (root.swatchSize + root.swatchGap) - root.swatchGap
    height: root.swatchSize
    anchors.left: root.after ? (root.hug ? root.after.left : root.after.right) : undefined
    anchors.leftMargin: root.after && root.hug ? root.after.contentWidth + Theme.spacing.gap : Theme.spacing.gap
    anchors.verticalCenter: root.after ? root.after.verticalCenter : undefined
    anchors.top: root.below ? root.below.bottom : undefined
    anchors.horizontalCenter: root.below ? parent.horizontalCenter : undefined

    Repeater {
        model: root.tags
        delegate: Rectangle {
            id: swatch
            required property int index
            required property string modelData
            x: swatch.index * (root.swatchSize + root.swatchGap)
            width: root.swatchSize
            height: root.swatchSize
            color: Theme.tag.fallback ? "transparent" : Theme.tag.colors[swatch.modelData] || "transparent"
            border.width: Theme.tag.fallback ? 2 : 0
            border.color: Theme.tag.colors[swatch.modelData] || "transparent"
            Text {
                visible: Theme.tag.fallback
                anchors.centerIn: parent
                text: Tags.keyFor(swatch.modelData)
                color: Theme.tag.colors[swatch.modelData] || "transparent"
                font.family: Theme.font.family
                font.pixelSize: Theme.font.caption
                font.bold: true
                textFormat: Text.PlainText
            }
        }
    }
}
