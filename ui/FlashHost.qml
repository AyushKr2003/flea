import QtQuick
import "js/Focus.js" as Focus
import "js/Flash.js" as Flash

// Built once per window on first use with no placeholder; one host serves every later open and marks its pane active.
Loader {
    id: root
    property var coverPane: null
    active: false
    visible: opened
    readonly property bool opened: item !== null && item.opened
    readonly property int count: item ? item.driveCount : 0
    // The counts zone's own line while the host owns the pane, read by the window.
    readonly property string countText: Flash.drivesLine(root.count)

    // Covers the opening pane's slot the way Trash does, then opens with the half the menu came from.
    // A second pane cannot take the host while a flash runs: the running view owns its replies.
    function openFor(pane, image, device) {
        if (root.item && root.item.pane !== pane && root.item.transfer.running === true) {
            pane.message(Flash.alreadyRunning(), false)
            return
        }
        root.coverPane = pane
        root.parent = pane
        root.anchors.fill = pane
        root.anchors.leftMargin = pane.sidebarWidth
        pane.flashActive = true
        root.active = true
        if (!root.item || root.item.pane !== pane)
            root.setSource("FlashView.qml", { pane: pane, statusBar: pane.statusBar })
        if (image && image.length > 0)
            root.item.openWithImage(image)
        else
            root.item.openWithDrive(device)
    }
    function close() {
        if (root.opened)
            root.item.close()
        if (root.coverPane)
            root.coverPane.flashActive = false
    }
    // The read-only seam's own flash readers, so ui/Ipc.qml stays one call per entry point.
    function describe() {
        var view = root.item
        if (!view)
            return "{\"opened\":false}"
        return JSON.stringify({ opened: view.opened, cursor: view.cursor,
            image: view.image ? view.image.path : "", drives: view.drives.length,
            selected: view.selected, running: view.running,
            phase: view.running ? view.transfer.phase : "",
            ending: view.ending ? view.ending.headline : "" })
    }
    function controlItem(name) {
        var view = root.item
        if (!view)
            return null
        return name === "flash" ? view.flashItem : name === "cancel" ? view.cancelItem
            : name === "end" ? view.endItem : null
    }
    Connections {
        target: root.item
        function onBackRequested() {
            if (!root.coverPane)
                return
            root.coverPane.focusView = Focus.LIST
            root.coverPane.listArea.forceActiveFocus()
        }
        function onFocusRailRequested() {
            if (root.coverPane)
                root.coverPane.focusView = Focus.RAIL
        }
    }
}
