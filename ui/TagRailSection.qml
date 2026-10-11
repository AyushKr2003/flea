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
    // Guarded as Sidebar.tagsListed is, because the rail can move to a pane that has built no tag state.
    readonly property var entries: Tags.railEntries(root.sidebar.navigationPane !== null && root.sidebar.navigationPane.tagState !== null
        ? root.sidebar.navigationPane.tagState.inUse : ({}))
    // Where this section's first row stands among the rail's entries.
    readonly property int base: root.sidebar.placesEntries.length - root.entries.length
    function itemAt(i) { return tagRepeater.itemAt(i) }
    // The board's 14 px swatch and the digit square's border; the heading leads and tracks as the rail's other headings do.
    readonly property int swatchSize: 14
    readonly property int fallbackBorder: 2
    readonly property real headingLead: 0.15
    readonly property real headingTracking: 1

    // The Loader sizes its item to the 13 px slot, so the 14 px swatch is a child the Loader leaves alone.
    Component {
        id: markComponent
        Item {
            id: slot
            property var entry: ({})
            Rectangle {
                anchors.centerIn: parent
                width: root.swatchSize
                height: root.swatchSize
                color: Theme.tag.fallback ? "transparent" : Theme.tag.menuColors[slot.entry.swatch] || "transparent"
                border.width: Theme.tag.fallback ? root.fallbackBorder : 0
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
        topPadding: Style.spacing.panelGap + Math.ceil(font.pixelSize * root.headingLead)
        bottomPadding: Style.spacing.rowGap
        text: "TAGS"
        color: Theme.color.muted
        font.family: Theme.font.family
        font.pixelSize: Theme.font.caption
        font.letterSpacing: root.headingTracking
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
