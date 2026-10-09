import QtQuick

// ui/DialogField.qml's surface: text is what the operator typed, accepted is Enter in the field.
Item {
    property string label: ""
    property string placeholder: ""
    property bool secret: false
    property string text: ""
    readonly property Item input: box

    signal accepted()
    signal tabbed(var from, bool back)

    function takeFocus() { box.forceActiveFocus() }

    Item { id: box }
}
