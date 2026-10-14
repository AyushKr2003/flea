import QtQuick
import Quickshell
import Quickshell.Io
import "flea" as Flea

ShellRoot {
    id: root
    property int phase: 0
    property int failures: 0
    property bool capturing: false
    readonly property string folder: Quickshell.env("HTML_ROOT")
    readonly property string picturePath: root.folder + "/reload.png"
    readonly property string output: Quickshell.env("FLEA_CI_SUITE_LOGS") || root.folder
    function check(name, good) {
        if (!good) root.failures++
        console.warn("HTML_PREVIEW " + (good ? "PASS " : "FAIL ") + name)
    }
    function reply() {
        responder.htmlResult({slot: document.slot, token: document.token, state: "ready", file: root.picturePath,
            width: document.deviceWidth, total: 1, title: "Reload"})
    }
    function shot(name, after) {
        root.capturing = true
        document.grabToImage(function (image) {
            root.check(name + " capture saved", image.saveToFile(root.output + "/" + name + ".png"))
            root.capturing = false
            after()
        })
    }
    QtObject {
        id: responder
        property int serial: 0
        signal htmlResult(var message)
        function askHtml(slot, path, width, cancel, height) { return ++serial }
    }
    Process {
        id: writer
        command: ["cp", root.folder + "/reload-blue.png", root.picturePath]
        onExited: function (code) {
            root.check("replacement bytes published to the same path", code === 0)
            document.ask()
            root.check("re-ask retains a ready image without a loading mark", !document.loading && document.bodyItem.contentItem.children[0].status === Image.Ready)
            root.shot("html-reload-pending", function () { root.reply(); root.phase = 3 })
        }
    }
    FloatingWindow {
        implicitWidth: 300
        implicitHeight: 200
        visible: true
        color: "transparent"
        Flea.PreviewHtml {
            id: document
            anchors.fill: parent
            active: true
            path: root.folder + "/reload.html"
            backend: responder
        }
    }
    Timer {
        interval: 20
        running: true
        repeat: true
        onTriggered: {
            if (root.capturing) return
            if (root.phase === 0 && document.token > 0) { root.reply(); root.phase = 1 }
            else if (root.phase === 1 && document.contentReady) {
                root.phase = 2
                root.check("native image retains pixels through asynchronous reload", document.bodyItem.contentItem.children[0].retainWhileLoading === true)
                root.shot("html-reload-before", function () { writer.running = true })
            } else if (root.phase === 3 && document.contentReady) {
                root.phase = 4
                root.check("same-path reply is loaded", document.imageFile === root.picturePath)
                root.shot("html-reload-after", function () {
                    console.warn("HTML_PREVIEW DONE reload, " + root.failures + " failed")
                    Qt.exit(root.failures ? 1 : 0)
                })
            }
        }
    }
    Timer {
        interval: 15000
        running: true
        onTriggered: { root.check("same-path reload completes", false); Qt.exit(1) }
    }
}
