//@ pragma ShellId flea-cohesion-capture-reader-test
import QtQuick
import Quickshell
import QtTest
import "flea" as Flea

// Real controls exercise the capture-only reader, including geometry while pressed and an item outside its clipping parent.
ShellRoot {
    id: root
    property int stage: 0
    property int ticks: 0
    property int checks: 0
    property var failures: []
    property var rest: null
    property var reader: null

    function check(cond, label) {
        root.checks++
        if (!cond) { root.failures.push(label); console.log("COHCAPTURE FAIL " + label) }
    }
    function read() {
        return JSON.parse(root.reader.read(window, window.contentItem, /^(DialogButton|SettingsRow)_QML/, {}))
    }
    function control(state, name) { return state.controls.find(function(c) { return c.name === name }) }
    function report() {
        timer.running = false
        console.log("COHCAPTURE DONE checks=" + root.checks + " failed=" + root.failures.length)
        Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }
    Component.onCompleted: root.reader = Qt.createComponent("flea/IpcControls.qml").createObject(root)

    FloatingWindow {
        id: window
        implicitWidth: 500
        implicitHeight: 400
        Item {
            id: stage
            anchors.fill: parent
            Flea.DialogButton { id: button; x: 100; y: 100; width: 100; height: 30; label: "Press" }
            Item {
                x: 100; y: 160; width: 40; height: 30; clip: true
                Flea.DialogButton { x: 50; width: 80; height: 30; label: "Clipped" }
            }
            Flea.MediaStrip { id: media; x: 10; y: 220; width: 480 }
            Flea.MenuRow { x: 100; y: 280; width: 100; entry: ({label: "Images", action: "1"}); current: true }
            Flea.SettingsRow { x: 100; y: 330; width: 200; row: ({kind: "hint", label: "Information"}) }
        }
        TestEvent { id: driver }
    }
    Timer {
        id: timer
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            root.ticks++
            if (root.ticks > 100) { root.check(false, "the capture reader did not finish"); root.report(); return }
            if (!root.reader || window.width !== 500) return
            if (root.stage === 0) {
                var state = root.read()
                root.rest = root.control(state, "Press")
                root.check(!!root.rest && root.rest.exposed && root.rest.pressLive, "the button exposes a real press target")
                root.check(root.control(state, "Clipped").exposed === false, "a centre outside its clipping parent is not a pointer target")
                var play = root.control(state, "Play")
                root.check(!!play && play.exposed && !play.hoverable && play.pressLive, "media play reports its real TapHandler and absence of a hover effect")
                var choice = root.control(state, "Images")
                root.check(!!choice && choice.value === "1" && choice.focused, "the filter menu row reports its caption, action and cursor")
                var hint = state.controls.find(function(c) { return c.kind === "SettingsRow" })
                root.check(!!hint && !hint.hoverLive && !hint.pressLive, "an informational settings row has no live hover or press target")
                driver.mousePress(stage, root.rest.targetX, root.rest.targetY, Qt.LeftButton, Qt.NoModifier, 0)
                root.stage = 1
                return
            }
            if (root.stage === 1) {
                var held = root.control(root.read(), "Press")
                root.check(held.pressed, "a held press is read from the actual button")
                root.check(held.x !== root.rest.x || held.y !== root.rest.y, "press scaling invalidates the old coordinate signature")
                root.check(held.x <= root.rest.targetX && root.rest.targetX < held.x + held.w
                    && held.y <= root.rest.targetY && root.rest.targetY < held.y + held.h, "the original hit point still identifies the scaled control")
                driver.mouseRelease(stage, root.rest.targetX, root.rest.targetY, Qt.LeftButton, Qt.NoModifier, 0)
                var point = media.playItem.mapToItem(stage, media.playItem.width / 2, media.playItem.height / 2)
                driver.mousePress(stage, point.x, point.y, Qt.LeftButton, Qt.NoModifier, 0)
                root.stage = 2
                return
            }
            var playing = root.control(root.read(), "Play")
            root.check(playing.pressed, "media play reads a real held press")
            driver.mouseRelease(stage, playing.targetX, playing.targetY, Qt.LeftButton, Qt.NoModifier, 0)
            root.report()
        }
    }
}
