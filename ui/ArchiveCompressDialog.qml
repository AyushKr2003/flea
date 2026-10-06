import QtQuick
import qs.Commons
import "." as Flea
import "js/Archive.js" as Archive

// The With-password compress card: the format segment, the name, the password pair and the header
// encryption switch, reusing the shipped dialog controls rather than drawing look-alikes.
Item {
    id: root

    property bool opened: false
    property var owner: null
    property var source: null
    property int count: 0
    property string parentLeaf: ""
    property var formats: ["7z", "zip"]
    property string format: "7z"
    property string stem: ""
    property bool encryptNames: true
    property bool busy: false
    property string errorText: ""
    property int focusPart: 0

    signal accepted(var source, string format, string name, string password, bool encryptNames)

    readonly property string password: passwordField.text
    readonly property string confirm: confirmField.text
    readonly property bool matched: root.password === root.confirm
    readonly property bool editable: !root.busy
    // An empty pair is a plain compress, so only a mismatch refuses; the backend reads no password then.
    readonly property bool canCompress: root.opened && root.editable && root.matched && root.name.length > 0
    readonly property string name: nameField.text
    readonly property var cancelItem: cancelButton
    readonly property var submitItem: compressButton
    readonly property var bodyItem: body
    readonly property int dialogWidth: 448
    readonly property int clampMargin: 8
    readonly property var cardItem: card

    anchors.fill: parent
    visible: root.opened
    z: 2

    // The tab order, which the segment opens: it is a Row with no key of its own, so the dialog
    // focuses it and answers its arrows at the root, the way the convert dialog answers its rows.
    function tabStops() {
        var stops = [formatRow, nameField.input, passwordField.input, confirmField.input]
        if (root.format === "7z") stops.push(encryptRow)
        return stops.concat([cancelButton, compressButton])
    }

    function stepTab(back) {
        var stops = root.tabStops()
        var at = -1
        for (var i = 0; i < stops.length; i++) {
            if (stops[i].activeFocus) { at = i; break }
        }
        var next = at < 0 ? (back ? stops.length - 1 : 0)
                          : (at + (back ? stops.length - 1 : 1)) % stops.length
        // The button and box rings read focusPart, so the ring follows the tab stop.
        if (stops[next] === cancelButton) root.focusPart = 5
        else if (stops[next] === compressButton) root.focusPart = 6
        else if (stops[next] === encryptRow) root.focusPart = 4
        else root.focusPart = 0
        stops[next].forceActiveFocus()
    }

    Keys.onEscapePressed: function (event) { root.close(); event.accepted = true }
    Keys.onTabPressed: function (event) { root.stepTab(false); event.accepted = true }
    Keys.onBacktabPressed: function (event) { root.stepTab(true); event.accepted = true }
    Keys.onPressed: function (event) {
        if (formatRow.activeFocus
                && (event.key === Qt.Key_Left || event.key === Qt.Key_Right)) {
            var at = root.formats.indexOf(root.format)
            root.chooseFormat(at + (event.key === Qt.Key_Right ? 1 : -1))
            event.accepted = true
            return
        }
        if (encryptRow.activeFocus && event.key === Qt.Key_Space) {
            root.encryptNames = !root.encryptNames
            event.accepted = true
            return
        }
        if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                && (formatRow.activeFocus || encryptRow.activeFocus)) {
            root.commit()
            event.accepted = true
        }
    }

    // Test seam for the offscreen threat walk: types into the pair the way keys would, so the
    // walk holds a real secret without reaching into the fields.
    function takeSecretForTest(secret) {
        passwordField.text = secret
        confirmField.text = secret
    }

    function open(paths, leaf, holder) {
        if (root.opened || !holder || !paths || paths.length === 0) return
        root.owner = holder
        var leaves = []
        for (var i = 0; i < paths.length; i++) {
            var cut = String(paths[i]).lastIndexOf("/")
            leaves.push(cut >= 0 ? String(paths[i]).substring(cut + 1) : String(paths[i]))
        }
        root.source = { paths: paths }
        root.count = paths.length
        root.parentLeaf = leaf || ""
        var offered = (holder.backend.archiveFormats || []).filter(function (f) {
            return f === "7z" || f === "zip"
        })
        root.formats = offered.length > 0 ? offered : ["7z"]
        root.format = root.formats.indexOf("7z") >= 0 ? "7z" : root.formats[0]
        root.stem = Archive.archiveStem(leaves, root.parentLeaf)
        root.encryptNames = true
        root.errorText = ""
        root.busy = false
        root.focusPart = 2
        root.opened = true
        body.contentY = 0
        nameField.text = root.stem + "." + root.format
        passwordField.text = ""
        confirmField.text = ""
        passwordField.takeFocus()
    }

    // The fields clear on close, so a secret never outlives the card that took it.
    function close() {
        if (!root.opened || root.busy)
            return
        passwordField.text = ""
        confirmField.text = ""
        nameField.text = ""
        root.stem = ""
        root.source = null
        root.opened = false
        if (root.owner && root.owner.listArea)
            root.owner.listArea.forceActiveFocus()
    }

    function chooseFormat(index) {
        if (!root.editable) return
        var next = root.formats[Math.max(0, Math.min(root.formats.length - 1, index))]
        if (next === root.format) return
        root.format = next
        if (next !== "7z") root.encryptNames = false
        nameField.text = root.stem + "." + next
    }

    function commit() {
        if (!root.canCompress) {
            if (!root.matched) root.errorText = "Passwords do not match."
            return
        }
        root.errorText = ""
        // Accepted before close, so the owner's submit still sees the source; close clears the fields.
        root.accepted(root.source, root.format, root.name, root.password,
                      root.encryptNames && root.format === "7z")
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
                        text: Archive.compressTitle(root.count)
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

                // The segment's own caption, in the same capitals DialogField draws above its box.
                Text {
                    x: Theme.spacing.rowPaddingX
                    width: parent.width - 2 * Theme.spacing.rowPaddingX
                    text: "FORMAT"
                    color: Theme.color.muted
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.caption
                    font.letterSpacing: Theme.font.caption * 0.1
                    textFormat: Text.PlainText
                }

                Flea.SettingsSegment {
                    id: formatRow
                    x: Theme.spacing.rowPaddingX
                    options: root.formats
                    value: root.format
                    onPicked: function (index) { root.chooseFormat(index) }
                }

                Flea.DialogField {
                    id: nameField
                    x: Theme.spacing.rowPaddingX
                    width: parent.width - 2 * Theme.spacing.rowPaddingX
                    label: "Name"
                    placeholder: "Archive.7z"
                    onAccepted: root.commit()
                    onTabbed: function (from, back) { root.stepTab(back) }
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

                Flea.DialogField {
                    id: confirmField
                    x: Theme.spacing.rowPaddingX
                    width: parent.width - 2 * Theme.spacing.rowPaddingX
                    label: "Confirm"
                    secret: true
                    onAccepted: root.commit()
                    onTabbed: function (from, back) { root.stepTab(back) }
                }

                Item {
                    id: encryptRow
                    width: parent.width
                    height: Theme.rowHeight
                    visible: root.format === "7z"
                    enabled: root.editable
                    Accessible.role: Accessible.CheckBox
                    Accessible.name: "Encrypt file names"
                    Accessible.checkable: true
                    Accessible.checked: root.encryptNames

                    Rectangle {
                        id: box
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacing.rowPaddingX
                        anchors.verticalCenter: parent.verticalCenter
                        width: ruleBox.implicitWidth
                        height: ruleBox.implicitHeight

                        Flea.CheckBox {
                            id: ruleBox
                            value: root.encryptNames ? "on" : "off"
                            focused: root.focusPart === 4
                            available: root.editable
                        }
                    }

                    Text {
                        anchors.left: box.right
                        anchors.leftMargin: Theme.spacing.gap
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Encrypt file names"
                        color: Theme.color.foreground
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.body
                        textFormat: Text.PlainText
                    }

                    TapHandler {
                        acceptedButtons: Qt.LeftButton
                        gesturePolicy: TapHandler.ReleaseWithinBounds
                        onTapped: if (root.editable) root.encryptNames = !root.encryptNames
                    }
                }

                Text {
                    x: Theme.spacing.rowPaddingX
                    width: parent.width - 2 * Theme.spacing.rowPaddingX
                    visible: root.errorText.length > 0
                    topPadding: 2 * Theme.spacing.hairline
                    bottomPadding: 2 * Theme.spacing.hairline
                    text: root.errorText
                    color: Theme.color.error
                    font { family: Theme.font.family; pixelSize: Theme.font.caption }
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                }

                Item {
                    width: parent.width
                    height: Theme.spacing.gap + Math.max(cancelButton.implicitHeight, compressButton.implicitHeight)
                    Row {
                        anchors.bottom: parent.bottom
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacing.rowPaddingX
                        spacing: Theme.spacing.gap

                        Flea.DialogButton {
                            id: cancelButton
                            label: "Cancel"
                            focused: root.focusPart === 5
                            available: !root.busy
                            enabled: available
                            onActivated: root.close()
                            onTabbed: function (from, back) { root.stepTab(back) }
                        }

                        Flea.DialogButton {
                            id: compressButton
                            label: "Compress"
                            primary: true
                            focused: root.focusPart === 6
                            available: root.canCompress
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
