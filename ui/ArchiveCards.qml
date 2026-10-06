import QtQuick
import "." as Flea
import "js/ArchiveOps.js" as ArchiveOps

// The two password cards, built by their first open and kept like every overlay: a launch that
// never opens one pays neither its compile nor its objects. Each Loader carries the members its
// callers read, and ui/Ipc.qml reads the built item or null.
Item {
    id: root

    property var compressOwner: null
    property var extractOwner: null
    property var compressPwSource: null

    function askCompressPw(pane, paths, menuId) {
        if (paths) ArchiveOps.compressPwResolved(root, pane, paths, menuId)
        else ArchiveOps.openCompressPw(pane, menuId, root)
    }

    function openCompressDialog(source, parentLeaf, holder) {
        compressOwner = holder
        compressDialog.active = true
        compressDialog.item.open(source.paths, parentLeaf, holder)
    }

    function openExtractPw(leaf, holder, err) {
        extractOwner = holder
        extractDialog.active = true
        extractDialog.item.open(leaf, holder, err)
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
        function onAccepted(password) { ArchiveOps.submitExtractPw(root.extractOwner, password) }
    }
}
