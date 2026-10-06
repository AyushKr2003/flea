import Quickshell
import QtQuick
import qs.Commons
import "." as Flea
import "js/RunFile.js" as RunFile

// Opening an executable file asks once, in this one card: Cancel, Open as text, Run and Run in terminal, with the ring on the default. An AppImage the desktop names a handler for offers Open with first and focuses it instead.
FocusScope {
    id: root
    anchors.fill: parent
    visible: opened
    property bool opened: false
    property string path: ""
    property string kind: "script"
    property double size: 0
    property bool makeExecutable: false
    property bool hasHandler: false
    property double dev: 0
    property double ino: 0
    property double mtimeS: 0
    property double mtimeNs: 0
    property string tweak: ""
    property var pane: null
    readonly property string fileName: RunFile.leafOf(root.path)
    readonly property var buttons: RunFile.buttonsFor(root.kind, root.hasHandler, root.makeExecutable)
    // The board's own default: the handler where one is named, Run in terminal elsewhere.
    readonly property string defaultName: RunFile.defaultButton(root.kind, root.hasHandler)
    property string focusName: RunFile.START
    // The card's own single-flight run lane, one per window: a second press while one
    // runs is refused out loud rather than queued, so runBusy keeps its meaning.
    property string runCurrent: ""
    property string runAction: ""
    readonly property int isDirectoryStatus: 3
    readonly property var cardItem: card
    readonly property string titleText: title.text
    readonly property bool buttonsFit: buttons.width <= body.holderWidth
    function buttonItem(name) {
        var at = root.buttons.indexOf(name)
        return at >= 0 ? buttonRow.itemAt(at) : null
    }
    // One shot: the next open re-derives the ring, so a tweak never sticks to a later file.
    function open(info, pane) {
        root.pane = pane
        root.path = info.path || ""
        root.kind = info.kind || "script"
        root.size = info.size || 0
        root.makeExecutable = info.makeExecutable === true
        root.hasHandler = info.hasHandler === true
        root.dev = info.dev || 0
        root.ino = info.ino || 0
        root.mtimeS = info.mtimeS || 0
        root.mtimeNs = info.mtimeNs || 0
        root.tweak = info.tweak || RunFile.START
        root.focusName = RunFile.startFocus(root.buttons, root.tweak)
        body.contentY = 0
        root.opened = true
        root.forceActiveFocus()
    }
    function close() { root.opened = false }
    // A press lands on its own button first, so the accent never shows one choice while another is taken.
    function press(choice) {
        root.focusName = choice
        root.choose(choice)
    }
    function launch(action, command, path) {
        if (runChild.running) {
            root.pane.message("Still running the last file; try again in a moment.", false)
            return
        }
        root.runAction = action
        root.runCurrent = path
        runChild.command = command
        runChild.running = true
    }
    // Sample argv: flea --run /home/gm/tool.sh <the card's identity>, never a shell string.
    function run(path, dev, ino, size, mtimeS, mtimeNs) {
        root.launch("run", [Quickshell.env("FLEA_BIN") || "flea", "--run", path, dev, ino, size, mtimeS, mtimeNs], path)
    }
    function runTerminal(path, dev, ino, size, mtimeS, mtimeNs) {
        root.launch("terminal", [Quickshell.env("FLEA_BIN") || "flea", "--run-terminal", path, dev, ino, size, mtimeS, mtimeNs], path)
    }
    function openText(path) {
        root.launch("text", [Quickshell.env("FLEA_BIN") || "flea", "--open-text", path], path)
    }
    // The choice lands on the pane that asked, through ui/js/RunFile.js; Make
    // executable reuses the menu's permissions-batch path from there.
    function choose(choice) {
        root.opened = false
        RunFile.choose(root.pane, root, choice)
    }
    Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) root.choose("cancel")
        else if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) { event.accepted = true; return }
        else if (RunFile.activates(event.key)) root.choose(root.focusName)
        else root.focusName = RunFile.moved(root.buttons, root.focusName, event.key)
        if (root.opened) body.reveal(root.buttonItem(root.focusName))
        event.accepted = true
    }
    Process {
        id: runChild

        onExited: function (exitCode, exitStatus) {
            var action = root.runAction
            var path = root.runCurrent
            root.runAction = ""
            root.runCurrent = ""
            if (exitCode === 0)
                return
            if (exitCode === root.isDirectoryStatus) {
                root.pane.open(path)
                return
            }
            if (action === "run")
                root.pane.message("That program could not be run.", true)
            else if (action === "terminal")
                root.pane.message("That program could not be run in a terminal.", true)
            else
                root.pane.message("No text editor opened that file.", true)
        }
    }
    Rectangle {
        anchors.fill: parent
        color: Theme.color.background
        opacity: 0.5
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: root.choose("cancel")
            onWheel: function (wheel) { wheel.accepted = true }
        }
    }
    Rectangle {
        id: card
        x: Theme.cardOrigin(root.width, width)
        y: Theme.cardOrigin(root.height, height)
        // The board's own 448, grown by the text size the way the collision card is.
        width: Theme.cardSpan(root.contentWidth + 2 * root.cardPadding + 2 * Theme.spacing.hairline, root.width - 2 * Theme.spacing.gap)
        height: Theme.cardSpan(body.wanted + root.cardPadding + root.cardBottomPadding + 2 * Theme.spacing.hairline, root.height - 2 * Theme.spacing.gap)
        color: Theme.color.surface
        border.color: Theme.color.muted
        border.width: Theme.spacing.hairline
        radius: Style.cornerRadius
        readonly property real referenceScale: Theme.font.bodySmall / 13
        readonly property real cardPadding: Math.round(16 * referenceScale)
        readonly property real cardBottomPadding: Theme.spacing.rowPaddingX
        // The board's 414 content, since four buttons at DialogButton's pad and gap need 409.
        readonly property real contentWidth: Math.max(Math.round(414 * referenceScale * Theme.dialogWidthRatio), buttons.implicitWidth)
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onWheel: function (wheel) { wheel.accepted = true }
        }
        Flea.CardScroll {
            id: body
            bleed: Theme.ringClearance
            anchors.fill: parent
            anchors.leftMargin: card.cardPadding + Theme.spacing.hairline - Theme.ringClearance
            anchors.rightMargin: card.cardPadding + Theme.spacing.hairline - Theme.ringClearance
            anchors.topMargin: card.cardPadding + Theme.spacing.hairline - Theme.ringClearance
            anchors.bottomMargin: card.cardBottomPadding + Theme.spacing.hairline - Theme.ringClearance
            Column {
                width: body.holderWidth
                spacing: Theme.spacing.gap
                Row {
                    width: parent.width
                    spacing: Theme.spacing.gap
                    Text {
                        id: title
                        width: parent.width - escHint.width - parent.spacing
                        text: RunFile.titleFor(root.fileName)
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        color: Theme.color.foreground
                        font { family: Theme.font.family; pixelSize: Theme.font.body; bold: true }
                    }
                    Text {
                        id: escHint
                        text: "esc"
                        color: Theme.color.muted
                        font { family: Theme.font.family; pixelSize: Theme.font.caption }
                    }
                }
                Row {
                    width: parent.width
                    height: Theme.fileRowHeight
                    spacing: Theme.spacing.gap
                    Flea.Glyph {
                        width: Theme.markSize
                        height: parent.height
                        name: RunFile.glyphFor(root.kind)
                        color: Theme.color.foreground
                    }
                    Text {
                        width: Math.max(0, parent.width - Theme.markSize - parent.spacing)
                        anchors.verticalCenter: parent.verticalCenter
                        text: RunFile.subtitleFor(root.kind, root.size)
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        color: Theme.color.foreground
                        font { family: Theme.font.family; pixelSize: Theme.font.body }
                    }
                }
                Row {
                    id: buttons
                    anchors.right: parent.right
                    spacing: Theme.spacing.gap
                    Repeater {
                        id: buttonRow
                        model: root.buttons
                        Flea.DialogButton {
                            required property string modelData
                            label: RunFile.LABELS[modelData] || modelData
                            primary: modelData === root.defaultName
                            focused: root.focusName === modelData
                            onActivated: root.press(modelData)
                        }
                    }
                }
            }
        }
    }
}
