//@ pragma ShellId flea-reveal-test
import QtQuick
import Quickshell
import "flea" as Flea
import "flea/js/Motion.js" as Motion
import "qml-probe.js" as QmlProbe

// tests/reveal.sh's harness: the real dialog, share browser and context menu fade in and out on the one shared curve, snap under reduced motion, and never move their card while they fade out.
ShellRoot {
    id: shell

    property int checks: 0
    property var failures: []
    property bool done: false
    property int step: 0
    property double stepStart: 0
    property double watchStart: 0
    property bool acted: false
    property var samples: []
    property var script: []
    property var carry: ({})
    // A step's samples run this long past its action, enough for a fade of either length to finish and a frame or two over.
    readonly property int watchMs: 360
    // OutCubic is at 7/8 of its way by half its time; a sample near half a duration must be past this share, or inside its complement for a fade-out.
    readonly property real halfwayShare: 0.75
    // A fade reads as settled at this distance from its end opacity.
    readonly property real settledGap: 0.002
    // Timing windows on the driver clock, as shares of the shared duration; a fade reads as settled near seven eighths of its time, and offscreen frames are not vsync.
    readonly property real earliestShare: 0.8
    readonly property real latestShare: 1.1
    // One pixel of rounding between two reads of the same card rectangle.
    readonly property int roundingSlack: 1

    function log(line) { QmlProbe.log("REVEAL", line) }
    function quit() { Quickshell.execDetached(["kill", String(Quickshell.processId)]) }
    function check(name, actual, expected) { QmlProbe.checkQuiet(shell, name, actual, expected) }

    function report() {
        QmlProbe.reportCard(shell, ticker)
        shell.quit()
    }

    FloatingWindow {
        implicitWidth: 900
        implicitHeight: 600
        color: "#303030"
        Item {
            id: host
            anchors.fill: parent
            Item {
                id: bare
                x: 20; y: 20; width: 100; height: 60
                opacity: 0
                Item { id: bareCard; width: 100; height: 60 }
                Flea.Reveal { id: bareReveal; target: bare; shown: false; lift: bareCard }
            }
            Flea.TrashConfirm { id: trash }
            Flea.ShareBrowser { id: shares }
            Flea.ContextMenu { id: menu }
        }
    }

    function rectOf(item) {
        var p = item.mapToItem(null, 0, 0)
        return [Math.round(p.x), Math.round(p.y), Math.round(item.width), Math.round(item.height)]
    }

    // One surface: how it opens and closes, the item whose opacity fades, the item whose visibility and input the fade holds, and the card that must keep still.
    function surfaces() {
        return [
            { name: "bare reveal", open: function () { bareReveal.shown = true }, close: function () { bareReveal.shown = false },
              fader: bare, host: null, gate: null, card: bareCard },
            { name: "dialog", open: function () { trash.open({ token: 1, all: true, count: 3, bytes: 4096 }) }, close: function () { trash.close() },
              fader: trash, host: trash, gate: trash, card: trash.cardItem },
            { name: "share browser", open: function () { shares.open("smb://host/", "host", ["alpha", "beta"]) }, close: function () { shares.close() },
              fader: shares.children[0], host: shares, gate: shares.children[0], card: shares.children[0] },
            { name: "context menu", open: function () { menu.openAt(Qt.point(100, 40)) }, close: function () { menu.close() },
              fader: menu.frameItem, host: menu, gate: menu, card: menu.frameItem }
        ]
    }

    function snap(s, t) {
        return { t: t, op: s.fader.opacity, vis: s.host === null ? true : s.host.visible, en: s.gate === null ? false : s.gate.enabled, rect: shell.rectOf(s.card) }
    }

    // The first sample at or past a time, or the last one.
    function nearest(samples, ms) {
        for (var i = 0; i < samples.length; i++) if (samples[i].t >= ms) return samples[i]
        return samples[samples.length - 1]
    }
    // The first sample whose opacity is past a bound in a direction, as its time, else -1.
    function settledAt(samples, target) {
        for (var i = 0; i < samples.length; i++) if (Math.abs(samples[i].op - target) <= shell.settledGap) return samples[i].t
        return -1
    }
    function monotonic(samples, up) {
        for (var i = 1; i < samples.length; i++) {
            if (up && samples[i].op < samples[i - 1].op - 1e-6) return false
            if (!up && samples[i].op > samples[i - 1].op + 1e-6) return false
        }
        return true
    }
    function sameRect(a, b) {
        for (var i = 0; i < 4; i++) if (Math.abs(a[i] - b[i]) > shell.roundingSlack) return false
        return true
    }
    function stillCard(samples, resting) {
        return samples.every(function (p) { return shell.sameRect(p.rect, resting) })
    }

    function buildScript() {
        var out = []
        shell.surfaces().forEach(function (s, index) {
            var tag = s.name
            function surface() { return shell.surfaces()[index] }
            out.push({ name: tag + ": open", act: function () { Flea.Theme.reducedMotion = false; surface().open() }, record: function (samples) {
                var want = Motion.durMs.open
                var settled = shell.settledAt(samples, 1)
                shell.check(tag + ": opening reaches full opacity", settled >= 0, true)
                shell.check(tag + ": opening takes the shared open time on the driver clock", settled >= want * shell.earliestShare && settled <= want * shell.latestShare, true)
                shell.check(tag + ": opening only ever gains opacity", shell.monotonic(samples, true), true)
                shell.check(tag + ": opening is OutCubic, mostly there by half its time", shell.nearest(samples, want / 2).op >= shell.halfwayShare, true)
                shell.check(tag + ": the surface is drawn the whole open", samples.every(function (p) { return p.vis || p.op === 0 }), true)
                var last = samples[samples.length - 1]
                shell.carry[tag] = last.rect
                if (s.host !== null) shell.check(tag + ": the open surface takes input", last.en, true)
                shell.check(tag + ": the card rests where it is laid", shell.sameRect(last.rect, shell.rectOf(surface().card)), true)
            } })
            out.push({ name: tag + ": close", act: function () { surface().close() }, record: function (samples) {
                var want = Motion.durMs.close
                var settled = shell.settledAt(samples, 0)
                shell.check(tag + ": closing reaches no opacity", settled >= 0, true)
                shell.check(tag + ": closing takes the shared close time on the driver clock", settled >= want * shell.earliestShare && settled <= want * shell.latestShare, true)
                shell.check(tag + ": closing only ever loses opacity", shell.monotonic(samples, false), true)
                shell.check(tag + ": closing is OutCubic, mostly gone by half its time", shell.nearest(samples, want / 2).op <= 1 - shell.halfwayShare, true)
                shell.check(tag + ": the card never moves while it fades out", shell.stillCard(samples, shell.carry[tag]), true)
                var last = samples[samples.length - 1]
                if (s.host !== null) {
                    shell.check(tag + ": a closed surface is hidden", last.vis, false)
                    shell.check(tag + ": the fading surface takes no input", samples.every(function (p) { return !p.en }), true)
                    shell.check(tag + ": it stays drawn until its fade ends", samples.every(function (p) { return p.vis || p.op < shell.settledGap }), true)
                }
            } })
            out.push({ name: tag + ": reopen", watch: 0, act: function () { surface().open() }, record: function () {} })
            out.push({ name: tag + ": settle", act: function () {}, record: function () {} })
            out.push({ name: tag + ": reopen mid close", watch: 60, act: function () { surface().close() }, record: function (samples) {
                shell.carry.mid = samples[samples.length - 1].op
                surface().open()
            } })
            out.push({ name: tag + ": reopened", act: function () {}, record: function (samples) {
                shell.check(tag + ": a reopen fades up from where the close stood", samples[0].op >= shell.carry.mid - 0.15, true)
                shell.check(tag + ": a reopen in a close does not replay the rise", shell.stillCard(samples, shell.carry[tag]), true)
                shell.check(tag + ": the reopened surface is full", samples[samples.length - 1].op, 1)
            } })
            out.push({ name: tag + ": reduced", watch: 0, act: function () {
                Flea.Theme.reducedMotion = true
                surface().close()
                var closed = shell.snap(surface(), 0)
                shell.check(tag + ": under reduced motion a close is instant", closed.op, 0)
                if (s.host !== null) shell.check(tag + ": and the surface is gone at once", closed.vis, false)
                surface().open()
                var opened = shell.snap(surface(), 0)
                shell.check(tag + ": under reduced motion an open is instant", opened.op, 1)
                shell.check(tag + ": and the card sits at rest at once", shell.sameRect(opened.rect, shell.carry[tag]), true)
                surface().close()
                Flea.Theme.reducedMotion = false
            }, record: function () {} })
            out.push({ name: tag + ": closed", watch: 160, act: function () {}, record: function (samples) {
                shell.check(tag + ": the reduced-motion close left it closed", samples[samples.length - 1].op, 0)
            } })
        })
        shell.script = out
    }

    Timer {
        id: starter
        interval: 400
        running: true
        onTriggered: { shell.buildScript(); shell.stepStart = Date.now(); ticker.running = true }
    }

    // One frame at a time: a step acts, then samples every frame for its watch time, then records.
    FrameAnimation {
        id: ticker
        running: false
        onTriggered: {
            if (shell.done) return
            if (shell.step >= shell.script.length) { shell.report(); return }
            var current = shell.script[shell.step]
            var s = shell.surfaces()[Math.floor(shell.step / 8)]
            var watch = current.watch !== undefined ? current.watch : shell.watchMs
            if (!shell.acted) {
                shell.acted = true
                shell.samples = []
                shell.watchStart = Date.now()
                current.act()
            }
            var elapsed = Date.now() - shell.watchStart
            if (watch > 0) shell.samples.push(shell.snap(s, elapsed))
            if (elapsed >= watch) {
                if (watch === 0) shell.samples.push(shell.snap(s, 0))
                current.record(shell.samples)
                shell.acted = false
                shell.step += 1
            }
        }
    }
}
