import QtQuick
import QtQuick.Window
import QtWebEngine

// One local page becomes a still image; this unit belongs to the isolated qml6 helper only.
Window {
    id: win
    function arg(name, fallback) {
        var args = Qt.application.arguments
        for (var i = 0; i < args.length; i++)
            if (args[i].indexOf("--" + name + "=") === 0) return args[i].substring(name.length + 3)
        return fallback
    }
    readonly property string pageUrl: "file:///output/input.html"
    readonly property string outPath: "/output/page.png"
    readonly property int pageWidth: parseInt(arg("width", "984"))
    visible: true
    color: "#ffffff"
    width: pageWidth
    height: 600

    WebEngineView {
        id: view
        anchors.fill: parent
        url: win.pageUrl
        profile: WebEngineProfile { offTheRecord: true; httpUserAgent: "Flea-Preview" }
        settings.javascriptEnabled: false
        settings.localContentCanAccessRemoteUrls: false
        settings.localStorageEnabled: false
        settings.autoLoadIconsForPage: false
        settings.pluginsEnabled: false
        settings.webGLEnabled: false
        settings.allowRunningInsecureContent: false
        settings.dnsPrefetchEnabled: false
        settings.hyperlinkAuditingEnabled: false
        settings.focusOnNavigationEnabled: false
        settings.errorPageEnabled: false
        onNavigationRequested: function (request) {
            if (request.url.toString() !== win.pageUrl)
                request.action = WebEngineNavigationRequest.IgnoreRequest
        }
        onLoadingChanged: function (info) {
            if (info.status === WebEngineView.LoadSucceededStatus) settle.start()
            else if (info.status === WebEngineView.LoadFailedStatus) Qt.exit(3)
        }
        onRenderProcessTerminated: Qt.exit(3)
    }
    Timer {
        id: settle
        interval: 30
        onTriggered: {
            win.height = Math.max(1, Math.min(Math.ceil(view.contentsSize.height), 8000))
            grab.start()
        }
    }
    Timer {
        id: grab
        interval: 120
        onTriggered: view.grabToImage(function (result) {
            if (!result.saveToFile(win.outPath)) { Qt.exit(4); return }
            console.warn("HTML_META " + JSON.stringify({ title: view.title }))
            Qt.exit(0)
        })
    }
    Timer { interval: 15000; running: true; onTriggered: Qt.exit(5) }
}
