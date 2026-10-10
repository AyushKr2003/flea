import QtQuick
import "js/Unlock.js" as Unlock

// Unlock (U039): the encrypted-drive dialog's host, over the whole window.
// Created once per window on first use, so no placeholder object stands before it; the unlocked-drive follow lives here.
Item {
    id: root
    anchors.fill: parent
    property var window: null
    property var footer: null
    property var sidebar: null
    property string pendingPath: ""
    property int lockedCursor: -1
    // The device flea --unlock opened on, until a rail row names it.
    property string unnamedDevice: ""
    readonly property bool opened: loader.item !== null && loader.item.opened
    // The test seam reads the card through this, so no writer ever reaches past the host.
    readonly property var dialog: loader.item

    function openFor(device, label, size, fstype, rail) {
        if (rail !== undefined && rail !== null)
            root.sidebar = rail
        root.lockedCursor = root.cursorOnRow(device)
        loader.active = true
        loader.item.openFor(device, label, size, fstype)
    }
    // flea --unlock may open before the rail's first lsblk, so the card shows the device's leaf until its locked row names it.
    function openForDevice(devicePath, rail) {
        var leaf = String(devicePath || "").split("/").pop()
        openFor(devicePath, leaf, 0, "LUKS", rail)
        root.unnamedDevice = String(devicePath || "")
        root.nameDevice()
    }
    // Only a card still at its first typing state takes the name, so no sentence on screen changes the drive it names.
    function nameDevice() {
        var dlg = loader.item
        if (root.unnamedDevice.length === 0 || !dlg || !dlg.opened || dlg.device !== root.unnamedDevice) {
            root.unnamedDevice = ""
            return
        }
        var row = Unlock.lockedRow(root.sidebar ? root.sidebar.deviceEntries : [], root.unnamedDevice)
        if (!row || dlg.phase !== "typing" || dlg.noteText.length > 0)
            return
        root.unnamedDevice = ""
        dlg.describe(row.label, row.size, row.fstype)
    }

    // After an unlock the locked row is a crypt row in the same place; put the cursor on it,
    // so the unlocked drive stays current. Matched by mountpoint: udisksctl names /dev/dm-N, lsblk /dev/mapper/.
    function followUnlocked(path) {
        root.pendingPath = String(path || "")
        root.landCursor(true)
    }
    // Answers whether the cursor landed; stashes for the next rebuild when asked.
    function landCursor(stash) {
        var rail = root.sidebar
        var want = root.pendingPath
        if (!rail || want.length === 0) {
            root.pendingPath = ""
            return false
        }
        var at = rail.placesEntries.length + rail.networkEntries.length
        for (var i = 0; i < rail.deviceEntries.length; i++) {
            if (String(rail.deviceEntries[i].path || "") === want) {
                root.pendingPath = ""
                rail.cursorIndex = at + i
                return true
            }
        }
        if (stash !== true)
            root.pendingPath = ""
        return false
    }

    // The rail index of the cursor when it sits on this device's own row, else -1: the locked row the unlock was asked on.
    function cursorOnRow(device) {
        var rail = root.sidebar
        if (!rail || rail.cursorIndex < 0)
            return -1
        var row = rail.deviceEntries[rail.cursorIndex - rail.placesEntries.length - rail.networkEntries.length]
        return row && String(row.device || "") === device ? rail.cursorIndex : -1
    }

    // A rebuilt rail ends the follow when the cursor moved off the locked row, and lands it otherwise.
    function settleFollow() {
        if (root.pendingPath.length === 0)
            return
        var rail = root.sidebar
        if (!rail || (rail.cursorIndex !== -1 && rail.cursorIndex !== root.lockedCursor)) {
            root.pendingPath = ""
            return
        }
        root.landCursor(false)
    }

    Loader {
        id: loader
        anchors.fill: parent
        z: 2
        active: false
        source: "UnlockDialog.qml"
        onLoaded: {
            item.closed.connect(root.onDialogClosed)
            item.unlocked.connect(root.onDialogUnlocked)
            item.lockFailed.connect(root.onDialogLockFailed)
        }
    }
    Connections {
        target: root.sidebar
        function onEntriesChanged() { root.settleFollow(); root.nameDevice() }
    }
    function onDialogClosed() {
        if (root.window)
            root.window.currentPane.forceActiveFocus()
    }
    // A dialog that ended without a volume could not put the container back; the drive is named.
    function onDialogLockFailed(note) {
        if (root.footer)
            root.footer.say(note, true)
    }
    // The rail's own open, so a rail Enter's focus claim lands in the folder as any mount-first open does (RailKeys.landed).
    function onDialogUnlocked(path, label, note) {
        if (!root.window || !root.sidebar)
            return
        root.sidebar.opened(path)
        // The unlocked row and its eject mark land now, not at the rail's next five second poll.
        root.sidebar.pollDevices()
        root.followUnlocked(path)
        if (root.footer)
            root.footer.say(note, false)
    }
}
