import QtQuick

// A context menu's flyout fade, built by its first flyout; it holds the flyout's rows, place and action at their last open values while it fades out.
QtObject {
    id: root

    required property var menu

    property Reveal reveal: Reveal { target: root.menu.submenuFrameItem; shown: root.menu.submenuOpen }
    // The rows are copied when the menu names some, never by a Binding: that one re-reads the emptied rows of a closing flyout before its own `when` goes false.
    property Connections heldRows: Connections {
        target: root.menu
        function onSubmenuEntriesChanged() { root.holdRows() }
    }
    property Binding heldOffset: Binding { target: root.menu; property: "heldOffset"; value: root.menu.submenuOffset(); when: root.menu.submenuOpen; restoreMode: Binding.RestoreNone }
    property Binding heldAction: Binding { target: root.menu; property: "heldAction"; value: root.menu.submenuAction(); when: root.menu.submenuOpen; restoreMode: Binding.RestoreNone }

    function holdRows() {
        var rows = root.menu.submenuEntries
        if (rows && rows.length > 0) root.menu.heldRows = rows
    }
    Component.onCompleted: root.holdRows()
}
