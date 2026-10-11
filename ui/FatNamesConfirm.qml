import QtQuick
import qs.Commons
import "." as Flea
import "js/Collide.js" as Collide
import "js/Icons.js" as Icons

// The names a FAT-family destination cannot hold, on ui/CollideConfirm.qml's card, keys and look; Rename and copy opens focused, the one choice that loses nothing.
FocusScope {
    id: root
    anchors.fill: parent
    visible: opened
    property bool opened: false
    property string titleText: ""
    property var renames: []
    property string noteText: ""
    property string focusName: Collide.FAT_DEFAULT
    // The board's own reference size, pad and content width, so no bare number sits in an expression.
    readonly property real referenceBody: 13
    readonly property real cardPad: 16
    readonly property real contentBase: 368
    readonly property real referenceScale: Theme.font.bodySmall / referenceBody
    readonly property real cardPadding: Math.round(cardPad * referenceScale)
    readonly property real cardBottomPadding: Theme.spacing.rowPaddingX
    // The card grows with the labels rather than wrapping one, and Rename and copy keeps the ring.
    readonly property real contentWidth: Math.max(Math.round(contentBase * referenceScale * Theme.dialogWidthRatio), buttons.implicitWidth)
    signal chosen(string choice)
    readonly property var cardItem: card
    readonly property bool buttonsFit: buttons.width <= body.holderWidth
    function buttonItem(name) { return ({cancel: cancelButton, skip: skipButton, rename: renameButton})[name] || null }
    function open(heading, list, note) {
        titleText = heading
        renames = list
        noteText = note
        focusName = Collide.FAT_DEFAULT
        body.contentY = 0
        opened = true
        forceActiveFocus()
    }
    function choose(choice) {
        opened = false
        chosen(choice)
    }
    // A press lands on its own button first, so the accent never shows one choice while another is taken.
    function press(choice) {
        focusName = choice
        choose(choice)
    }
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) root.choose("cancel")
        else if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) { event.accepted = true; return }
        else if (Collide.activates(event.key)) root.choose(root.focusName)
        else root.focusName = Collide.walk(["cancel", "skip", "rename"], root.focusName, event.key, event.modifiers, "cancel")
        if (root.opened) body.reveal(root.buttonItem(root.focusName))
        event.accepted = true
    }
    Flea.DialogScrim {
        onDismissed: root.choose("cancel")
    }
    Rectangle {
        id: card
        x: Theme.cardOrigin(root.width, width)
        y: Theme.cardOrigin(root.height, height)
        width: Theme.cardSpan(root.contentWidth + 2 * root.cardPadding + 2 * Theme.spacing.hairline, root.width - 2 * Theme.spacing.gap)
        height: Theme.cardSpan(body.wanted + root.cardPadding + root.cardBottomPadding + 2 * Theme.spacing.hairline, root.height - 2 * Theme.spacing.gap)
        color: Theme.color.surface
        border.color: Theme.color.muted
        border.width: Theme.spacing.hairline
        radius: Style.cornerRadius
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onWheel: function(wheel) { wheel.accepted = true }
        }
        Flea.CardScroll {
            id: body
            bleed: Theme.focusClearance
            anchors.fill: parent
            anchors.leftMargin: root.cardPadding + Theme.spacing.hairline - Theme.focusClearance
            anchors.rightMargin: root.cardPadding + Theme.spacing.hairline - Theme.focusClearance
            anchors.topMargin: root.cardPadding + Theme.spacing.hairline - Theme.focusClearance
            anchors.bottomMargin: root.cardBottomPadding + Theme.spacing.hairline - Theme.focusClearance
            Column {
                width: body.holderWidth
                spacing: Theme.spacing.gap
                Flea.DialogTitle {
                    width: parent.width
                    text: root.titleText
                }
                Rectangle { width: parent.width; height: Theme.spacing.hairline; color: Theme.color.muted; opacity: 0.4 }
                Column {
                    width: parent.width
                    Repeater {
                        model: root.renames
                        delegate: Row {
                            id: nameRow
                            required property var modelData
                            // The label column: what is left of the row once the mark and its gap are taken.
                            readonly property real labelWidth: Math.max(0, width - Theme.markSize - spacing)
                            width: parent.width
                            height: Theme.fileRowHeight
                            spacing: Theme.spacing.gap
                            Flea.Glyph { width: Theme.markSize; height: parent.height; name: nameRow.modelData.d ? "folder" : Icons.glyphFor(nameRow.modelData.i); color: Theme.color.foreground }
                            Text {
                                id: oldName
                                width: Math.min(implicitWidth, Math.max(0, nameRow.labelWidth - arrow.implicitWidth))
                                anchors.verticalCenter: parent.verticalCenter
                                text: nameRow.modelData.old
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                color: Theme.color.muted
                                font { family: Theme.font.family; pixelSize: Theme.font.body }
                            }
                            Text {
                                id: arrow
                                anchors.verticalCenter: parent.verticalCenter
                                text: " → "
                                color: Theme.color.foreground
                                font { family: Theme.font.family; pixelSize: Theme.font.body }
                            }
                            Text {
                                width: Math.max(0, nameRow.labelWidth - oldName.width - arrow.implicitWidth)
                                anchors.verticalCenter: parent.verticalCenter
                                text: nameRow.modelData.new
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                color: Theme.color.foreground
                                font { family: Theme.font.family; pixelSize: Theme.font.body }
                            }
                        }
                    }
                }
                Text {
                    width: parent.width
                    text: root.noteText
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    color: Theme.color.foreground
                    font { family: Theme.font.family; pixelSize: Theme.font.caption }
                }
                Row {
                    id: buttons
                    anchors.right: parent.right
                    spacing: Theme.spacing.gap
                    Flea.DialogButton { id: cancelButton; label: Collide.FAT_BUTTONS.cancel; focused: root.focusName === "cancel"; onActivated: root.press("cancel") }
                    Flea.DialogButton { id: skipButton; label: Collide.FAT_BUTTONS.skip; focused: root.focusName === "skip"; onActivated: root.press("skip") }
                    Flea.DialogButton { id: renameButton; label: Collide.FAT_BUTTONS.rename; primary: true; focused: root.focusName === "rename"; onActivated: root.press("rename") }
                }
            }
        }
    }
}
