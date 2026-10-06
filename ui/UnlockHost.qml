import QtQuick
import Quickshell

// Unlock (U039): the encrypted-drive dialog's host, over the whole window.
// Created once per window on first use, so no placeholder object stands before it; the unlocked-drive follow lives here.
Item {
    id: root
    anchors.fill: parent
    property var window: null
    property var footer: null
    property var sidebar: null
    property string pendingDevice: ""
    property int lockedCursor: -1
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
    // flea --unlock names a device with no rail row behind it, so the label
    // is the device's own leaf and the size stays unknown until lsblk says so.
    function openForDevice(devicePath, rail) {
        var leaf = String(devicePath || "").split("/").pop()
        openFor(devicePath, leaf, 0, "LUKS", rail)
    }

    // After an unlock the locked row is a crypt row in the same place; put
    // the cursor on it, so the unlocked drive stays current.
    function followUnlocked(mapped) {
        root.pendingDevice = String(mapped || "")
        root.landCursor(true)
    }
    // Answers whether the cursor landed; stashes for the next rebuild when asked.
    function landCursor(stash) {
        var rail = root.sidebar
        var want = root.pendingDevice
        if (!rail || want.length === 0) {
            root.pendingDevice = ""
            return false
        }
        var at = rail.placesEntries.length + rail.networkEntries.length
        for (var i = 0; i < rail.deviceEntries.length; i++) {
            if (String(rail.deviceEntries[i].device || "") === want) {
                root.pendingDevice = ""
                rail.cursorIndex = at + i
                return true
            }
        }
        if (stash !== true)
            root.pendingDevice = ""
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
        if (root.pendingDevice.length === 0)
            return
        var rail = root.sidebar
        if (!rail || (rail.cursorIndex !== -1 && rail.cursorIndex !== root.lockedCursor)) {
            root.pendingDevice = ""
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
        function onEntriesChanged() { root.settleFollow() }
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
    function onDialogUnlocked(path, label, mapped, note) {
        if (!root.window || !root.sidebar)
            return
        root.sidebar.opened(path)
        root.followUnlocked(mapped)
        if (root.footer)
            root.footer.say(note, false)
    }
}
