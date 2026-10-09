import QtQuick

// ui/SettingsSegment.qml's surface as the compress card's format row sets it.
Item {
    property var options: []
    property string value: ""

    signal picked(int index)
}
