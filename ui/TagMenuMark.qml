import QtQuick
import "js/Tags.js" as Tags

// A Tags flyout row's rule-14 box and swatch, built only for those rows; the box is the root so it anchors as a sibling of the hint.
Item {
    id: root
    required property Item row
    required property Item mark
    required property Item hint
    readonly property var tagRow: root.row.entry.tagRow || ({ swatch: "", fallback: false, state: Tags.ABSENT, digit: "" })
    readonly property color ink: root.row.labelColor
    visible: root.row.entry.tagRow !== undefined
    anchors.right: root.hint.left
    anchors.rightMargin: Theme.spacing.gap
    anchors.verticalCenter: parent.verticalCenter
    width: 14
    height: 14

    Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.width: Theme.spacing.hairline
        border.color: root.ink
        opacity: root.row.available ? 1 : 0.55
    }
    Glyph {
        anchors.fill: parent
        visible: root.tagRow.state === Tags.APPLIED
        name: "check"
        color: root.ink
    }
    Rectangle {
        visible: root.tagRow.state === Tags.MIXED
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: Math.max(2, Theme.spacing.hairline * 2)
        color: root.ink
    }
    // Reparented to the mark slot, so the swatch is centred in it as the glyph would be.
    Rectangle {
        parent: root.mark
        anchors.centerIn: parent
        width: 14
        height: 14
        visible: root.visible
        color: root.tagRow.fallback ? "transparent" : Theme.tag.menuColors[root.tagRow.swatch] || "transparent"
        border.width: root.tagRow.fallback ? 2 : 0
        border.color: Theme.tag.menuColors[root.tagRow.swatch] || "transparent"
        Text {
            visible: root.tagRow.fallback
            anchors.centerIn: parent
            text: root.tagRow.digit
            color: Theme.tag.menuColors[root.tagRow.swatch] || "transparent"
            font.family: Theme.font.family
            font.pixelSize: Theme.font.caption
            font.bold: true
            textFormat: Text.PlainText
        }
    }
}
