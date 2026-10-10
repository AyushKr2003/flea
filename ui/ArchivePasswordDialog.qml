import QtQuick
import qs.Commons
import "." as Flea
import "js/Archive.js" as Archive

// The encrypted archive's card: its name, one masked field with the eye, and Extract; a wrong answer reopens it with its sentence and the typed bullets.
Item {
    id: root

    property bool opened: false
    property var owner: null
    property var source: null
    property string leaf: ""
    property string errorText: ""
    property int focusPart: 0
    // The archive and destination a submit sent: its secret stays in the hidden field only until the backend answers that extract.
    property string retryKey: ""

    signal accepted(var source, string password)

    readonly property string password: passwordField.text
    readonly property bool canExtract: root.opened && root.password.length > 0
    readonly property bool fieldError: root.errorText.length > 0
    readonly property var cancelItem: cancelButton
    readonly property var submitItem: extractButton
    readonly property var bodyItem: body
    readonly property int dialogWidth: 448
    readonly property int clampMargin: 8
    readonly property var cardItem: card

    anchors.fill: parent
    visible: root.opened
    z: 2

    // The tab order, answered at the root because the field owns Tab as a signal; a disabled stop is skipped.
    function tabStops() {
        return [passwordField.input, cancelButton, extractButton].filter(function (s) { return s.enabled })
    }

    function stepTab(back) {
        var stops = root.tabStops()
        var at = -1
        for (var i = 0; i < stops.length; i++) {
            if (stops[i].activeFocus) { at = i; break }
        }
        var next = at < 0 ? (back ? stops.length - 1 : 0)
                          : (at + (back ? stops.length - 1 : 1)) % stops.length
        root.focusPart = stops[next] === cancelButton ? 1 : stops[next] === extractButton ? 2 : 0
        stops[next].forceActiveFocus()
    }

    Keys.onEscapePressed: function (event) { root.close(); event.accepted = true }
    Keys.onTabPressed: function (event) { root.stepTab(false); event.accepted = true }
    Keys.onBacktabPressed: function (event) { root.stepTab(true); event.accepted = true }

    // Test seam for the threat walk: types into the field the way keys would.
    function takeSecretForTest(secret) {
        passwordField.text = secret
    }

    // What a capture reads instead of the field: whether bullets are drawn, the error frame and the eye, never a typed character.
    function captureState() {
        return { filled: passwordField.text.length > 0, fieldError: passwordField.error,
                 revealed: passwordField.revealed, eye: passwordField.eyeCentre() }
    }

    function keyOf(path, dest) {
        return String(path) + "\n" + String(dest)
    }

    // The source is { path, dest }; err is the backend's code, and a first ask carries no sentence.
    // Only the wrong-password answer to this card's own submit finds its typed secret still in the field.
    function open(source, holder, err) {
        if (root.opened || !holder || !source) return
        var again = Archive.wrongPassword(err) && root.retryKey === root.keyOf(source.path, source.dest)
        root.retryKey = ""
        root.owner = holder
        root.source = source
        root.leaf = Archive.sourceLeaf(source)
        if (!again) passwordField.text = ""
        root.errorText = Archive.wrongPassword(err) ? Archive.wrongPasswordSentence(root.leaf) : ""
        root.focusPart = 0
        root.opened = true
        body.contentY = 0
        passwordField.takeFocus()
        passwordField.input.cursorPosition = passwordField.text.length
    }

    // Cancel, esc and the ground clear the field, so a secret never outlives the card that took it.
    function close() {
        if (!root.opened)
            return
        passwordField.text = ""
        root.retryKey = ""
        root.hide()
    }

    function hide() {
        root.errorText = ""
        root.leaf = ""
        root.source = null
        root.opened = false
        if (root.owner && root.owner.listArea)
            root.owner.listArea.forceActiveFocus()
        root.owner = null
    }

    // A closed card drops a kept secret: any answer but this extract's wrong password, or a re-ask refused as busy.
    function forget() {
        if (root.opened) return
        passwordField.text = ""
        root.retryKey = ""
    }

    function answered(err, path, dest) {
        if (root.retryKey === "") return
        if (Archive.wrongPassword(err) && root.keyOf(path, dest) === root.retryKey) return
        root.forget()
    }

    function commit() {
        if (!root.opened) return
        // Extract stays live, as the board draws it and a primary is never the dimmer button; an empty field asks for the password.
        if (!root.canExtract) {
            root.errorText = "Type a password first."
            root.focusPart = 0
            passwordField.takeFocus()
            return
        }
        // Accepted before the card hides, so the owner's submit still sees it; the field keeps the secret until the answer.
        root.accepted(root.source, root.password)
        root.retryKey = root.keyOf(root.source.path, root.source.dest)
        root.hide()
    }

    // A dimmed ground, and a click on it is a cancel, the same shape the convert dialog uses.
    Rectangle {
        anchors.fill: parent
        color: Theme.color.background
        opacity: 0.5

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            hoverEnabled: true
            onClicked: root.close()
            onWheel: function (wheel) { wheel.accepted = true }
        }
    }

    Rectangle {
        id: card
        x: Theme.cardOrigin(root.width, width)
        y: Theme.cardOrigin(root.height, height)
        width: Theme.cardSpan(Theme.space(root.dialogWidth) * Theme.dialogWidthRatio, root.width - 2 * root.clampMargin)
        // Clamped to the window; the body scrolls whatever the clamp cut, see ui/CardScroll.qml.
        height: Theme.cardSpan(body.wanted + 2 * Theme.spacing.rowPaddingX, root.height - 2 * root.clampMargin)
        color: Theme.color.surface
        border.width: Theme.spacing.hairline
        border.color: Theme.color.muted
        radius: Style.cornerRadius

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            hoverEnabled: true
            onClicked: {}
            onWheel: function (wheel) { wheel.accepted = true }
        }

        Flea.CardScroll {
            id: body
            bleedY: Theme.ringClearance
            anchors.fill: parent
            anchors.topMargin: Theme.spacing.rowPaddingX - Theme.ringClearance
            anchors.bottomMargin: Theme.spacing.rowPaddingX - Theme.ringClearance

            Column {
                width: parent.width
                spacing: Theme.spacing.rowPaddingX

                Item {
                    width: parent.width
                    height: header.implicitHeight + Theme.spacing.gap

                    Flea.DialogTitle {
                        id: header
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.margins: Theme.spacing.rowPaddingX
                        text: Archive.encryptedTitle(root.leaf)
                        elide: Text.ElideMiddle
                    }

                    Rectangle {
                        anchors.bottom: parent.bottom
                        x: Theme.spacing.rowPaddingX
                        width: parent.width - 2 * Theme.spacing.rowPaddingX
                        height: Theme.spacing.hairline
                        color: Theme.color.muted
                        opacity: 0.4
                    }
                }

                // The wrong-password specimen: the field in the error frame, then its bare sentence directly under it.
                Column {
                    x: Theme.spacing.rowPaddingX
                    width: parent.width - 2 * Theme.spacing.rowPaddingX
                    spacing: Theme.spacing.gap

                    Flea.DialogField {
                        id: passwordField
                        width: parent.width
                        label: "Password"
                        secret: true
                        error: root.fieldError
                        onEdited: root.errorText = ""
                        onAccepted: root.commit()
                        onTabbed: function (from, back) { root.stepTab(back) }
                    }

                    Text {
                        width: parent.width
                        visible: root.errorText.length > 0
                        text: root.errorText
                        color: Theme.color.error
                        font { family: Theme.font.family; pixelSize: Theme.font.caption }
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                    }
                }

                Item {
                    width: parent.width
                    height: Math.max(cancelButton.implicitHeight, extractButton.implicitHeight)
                    Row {
                        anchors.bottom: parent.bottom
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacing.rowPaddingX
                        spacing: Theme.spacing.gap

                        Flea.DialogButton {
                            id: cancelButton
                            label: "Cancel"
                            focused: root.focusPart === 1
                            available: true
                            enabled: true
                            onActivated: root.close()
                            onTabbed: function (from, back) { root.stepTab(back) }
                        }

                        Flea.DialogButton {
                            id: extractButton
                            label: "Extract"
                            primary: true
                            focused: root.focusPart === 2
                            onActivated: root.commit()
                            onTabbed: function (from, back) { root.stepTab(back) }
                        }
                    }
                }
            }
        }
    }
}
