import QtQuick
import "." as Flea
import "js/Buttons.js" as Buttons

// The Display board's two-value control: both names side by side, the current one bright, rather than
// the chevron walk a longer list needs. ui/SettingsRow.qml draws it for any row whose model names its
// options, and the row above owns the writer, so nothing here holds state.
Row {
    id: root

    property var options: []
    property string value: ""
    property var glyphs: []
    // A host that puts the row in its Tab order (a dialog's Format) sets this; Settings never focuses it.
    property bool tabStop: false

    // The option a pointer chose, which is never the one already showing.
    signal picked(int index)

    spacing: Theme.spacing.hairline * Buttons.SEGMENT_GAP

    Repeater {
        model: root.options

        delegate: Rectangle {
            id: segment
            required property var modelData
            required property int index

            readonly property bool current: segment.modelData === root.value
            readonly property string glyph: root.glyphs[segment.index] || ""
            // A segment that takes the keyboard (a dialog's Tab stop) marks its current cell as DialogButton marks a focused set member.
            readonly property bool focusedHere: root.tabStop && segment.current && root.activeFocus && segment.glyph.length === 0

            // The WCAG floor the Blueprint sets for a compact control, which this row has room for.
            width: segment.glyph ? Math.max(Theme.hitMin, Theme.railIconSize + 2 * (Theme.spacing.gap - Theme.spacing.hairline))
                                 : name.implicitWidth + 2 * Theme.spacing.gap
            height: Theme.hitMin
            // Containers rule 4: a segmented cell is never filled, so the choice reads as brightness.
            color: "transparent"
            // Rule 3: words in a set are Tier B and every member wears the box; glyphs in a strip are
            // Tier A, where a box around four marks would be furniture.
            border.width: segment.glyph ? 0 : Theme.spacing.hairline
            border.color: segment.focusedHere && Theme.color.accentHasHue ? Theme.color.accent
                : segment.current ? Theme.color.foreground : Theme.color.muted
            Accessible.role: Accessible.Button
            Accessible.name: String(segment.modelData)
            Accessible.onPressAction: root.picked(segment.index)

            Flea.Glyph {
                anchors.centerIn: parent
                visible: segment.glyph.length > 0
                width: Theme.railIconSize
                height: width
                name: segment.glyph || "file"
                color: segment.current ? Theme.color.foreground : Theme.color.muted
            }

            Text {
                id: name
                visible: segment.glyph.length === 0
                anchors.centerIn: parent
                text: segment.modelData
                color: segment.current ? Theme.color.foreground : Theme.color.muted
                font.family: Theme.font.family
                font.pixelSize: Theme.font.caption
                textFormat: Text.PlainText
            }

            // A hueless accent would read as picked, so there the focused cell keeps buttons A's ring, as a set member does.
            Loader {
                anchors.fill: parent
                anchors.margins: -Buttons.RING
                active: root.tabStop
                sourceComponent: Rectangle {
                    color: "transparent"
                    border.width: Buttons.RING
                    border.color: Theme.color.foreground
                    visible: segment.focusedHere && !Theme.color.accentHasHue
                }
            }

            HoverHandler {
                cursorShape: Qt.PointingHandCursor
            }

            TapHandler {
                acceptedButtons: Qt.LeftButton
                gesturePolicy: TapHandler.ReleaseWithinBounds
                onTapped: if (!segment.current) root.picked(segment.index)
            }
        }
    }
}
