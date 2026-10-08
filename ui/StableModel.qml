import QtQuick
import QtQml.Models

// A view's row count as a model that never changes identity, so a new count keeps the delegates that stay drawn.
DelegateModel {
    id: root

    required property Item view
    property int total: 0
    // The compositor is filled in componentComplete, so a group change before onCompleted is silently dropped.
    property bool ready: false

    // A move asked for inside the change's own layout is dropped, so a view that places itself does it here.
    signal resized()

    // Qt refuses an integer model larger than 100,000,000 rows.
    readonly property int cap: 100000000
    model: root.cap
    groups: DelegateModelGroup { id: shown; name: "shown"; includeByDefault: false }
    filterOnGroup: "shown"

    onTotalChanged: root.resize()
    Component.onCompleted: { root.ready = true; root.resize() }

    // Moves to the top and row 0 as a reset does, before the change, so only top rows lay out and a view placing itself after keeps its place.
    function resize() {
        var to = Math.min(Math.max(root.total, 0), root.cap)
        var from = shown.count
        if (!root.ready || to === from)
            return
        root.view.contentY = root.view.originY - root.view.topMargin
        if (from > 0 && to > 0)
            root.view.currentIndex = 0
        if (to > from)
            root.items.addGroups(from, to - from, "shown")
        else
            shown.removeGroups(to, from - to, "shown")
        root.view.forceLayout()
        if (to > 0 && root.view.currentIndex < 0)
            root.view.currentIndex = 0
        root.resized()
        // An empty view holds no delegates, pooled ones included, so a view hidden after it emptied holds none either.
        if (to === 0) {
            root.view.reuseItems = false
            root.view.reuseItems = true
        }
    }
}
