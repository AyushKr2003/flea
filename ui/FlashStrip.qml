import QtQuick
import "." as Flea

// The flasher's own strip: Back, an unavailable Up, the title, no action. The pane's Back, Esc
// and Backspace all leave through the view's close, never through a strip control of their own.
Rectangle {
    id: root
    signal back()
    width: 0
    height: Theme.chromeHeight
    color: Theme.color.surface
    Row {
        anchors.fill: parent
        anchors.leftMargin: Theme.spacing.rowPaddingX
        anchors.rightMargin: Theme.spacing.rowPaddingX
        spacing: Theme.spacing.gap
        Flea.ChromeButton {
            glyph: "arrow-left"
            onActivated: root.back()
        }
        Flea.ChromeButton {
            glyph: "arrow-up"
            accessName: "Up unavailable in Flash"
            enabled: false
            Accessible.ignored: false
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Flash image"
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: Theme.color.foreground
            font { family: Theme.font.family; pixelSize: Theme.font.caption }
        }
    }
    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: Theme.spacing.hairline; color: Theme.color.foreground; opacity: 0.12 }
}
