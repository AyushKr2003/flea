import QtQuick
import "js/Tags.js" as Tags

// One tag swatch: the fill, the 2 px fallback border, the digit text.
Rectangle {
    id: root
    property string swatch: ""
    property bool fallback: false
    property string digit: ""
    required property var palette
    width: Tags.SWATCH_SIZE
    height: Tags.SWATCH_SIZE
    color: root.fallback ? "transparent" : root.palette[root.swatch] || "transparent"
    border.width: root.fallback ? 2 : 0
    border.color: root.palette[root.swatch] || "transparent"
    Text {
        visible: root.fallback
        anchors.centerIn: parent
        text: root.digit
        color: root.palette[root.swatch] || "transparent"
        font.family: Theme.font.family
        font.pixelSize: Theme.font.caption
        font.bold: true
        textFormat: Text.PlainText
    }
}
