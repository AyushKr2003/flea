import QtQuick
import "." as Flea
import "js/Focus.js" as Focus
import "js/Eject.js" as Eject
import "js/RailKeys.js" as RailKeys
import "js/RailMenu.js" as RailMenu

// The pane's rail, and the two ways it comes and goes. With Auto-hide sidebar off it is part of the
// pane and Show sidebar governs it, which is 0.2.1's behaviour. Directive 77, GM's own sentence:
// "hovering over the left side should show it, like every other autohide feature in every other file
// manager ever". So with the switch on the rail is withdrawn at every width, the pointer at the
// window's left edge reveals it over the pane rather than reflowing it, and it withdraws a moment
// after the pointer or the keyboard leaves.
Item {
    id: root

    property var pane: null
    // The window-long network host ui/WindowBody.qml builds lazily on the first open, handed to
    // the rail below: the rail Loader unloads the Sidebar when the rail hides, but this service
    // and these connections outlive it, so a mount, a bridge wait or a dialog answer that lands
    // afterwards still opens, messages and clears its sticky line.
    property var service: null
    readonly property bool overlay: ViewState.railAutoHide
    readonly property bool hidden: root.overlay ? !root.revealed : ViewState.railHidden
    // An overlay owes the pane no width, so the listing never reflows as the rail comes and goes.
    // This item is that width, and the rail itself draws past it.
    readonly property real inset: root.overlay ? 0 : rail.width
    readonly property real railWidth: rail.active ? rail.width : 0
    readonly property var item: root.held ? null : rail.item

    function focusPress(p) {
        var pane = root.pane
        if (p.x < 0 || p.y < 0 || p.x >= pane.width || p.y >= pane.height) return
        // The shown Sidebar can extend past its zero-width overlay host.
        var sidebar = root.item
        var r = sidebar ? sidebar.mapFromItem(pane, p.x, p.y) : null
        if (!root.hidden && r && r.x >= 0 && r.y >= 0 && r.x < sidebar.width && r.y < sidebar.height) {
            if (root.overlay) pane.railPane.focusView = Focus.RAIL
        } else { pane.focusView = Focus.LIST; pane.focusRequested() }
    }

    // Long enough that crossing the edge on the way somewhere else does not flash the rail, and that
    // leaving it by a pixel on the way to a row does not drop it.
    readonly property int settleMs: 220
    property bool revealed: false
    // The rail's own context menu takes the pointer with it, so without this the rail withdraws out
    // from under the menu it just opened.
    readonly property bool menuHere: root.pane !== null && root.pane.contextMenu().opened
                                     && root.pane.contextMenu().forRail
    // The rail stays up while the pointer is on it, which is the other half of the reveal.
    readonly property bool over: railHover.hovered
    // A release in flight keeps a revealed overlay rail up; the hold below is what keeps the Sidebar when it hides anyway.
    readonly property bool releasing: rail.item !== null && (rail.item as Flea.Sidebar).releasing === true
    // A hide mid-release unloads the Sidebar's DeviceMounts and kills its gio, so the Sidebar outlives the hide, undrawn,
    // until the release ends. Latched from the release's own edges and never derived from hidden: the unload it prevents
    // is what hidden drives, so a binding through it would loop.
    property bool releaseHold: false
    readonly property bool held: root.releaseHold && root.hidden
    function holdRelease(on) {
        if (on) { root.releaseHold = true; return }
        // Past the signal that ended it, where the unload the hold was keeping would destroy the sender mid-emission.
        Qt.callLater(function () { if (!root.releasing) root.releaseHold = false })
    }
    readonly property bool wanted: edge.hovered || root.over || root.menuHere || root.releasing
                                   || (root.pane !== null && root.pane.focusView === Focus.RAIL)

    onWantedChanged: {
        if (root.wanted) { settle.stop(); root.revealed = true }
        else settle.restart()
    }
    // The switch itself is a fresh start either way: nothing is revealed until the pointer asks.
    onOverlayChanged: root.revealed = false

    anchors { top: parent.top; bottom: parent.bottom }
    width: root.inset

    Timer {
        id: settle
        interval: root.settleMs
        onTriggered: root.revealed = false
    }

    // The strip that answers the pointer, at the window's own left edge and only while the switch is
    // on. It holds no MouseArea, so a click on the listing under it still lands on the listing.
    Item {
        id: strip
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: Theme.space(4)
        enabled: root.overlay
        HoverHandler { id: edge; enabled: root.overlay }
    }

    Loader {
        id: rail
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: item && !root.held ? item.implicitWidth : 0
        visible: !root.held
        active: root.pane !== null && !root.pane.listOnly && root.pane.sharedSidebar === null && (!root.hidden || root.releaseHold)
        // A Sidebar that went for another reason took its release with it, so there is nothing left to hold.
        onItemChanged: if (item === null) root.releaseHold = false
        sourceComponent: Flea.Sidebar {
            id: sidebar
            backend: root.pane.backend
            navigationPane: root.pane.railPane
            service: root.service
            focused: root.pane.railPane.focusView === Focus.RAIL
            trashActive: root.pane.railPane.trash.opened
            onOpened: function(path) { RailKeys.openFrom(root.pane.railPane, path, sidebar) }
            // Sidebar040: the rail's Recent row answers with the history's own paths, which the
            // pane lists with listpaths; focus follows into the folder the way a mount's open does.
            onRecentRequested: function (paths, requester, visits) { var target = requester || root.pane.railPane; target.openRecent(paths, visits); RailKeys.landed(target, sidebar) }
            onTrashRequested: root.pane.railPane.trash.open()
            onMessage: function(text, isError) { RailKeys.messaged(sidebar, isError); root.pane.message(text, isError) }
            onForgetMessage: function(text) { root.pane.forgetMessage(text) }
            menu: root.pane.railPane.contextMenu()
            onRenameFinished: root.pane.railPane.listArea.forceActiveFocus()
            // The pane's own PointHandler never sees a press a row grabs, so an overlay rail claims the keyboard itself; a docked rail leaves it.
            onPressed: if (root.overlay) root.pane.railPane.focusView = Focus.RAIL
            onReleasingChanged: root.holdRelease(sidebar.releasing)
        }
        // Disabled with the Sidebar, so an unload under the pointer clears it; a handler inside the Sidebar dies without reporting.
        HoverHandler { id: railHover; enabled: rail.active && !root.held }
    }

    // The rail's Sidebar renders the window-long service below; the service's answers
    // route once by origin in ui/WindowBody.qml, so this file carries no Connections of its
    // own and a dual-view open cannot fire twice.

    // Ctrl+E from a listing with the rail hidden. The rail Loader above unloads the Sidebar with
    // its DeviceMounts poll, eject verdict state and releaseChosen, so the key has nothing to read
    // and nothing to release through. It spins this transient instead: the same DeviceMounts
    // component the rail uses, never a second poller, alive only for this flow. Its first listing
    // resolves the holding volume through the same Mounts.holding and Mounts.railMenu verdict and
    // releases through the same RailMenu.release and devices.eject path with the same messages;
    // the verdict lands, the host unloads, and while nothing is pressed nothing here exists.
    property bool hiddenEjectArmed: false
    function unloadHiddenEject() {
        // Past the signal that asked for it, where a synchronous unload would destroy the sender
        // mid-emission. A release still in flight keeps it: the Loader's end would kill its gio.
        Qt.callLater(function () {
            if (!hiddenEject.item || !hiddenEject.item.releasing)
                hiddenEject.active = false
        })
    }
    function ejectHidden() {
        if (!root.pane)
            return
        if (!hiddenEject.active) {
            hiddenEjectArmed = true
            hiddenEject.active = true
            return
        }
        // A flow is already waiting on its first listing, or an eject is running: re-resolve
        // against the freshest entries, where the service refuses a concurrent eject itself.
        hiddenEjectArmed = true
        if (hiddenEject.item && hiddenEject.item.firstAnswered)
            root.hiddenEjectReady()
    }
    function hiddenEjectReady() {
        var device = hiddenEject.item
        if (!device || !hiddenEjectArmed)
            return
        hiddenEjectArmed = false
        // The adapter is the Sidebar's shape and nothing more: entries to resolve against and
        // releaseChosen to release through, so this lands in Eject.release beside the rail's own.
        // Only a volume holds a listing's path: shares and phones carry none and favourites offer no
        // release, and the system-volume answer is the pane's own, not read from any row here.
        var adapter = { entries: device.entries, deviceEntries: device.entries, networkEntries: [] }
        adapter.releaseChosen = function (action, key) { RailMenu.release(action, key, device, null, adapter) }
        Eject.release(root.pane, adapter, false)
        root.unloadHiddenEject()
    }
    Loader {
        id: hiddenEject
        active: false
        sourceComponent: Flea.DeviceMounts {
            showUnmounted: ((ViewState.state.places || {}).showUnmounted !== false)
            onOpened: function (path) { root.pane.open(path) }
            onMessage: function (text, isError) { root.pane.message(text, isError) }
            onReleasingChanged: root.unloadHiddenEject()
            onForgetMessage: function (text) { root.pane.forgetMessage(text) }
            onQuiesce: function (path) { root.pane.quiesceVolume(path) }
            onFirstAnsweredChanged: root.hiddenEjectReady()
        }
    }
}
