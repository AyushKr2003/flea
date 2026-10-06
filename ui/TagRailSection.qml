pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import "js/Tags.js" as Tags

// The rail's TAGS section: the heading and one row per tag in use. The rail builds it once, when the setting is on and a tag is in use.
Column {
    id: root
    required property var sidebar
    width: parent.width
    visible: sidebar.placesState.showTags === true
    readonly property var entries: Tags.railEntries(root.sidebar.navigationPane.tagState.inUse)
    // Where this section's first row stands among the rail's entries.
    readonly property int base: root.sidebar.placesEntries.length - root.entries.length
    function itemAt(i) { return tagRepeater.itemAt(i) }

    // The Loader sizes its item to the 13 px slot, so the 14 px swatch is a child the Loader leaves alone.
    Component {
        id: markComponent
        Item {
            id: slot
            property var entry: ({})
            Rectangle {
                anchors.centerIn: parent
                width: 14
                height: 14
                color: Theme.tag.fallback ? "transparent" : Theme.tag.menuColors[slot.entry.swatch] || "transparent"
                border.width: Theme.tag.fallback ? 2 : 0
                border.color: Theme.tag.menuColors[slot.entry.swatch] || "transparent"
                Text {
                    visible: Theme.tag.fallback
                    anchors.centerIn: parent
                    text: slot.entry.digit || ""
                    color: Theme.tag.menuColors[slot.entry.swatch] || "transparent"
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.caption
                    font.bold: true
                    textFormat: Text.PlainText
                }
            }
        }
    }

    Text {
        x: Style.spacing.rowPaddingX
        topPadding: Style.spacing.panelGap + Math.ceil(font.pixelSize * 0.15)
        bottomPadding: Style.spacing.rowGap
        text: "TAGS"
        color: Theme.color.muted
        font.family: Theme.font.family
        font.pixelSize: Theme.font.caption
        font.letterSpacing: 1
        textFormat: Text.PlainText
    }
    Repeater {
        id: tagRepeater
        model: root.entries
        delegate: SidebarRow {
            cursor: index + root.base === root.sidebar.cursorIndex
            focused: root.sidebar.focused
            tagMark: markComponent
            onActivated: function (idx) { root.sidebar.activate(idx + root.base) }
        }
    }
}
