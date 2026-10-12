import QtQuick

// A context menu's flyout fade, built by the menu's first flyout: the flyout fades on its own frame, and keeps
// the rows, the place and the action it hangs from at their last open values while it fades out.
QtObject {
    id: root

    required property var menu

    property Reveal reveal: Reveal { target: root.menu.submenuFrameItem; shown: root.menu.submenuOpen }
    property Binding heldRows: Binding { target: root.menu; property: "heldRows"; value: root.menu.submenuEntries; when: root.menu.submenuOpen; restoreMode: Binding.RestoreNone }
    property Binding heldOffset: Binding { target: root.menu; property: "heldOffset"; value: root.menu.submenuOffset(); when: root.menu.submenuOpen; restoreMode: Binding.RestoreNone }
    property Binding heldAction: Binding { target: root.menu; property: "heldAction"; value: root.menu.submenuAction(); when: root.menu.submenuOpen; restoreMode: Binding.RestoreNone }
}
