import QtQuick
import qs.Commons
import "." as Flea
import "js/Archive.js" as Archive

// The encrypted archive's card: its name, one masked field with the eye, and Extract. A wrong answer
// reopens it with its sentence; Cancel leaves nothing behind, because no job runs for this card.
Item {
    id: root

    property bool opened: false
    property var owner: null
    property string leaf: ""
    property string errorText: ""
    property int focusPart: 0

    signal accepted(string password)

    readonly property string password: passwordField.text
    readonly property bool editable: root.opened
    readonly property bool canExtract: root.opened && root.password.length > 0
    readonly property var cancelItem: cancelButton
    readonly property var submitItem: extractButton
    readonly property var bodyItem: body
    readonly property int dialogWidth: 448
    readonly property int clampMargin: 8
    readonly property var cardItem: card

    anchors.fill: parent
    visible: root.opened
    z: 2

    // The tab order, answered at the root the way the menu dialog answers its own: the field owns
    // Tab as a signal and never as a key, so the root steps and the field never swallows it.
    function stepTab(back) {
        var stops = [passwordField.input, cancelButton, extractButton]
        var at = -1
        for (var i = 0; i < stops.length; i++) {
            if (stops[i].activeFocus) { at = i; break }
        }
        var next = at < 0 ? (back ? stops.length - 1 : 0)
                          : (at + (back ? stops.length - 1 : 1)) % stops.length
        root.focusPart = next
        stops[next].forceActiveFocus()
    }

    Keys.onEscapePressed: function (event) { root.close(); event.accepted = true }
    Keys.onTabPressed: function (event) { root.stepTab(false); event.accepted = true }
    Keys.onBacktabPressed: function (event) { root.stepTab(true); event.accepted = true }

    // Test seam for the offscreen threat walk: types into the field the way keys would, so the
    // walk holds a real secret without reaching into the field.
    function takeSecretForTest(secret) {
        passwordField.text = secret
    }

    // A wrong answer asks again over the same card; a first ask carries no sentence. The err is
    // the backend's code, and the sentence is worded here from the template, never parsed.
    function open(name, holder, err) {
        if (root.opened || !holder) return
        root.owner = holder
        root.leaf = name || ""
        passwordField.text = ""
        root.errorText = Archive.wrongPassword(err) ? Archive.wrongPasswordSentence(root.leaf) : ""
        root.focusPart = 0
        root.opened = true
        body.contentY = 0
        passwordField.takeFocus()
    }

    // The field clears on close, so a secret never outlives the card that took it.
    function close() {
        if (!root.opened)
            return
        passwordField.text = ""
        root.errorText = ""
        root.leaf = ""
        root.opened = false
        if (root.owner && root.owner.listArea)
            root.owner.listArea.forceActiveFocus()
        root.owner = null
    }

    function commit() {
        if (!root.canExtract) return
        // Accepted before close, so the owner's submit still sees it; close clears the field.
        root.accepted(root.password)
        root.close()
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
                        width: parent.width
                        height: Theme.spacing.hairline
                        color: Theme.color.muted
                        opacity: 0.4
                    }
                }

                Flea.DialogField {
                    id: passwordField
                    x: Theme.spacing.rowPaddingX
                    width: parent.width - 2 * Theme.spacing.rowPaddingX
                    label: "Password"
                    secret: true
                    onAccepted: root.commit()
                    onTabbed: function (from, back) { root.stepTab(back) }
                }

                // The wrong-password specimen's error frame, in the error role.
                Rectangle {
                    x: Theme.spacing.rowPaddingX
                    width: parent.width - 2 * Theme.spacing.rowPaddingX
                    visible: root.errorText.length > 0
                    height: errorLabel.implicitHeight + 2 * Theme.spacing.gap
                    color: "transparent"
                    border.width: Theme.spacing.hairline
                    border.color: Theme.color.error

                    Text {
                        id: errorLabel
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.margins: Theme.spacing.gap
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.errorText
                        color: Theme.color.error
                        font { family: Theme.font.family; pixelSize: Theme.font.caption }
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                    }
                }

                Item {
                    width: parent.width
                    height: Theme.spacing.gap + Math.max(cancelButton.implicitHeight, extractButton.implicitHeight)
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
                            available: root.canExtract
                            enabled: available
                            onActivated: root.commit()
                            onTabbed: function (from, back) { root.stepTab(back) }
                        }
                    }
                }
            }
        }
    }
}
