import QtQuick
import qs.Commons

// One rail heading: the caption text with the rail's lead and tracking.
Text {
    id: root
    property real topExtra: 0
    property bool noBottom: false
    x: Style.spacing.rowPaddingX
    topPadding: root.topExtra + Math.ceil(font.pixelSize * 0.15)
    bottomPadding: root.noBottom ? 0 : Style.spacing.rowGap
    color: Theme.color.muted
    font.family: Theme.font.family
    font.pixelSize: Theme.font.caption
    font.letterSpacing: 1
    textFormat: Text.PlainText
}
