import QtQuick
import "." as Flea

// Quick Look uses the same bar as Markdown; the column loads only the document body.
Item {
    id: root
    property bool active: false
    property string path: ""
    property int size: 0
    property string view: "rendered"
    property int maxBytes: 1048576
    property bool truncate: false
    property string blockPath: ""
    property var backend: null
    property bool wrap: false
    property bool closeFocused: false
    signal closeRequested
    signal viewRequested(string view)
    readonly property var bodyItem: doc.bodyItem
    readonly property var document: doc
    readonly property string rawText: doc.sourceCode ? doc.sourceCode.lines.join("\n") : ""
    readonly property string status: doc.status
    readonly property string lineLabel: doc.lineLabel
    readonly property string shownView: doc.shownView
    readonly property bool contentReady: doc.contentReady
    readonly property bool firstScreen: doc.firstScreen
    readonly property real scrollY: doc.scrollY
    function endGap() { return doc.endGap() }
    function closeState() { return bar.closeState() }
    function barGeometry() { var g = bar.geometry(); g.ready = root.contentReady; return g }
    function scrollBy(rows) { doc.scrollBy(rows) }
    function zoomBy(steps) { doc.zoomBy(steps) }
    function zoomFit() { doc.zoomFit() }
    function tableScroller() { return null }

    Flea.QuickLookBar {
        id: bar
        anchors { top: parent.top; left: parent.left; right: parent.right }
        markName: "html"
        name: root.path.substring(root.path.lastIndexOf("/") + 1)
        countLabel: root.contentReady ? root.lineLabel : ""
        views: true
        view: root.shownView
        closeFocused: root.closeFocused
        onCloseRequested: root.closeRequested()
        onViewRequested: function (which) { root.viewRequested(which) }
    }
    Flea.PreviewHtml {
        id: doc
        anchors.fill: parent
        anchors.topMargin: bar.height
        active: root.active
        path: root.path
        size: root.size
        view: root.view
        maxBytes: root.maxBytes
        truncate: root.truncate
        backend: root.backend
        slot: "look"
        wrap: root.wrap
    }
}
