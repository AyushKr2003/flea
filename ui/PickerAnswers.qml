import QtQuick
import qs.Commons
import "." as Flea
import "js/Picker.js" as Picker

// The one row under the listing in every mode: the filter at the left, Cancel and the answer at the right.
Item {
    id: root
    required property var picker
    readonly property alias filterItem: filter
    anchors.left: parent.left
    anchors.right: parent.right
    height: Theme.spacing.hairline + 2 * Theme.spacing.rowPaddingX + cancelButton.height

    // Every answer is the one body control every dialog draws; the picker owns Tab.
    component Answer: Flea.DialogButton {
        id: answer
        property string name: answer.label
        tabHandle: true
        tabStop: true
        onTabbed: function(from, back) { root.picker.stepFocus(answer, back) }
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.color.surface
    }

    Rectangle {
        anchors.top: parent.top
        width: parent.width
        height: Theme.spacing.hairline
        color: root.picker.edge
    }

    Flea.PickerFilter {
        id: filter
        picker: root.picker
        x: Theme.spacing.rowPaddingX
        y: Theme.spacing.hairline + Theme.spacing.rowPaddingX
        height: cancelButton.height
    }

    Row {
        anchors.right: parent.right
        anchors.rightMargin: Theme.spacing.rowPaddingX
        y: Theme.spacing.hairline + Theme.spacing.rowPaddingX
        spacing: Theme.spacing.gap

        Answer {
            id: cancelButton
            label: "Cancel"
            onActivated: root.picker.cancel()
        }

        Answer {
            id: acceptButton
            label: Picker.acceptLabel(root.picker.req, root.picker.marks.length)
            primary: true
            available: root.picker.canAccept
            onActivated: root.picker.accept()
        }
    }

    function focusItems() { return [cancelButton, acceptButton].concat(filter.visible ? [filter] : []) }
    function controls() {
        return root.focusItems().map(function(item) { return root.picker.control(item.name, item, item.available) })
    }
}
