//@ pragma ShellId flea-spinner-still-test

import QtQuick
import Quickshell
import qs.Commons
import "flea" as Flea

// tests/spinner-still.sh's harness: the real ui/Spinner.qml rests for its first second on screen, then crawls; a hide resets it.
ShellRoot {
    id: root

    property int checks: 0
    property var failures: []
    property int step: 0
    property real sample: 0

    function check(label, actual, expected) {
        root.checks += 1
        if (actual === expected) {
            console.log("SPINNERSTILL ok " + label)
            return
        }
        root.failures.push(label)
        console.log("SPINNERSTILL FAIL " + label + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected))
    }
    function quit() { Quickshell.execDetached(["kill", String(Quickshell.processId)]) }
    function report() {
        if (root.failures.length === 0)
            console.log("SPINNERSTILL PASS " + root.checks + " checks")
        root.quit()
    }
    // The mark's ShapePath: the Shape is the spinner's only child item, and the path is the Shape's only data entry.
    function offset(spinner) { return spinner.children[0].data[0].dashOffset }

    FloatingWindow {
        implicitWidth: 200
        implicitHeight: 100
        color: Flea.Theme.color.background

        Item {
            id: host
            width: 48
            height: 48
            Flea.Spinner { id: spin; anchors.fill: parent }
        }
        Flea.Spinner { id: own; x: 100; width: 48; height: 48 }
    }

    // Each entry runs once its ms have passed since the last show or hide (the start first), so a late step never moves a window.
    readonly property var plan: [
        [400, function () {
            root.check("still at 400 ms", spin.crawling, false)
            root.check("rest offset at 400 ms", root.offset(spin), 0)
        }],
        [850, function () { root.check("rest offset at 850 ms", root.offset(spin), 0) }],
        [1300, function () {
            root.check("crawling after its first second", spin.crawling, true)
            root.sample = root.offset(spin)
        }],
        [1450, function () {
            root.check("the dash moves once crawling", root.offset(spin) !== root.sample, true)
            host.visible = false
            root.anchor = Date.now()
        }],
        [100, function () {
            root.check("an ancestor's hide stops the crawl", spin.crawling, false)
            root.check("an ancestor's hide resets the dash", root.offset(spin), 0)
        }],
        [1300, function () {
            root.check("no crawl starts while hidden", spin.crawling, false)
            root.check("the dash stays at rest while hidden", root.offset(spin), 0)
            host.visible = true
            root.anchor = Date.now()
        }],
        [500, function () {
            root.check("still again 500 ms after the show", spin.crawling, false)
            root.check("rest offset again 500 ms after the show", root.offset(spin), 0)
        }],
        [1300, function () {
            root.check("crawling again a second after the show", spin.crawling, true)
            root.check("its own mark crawls too", own.crawling, true)
            own.visible = false
            root.anchor = Date.now()
        }],
        [100, function () {
            root.check("its own hide stops the crawl", own.crawling, false)
            root.check("its own hide resets the dash", root.offset(own), 0)
            root.report()
        }]
    ]
    property double anchor: Date.now()

    Timer {
        interval: 20
        repeat: true
        running: true
        onTriggered: {
            if (root.step < root.plan.length && Date.now() - root.anchor >= root.plan[root.step][0]) {
                root.plan[root.step][1]()
                root.step += 1
            }
        }
    }
    Timer {
        interval: 15000
        running: true
        onTriggered: { console.log("SPINNERSTILL FAIL timed out at step " + root.step); root.quit() }
    }
}
