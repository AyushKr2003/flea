import QtQuick
import Quickshell
import "flea" as Flea

// A hidden page must leave no live texture behind its refusal after a successful render.
ShellRoot {
    id: root
    property int phase: 0
    property int failures: 0
    property bool capturing: false
    readonly property string folder: Quickshell.env("HTML_ROOT")
    function check(name, good) {
        if (!good) root.failures++
        console.warn("HTML_PREVIEW " + (good ? "PASS " : "FAIL ") + name)
    }
    function clipActive() {
        for (var i = 0; i < document.children.length; i++) {
            var child = document.children[i]
            if (String(child.source).endsWith("HtmlClip.qml")) return child.active && !!child.item
        }
        return false
    }
    function reply(state) {
        responder.htmlResult({ slot: document.slot, token: document.token, state: state,
            file: root.folder + "/reload.png", width: document.deviceWidth, total: 1 })
    }
    function shot(name, after) {
        root.capturing = true
        document.grabToImage(function (image) {
            root.check(name + " capture saves", image.saveToFile(Quickshell.env("FLEA_CI_SUITE_LOGS") + "/" + name + ".png"))
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
    FloatingWindow {
        implicitWidth: 300
        implicitHeight: 200
        color: "transparent"
        Flea.PreviewHtml {
            id: document
            anchors.fill: parent
            active: true
            compact: true
            cornerRadius: 12
            path: root.folder + "/clip.html"
            backend: responder
        }
    }
    Timer {
        interval: 100
        running: true
        repeat: true
        onTriggered: {
            if (root.capturing) return
            if (root.phase === 0 && document.token > 0) { root.reply("ready"); root.phase = 1 }
            else if (root.phase === 1 && document.contentReady && root.clipActive()) {
                root.check("RHI clip is live after a ready reply", document.bodyItem.visible)
                root.phase = 2
                root.shot("html-clip-ready", function () { document.ask(); root.reply("failed") })
            } else if (root.phase === 2 && document.failed) {
                root.check("a failed rerender hides the page and unloads its clip", !document.bodyItem.visible && !root.clipActive())
                root.phase = 3
                root.shot("html-clip-failed", function () { document.ask(); root.reply("ready") })
            } else if (root.phase === 3 && document.contentReady && root.clipActive()) {
                document.size = document.maxBytes + 1
                root.phase = 4
            } else if (root.phase === 4 && document.tooLarge) {
                root.check("an over-limit page unloads its clip", !document.bodyItem.visible && !root.clipActive())
                root.phase = 5
                root.shot("html-clip-large", function () {
                    console.warn("HTML_PREVIEW DONE clip, " + root.failures + " failed")
                    Qt.exit(root.failures ? 1 : 0)
                })
            }
        }
    }
    Timer { interval: 10000; running: true; onTriggered: { root.check("clip lifecycle completes", false); Qt.exit(1) } }
}
