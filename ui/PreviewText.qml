import QtQuick
import Quickshell.Io
import qs.Commons
import "." as Flea
import "js/Markdown.js" as Markdown

// Quick Look's code and text pane: the bar, then the file's lines coloured by the backend, a gutter for code and none for plain text.
// A network or phone file is read here, under the size gate, so the backend is never given its path.
Item {
    id: root

    property bool active: false
    property string path: ""
    property int size: 0

    // FileView reads the whole file into memory, so this is the largest read a preview will start.
    // Remote storage keeps the smaller 256 KiB gate through maxBytes, and refuses past it too.
    property int maxBytes: 1048576
    // True on network and phone storage, where the backend is never given the path.
    property bool truncate: false
    // The backend that colours the lines; a bare stub leaves the file's own text drawn plain.
    property var backend: null
    property string markName: "file"
    property bool numbered: false
    property bool wrap: false
    // The keyboard is on the bar's close mark; Quick Look's key handler owns the walk.
    property bool closeFocused: false

    signal closeRequested

    readonly property bool engine: root.backend !== null && typeof root.backend.askCode === "function"
    readonly property bool fromFile: root.truncate || !root.engine
    // Over the gate by the listing's size, or by the backend's own count when the file grew since.
    readonly property bool tooLarge: root.size > root.maxBytes || lines.answer === "large"
    property bool readFailed: false
    readonly property bool failed: root.readFailed || lines.answer === "failed"
    readonly property bool binary: lines.answer === "binary"
    // For ui/Ipc.qml: the drawn lines and their box.
    readonly property Item bodyItem: lines
    readonly property bool firstScreen: lines.firstScreen
    // CodeLines' scrolling view, which the scroll bar and the wrap toggle read; its one Flickable child.
    readonly property var list: {
        var kids = lines.children
        for (var i = 0; i < kids.length; i++)
            if (kids[i].contentY !== undefined) return kids[i]
        return null
    }
    function shownText() { return root.fromFile ? file.text() : lines.lines.join("\n") }
    readonly property string status: {
        if (root.tooLarge) return "This file is too large to preview."
        if (root.failed) return "This file could not be read."
        return lines.answer !== "" ? "ready" : "loading"
    }

    visible: root.active

    // The line at the top of the view stays at the top while the rows change height.
    onWrapChanged: if (root.list !== null) Qt.callLater(root.keepTop, Math.max(0, root.list.indexAt(0, root.list.contentY + 1)))
    function keepTop(top) {
        root.list.forceLayout()
        root.list.positionViewAtIndex(top, ListView.Beginning)
    }

    FileView {
        id: file
        path: (root.active && root.size <= root.maxBytes && root.fromFile) ? root.path : ""
        printErrors: false
        onLoadFailed: root.readFailed = true
        onPathChanged: root.readFailed = false
    }

    Flea.QuickLookBar {
        id: bar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        markName: root.markName
        name: root.path.substring(root.path.lastIndexOf("/") + 1)
        countLabel: lines.settled ? Markdown.countLine(lines.total) : ""
        closeFocused: root.closeFocused
        onCloseRequested: root.closeRequested()
    }

    Flea.CodeLines {
        id: lines
        anchors.fill: parent
        anchors.topMargin: bar.height + Theme.spacing.rowPaddingX
        anchors.margins: Theme.spacing.rowPaddingX
        visible: !root.tooLarge && !root.failed && !root.binary
        backend: root.backend
        slot: "look"
        path: root.path
        fromText: root.fromFile
        text: root.fromFile && file.loaded ? file.text() : null
        active: root.active && root.size <= root.maxBytes
        numbered: root.numbered
        wrap: root.wrap
        scrolls: true
        pixelSize: Theme.font.body

        Flea.FastScrollHandler {
            flickable: root.list
        }

        Flea.ViewportScrollBar {
            anchors { top: parent.top; right: parent.right }
            flickable: root.list
        }
    }

    // The kind's mark and the one line saying why the file has nothing to draw.
    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        y: bar.height + Math.round((parent.height - bar.height - height) / 2)
        spacing: Theme.spacing.gap
        visible: root.binary || (root.tooLarge && !root.failed)

        Flea.Glyph {
            anchors.horizontalCenter: parent.horizontalCenter
            maxSize: Theme.stateMarkSize
            width: Theme.stateMarkSize
            height: Theme.stateMarkSize
            name: root.markName
            color: Theme.color.muted
            opacity: 0.7
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.binary ? "binary file" : "too large to preview"
            color: Theme.color.muted
            font.family: Theme.font.family
            font.pixelSize: Theme.font.caption
            textFormat: Text.PlainText
        }
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        y: bar.height + Math.round((parent.height - bar.height - height) / 2)
        visible: root.failed
        text: root.status
        color: Theme.color.muted
        font.family: Theme.font.family
        font.pixelSize: Theme.font.body
        textFormat: Text.PlainText
    }
}
