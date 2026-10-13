import QtQuick
import "js/Columns.js" as Columns
import "js/Swap.js" as Swap

// A changing ancestor keeps its own slot's last rows until the replacement or the listing swap's cap.
Item {
    id: root
    property var area: null
    property string target: ""
    property var held: ({})
    property int version: 0
    property bool expired: false
    property bool minimum: false

    function begin(carry, asks) {
        cap.stop(); minShow.stop()
        var next = {}, old = Columns.neighbourAsks(root.area.pane.path, root.area.width, root.area.columnsLimit)
        if (carry) {
            for (var i = 1; i <= asks.length; i++) {
                var path = asks[asks.length - i], from = old[old.length - i]
                var key = root.area.peekKey(path)
                var ready = root.area.peeked[key] !== undefined && root.area.peekOrders[key] === root.area.orderOf(path)
                if (ready || path === carry.seed && carry.rows !== null || !from) continue
                next[path] = { rows: root.area.rowsFor(from), mode: root.area.deniedMode(from), ready: false }
            }
        }
        root.target = carry ? carry.target : ""
        root.held = next
        root.expired = false
        root.minimum = false
        root.version++
        if (Object.keys(next).length) cap.start()
    }
    function waiting(path) { return root.version >= 0 && root.area.pane.path === root.target && root.held[path] !== undefined }
    function loading(path) { return root.waiting(path) && root.expired }
    function rows(path, ordinary) {
        if (!root.waiting(path)) return ordinary
        return root.expired ? [] : root.held[path].rows
    }
    function mode(path, ordinary) { return root.waiting(path) ? root.expired ? -1 : root.held[path].mode : ordinary }

    function remove(path) {
        var next = Object.assign({}, root.held)
        delete next[path]
        root.held = next
        root.version++
        if (!Object.keys(next).length) { cap.stop(); minShow.stop(); root.minimum = false }
    }
    function answered(path) {
        if (root.held[path] === undefined) return
        if (root.expired && root.minimum) {
            var next = Object.assign({}, root.held)
            next[path] = Object.assign({}, next[path], { ready: true })
            root.held = next
            root.version++
        } else root.remove(path)
    }
    // Start the minimum from the landing that actually reveals the capped ancestor, not from time spent behind the old listing.
    function landed() {
        if (root.expired && Object.keys(root.held).length && !root.minimum) root.showMark()
    }
    function showMark() { root.minimum = true; minShow.start() }
    function expire() {
        root.expired = true
        root.version++
        if (root.area.pane.path === root.target) root.showMark()
    }
    function releaseMinimum() {
        root.minimum = false
        var paths = Object.keys(root.held)
        for (var path of paths) if (root.held[path].ready) root.remove(path)
    }
    Timer { id: cap; interval: Swap.CAP_MS; onTriggered: root.expire() }
    Timer { id: minShow; interval: Swap.MIN_SHOW_MS; onTriggered: root.releaseMinimum() }
}
