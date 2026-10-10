import QtQuick
import "js/Archive.js" as Archive
import "js/ArchiveOps.js" as ArchiveOps

// The two password cards, built on their first open and kept like every overlay, so a launch that never opens one pays nothing.
Item {
    id: root

    property var compressOwner: null
    property var extractOwner: null
    readonly property var compressItem: compressDialog.item
    readonly property var extractItem: extractDialog.item

    function askCompressPw(pane, paths, menuId) {
        if (paths) ArchiveOps.compressPwResolved(root, pane, paths, menuId)
        else ArchiveOps.openCompressPw(pane, menuId, root)
    }

    // One card at a time: a second request is answered with a sentence and never dropped silently.
    function cardBusy(holder, verb) {
        if (!compressDialog.opened && !extractDialog.opened)
            return false
        holder.message(Archive.cardBusySentence(verb), true)
        return true
    }

    function openCompressDialog(source, parentLeaf, holder) {
        if (cardBusy(holder, "compress")) return
        compressOwner = holder
        compressDialog.active = true
        compressDialog.item.open(source, parentLeaf, holder)
    }

    function openExtractPw(source, holder, err) {
        if (cardBusy(holder, "extract this archive")) {
            if (extractDialog.item) extractDialog.item.forget()
            return
        }
        extractOwner = holder
        extractDialog.active = true
        extractDialog.item.open(source, holder, err)
    }

    anchors.fill: parent

    Loader {
        id: compressDialog
        anchors.fill: parent
        active: false
        source: "ArchiveCompressDialog.qml"
        readonly property bool opened: item !== null && item.opened
    }
    Connections {
        target: compressDialog.item
        function onAccepted(source, format, name, password, encryptNames) {
            ArchiveOps.submitCompressPw(root.compressOwner, source, format, name, password, encryptNames)
        }
    }

    Loader {
        id: extractDialog
        anchors.fill: parent
        active: false
        source: "ArchivePasswordDialog.qml"
        readonly property bool opened: item !== null && item.opened
    }
    Connections {
        target: extractDialog.item
        function onAccepted(source, password) { ArchiveOps.submitExtractPw(root.extractOwner, source, password) }
    }
    // Every archive answer reaches the card, so a secret kept for a wrong-password re-ask dies with any other answer.
    Connections {
        target: extractDialog.item && root.extractOwner ? root.extractOwner.backend : null
        function onArchiveDone(id, ok, verified, err, path, dest) { extractDialog.item.answered(err, path, dest) }
        // A backend that stops before it answers never will, so the kept secret goes with it.
        function onRunningChanged() { if (!root.extractOwner.backend.running) extractDialog.item.forget() }
    }
}
