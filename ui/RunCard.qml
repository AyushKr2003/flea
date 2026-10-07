import Quickshell
import Quickshell.Io
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
    // The listed path the ask was opened from, which names the row; path names the resolved target it runs.
    property string listedPath: ""
    property bool makeExecutable: false
    property bool hasHandler: false
    // dev and ino stay strings end to end: a double cannot hold every 64-bit value exactly.
    property string dev: ""
    property string ino: ""
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
    // The run card's own failures, the same numbers src/runfile.rs answers with.
    readonly property int runChangedStatus: 6
    readonly property int runNoExecStatus: 7
    readonly property int runSpawnStatus: 8
    readonly property var cardItem: card
    readonly property string titleText: title.text
    readonly property bool buttonsFit: buttons.width <= body.holderWidth
    function buttonItem(name) {
        var at = root.buttons.indexOf(name)
        return at >= 0 ? buttonRow.itemAt(at) : null
    }
    // One shot: the next open re-derives the ring, so a tweak never sticks to a later file.
    // The ask's raw text is parsed here, so the card names the resolved target it will run.
    function open(info, pane) {
        var ask = RunFile.parseAsk(info.raw || "")
        if (ask === null) {
            if (pane) pane.message("The run card could not ask about that file.", true)
            return
        }
        root.pane = pane
        root.path = ask.target
        root.listedPath = info.path || ask.target
        root.kind = ask.kind
        root.size = ask.size
        root.makeExecutable = ask.makeExecutable
        root.hasHandler = ask.hasHandler
        root.dev = ask.dev
        root.ino = ask.ino
        root.mtimeS = ask.mtimeS
        root.mtimeNs = ask.mtimeNs
        root.tweak = info.tweak || ""
        root.focusName = RunFile.startFocus(root.buttons, root.tweak)
        body.contentY = 0
        root.opened = true
        root.forceActiveFocus()
    }
    // Closing hands the keyboard back to the asking pane, whatever closed it.
    function close() {
        root.opened = false
        if (root.pane) root.pane.forceActiveFocus()
    }
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
    function openText(path, pane) {
        if (pane) root.pane = pane
        root.launch("text", [Quickshell.env("FLEA_BIN") || "flea", "--open-text", path], path)
    }
    // The choice lands on the pane that asked, through ui/js/RunFile.js; Make
    // executable reuses the menu's permissions-batch path from there.
    function choose(choice) {
        root.close()
        RunFile.choose(root.pane, root, choice)
    }
    // A held key never presses the default: repeats move nothing and run nothing.
    function keyPressed(key, autoRepeat, modifiers) {
        if (key === Qt.Key_Escape) { root.choose("cancel"); return }
        if (modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
        if (autoRepeat === true) return
        if (RunFile.activates(key)) root.choose(root.focusName)
        else root.focusName = RunFile.moved(root.buttons, root.focusName, key)
        if (root.opened) body.reveal(root.buttonItem(root.focusName))
    }
    Keys.onPressed: function (event) {
        root.keyPressed(event.key, event.isAutoRepeat, event.modifiers)
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
            if (exitCode === root.runChangedStatus) {
                root.pane.message("That file changed since the card asked, so it was not run.", true)
                return
            }
            if (exitCode === root.runNoExecStatus) {
                root.pane.message("That program is on a volume that does not allow running files.", true)
                return
            }
            if (exitCode === root.runSpawnStatus) {
                if (action === "run")
                    root.pane.message("Nothing on this system could run that file.", true)
                else if (action === "terminal")
                    root.pane.message("Nothing on this system could run that file in a terminal.", true)
                else
                    root.pane.message("Nothing on this system could open that file as text.", true)
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
        width: Theme.cardSpan(card.contentWidth + 2 * card.cardPadding + 2 * Theme.spacing.hairline, root.width - 2 * Theme.spacing.gap)
        height: Theme.cardSpan(body.wanted + card.cardPadding + card.cardBottomPadding + 2 * Theme.spacing.hairline, root.height - 2 * Theme.spacing.gap)
        color: Theme.color.surface
        border.color: Theme.color.muted
        border.width: Theme.spacing.hairline
        radius: Style.cornerRadius
        readonly property real referenceScale: Theme.font.bodySmall / referenceBody
        readonly property real cardPadding: Math.round(cardPad * referenceScale)
        readonly property real cardBottomPadding: Theme.spacing.rowPaddingX
        // The board's 414 content, since four buttons at DialogButton's pad and gap need 409.
        readonly property real contentWidth: Math.max(Math.round(contentBase * referenceScale * Theme.dialogWidthRatio), buttons.implicitWidth)
        // The board's own reference size, pad and content width, so no bare number sits in an expression.
        readonly property real referenceBody: 13
        readonly property real cardPad: 16
        readonly property real contentBase: 414
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
