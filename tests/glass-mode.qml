//@ pragma ShellId flea-glass-mode-test
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import "flea" as Flea
import "flea/js/Contrast.js" as Contrast

// Omarchy's Window Transparency precedence through Glass, and a Hyprland config reload reaching Style and Glass with no theme switch.
ShellRoot {
    id: root
    readonly property string home: Quickshell.env("HOME")
    readonly property string toggles: Quickshell.env("XDG_STATE_HOME") + "/omarchy/toggles/hypr"
    // "precedence" decides at launch and checks the 8-bit alpha; "reload" then moves the mode and Hyprland's rounding under a running window.
    readonly property string mode: Quickshell.env("GLASSM_MODE")
    readonly property int expect: Number(Quickshell.env("GLASSM_EXPECT"))
    // Set only by a row that proves the glassy-bare path; "-" keeps the shipped default of Glass.glassAlpha.
    readonly property string glass: Quickshell.env("GLASSM_GLASS")
    readonly property string roundingFile: Quickshell.env("GLASSM_ROUNDING")
    property int checks: 0
    property var failures: []
    property var steps: []
    property int stepIndex: 0
    property int stepTicks: 0
    // The stepper ticks every 50 ms, so 200 ticks bound one step to 10 s before it is reported as never completed.
    readonly property int stepTickLimit: 200
    // Style's own startup refresh lands up to this long after the first answer, so nothing is changed before it.
    readonly property int startupSettleMs: 600
    // How long a raw event or a reload gets to reach Style and Glass before a "did not move" check reads them.
    readonly property int eventSettleMs: 600
    // How long the detached rm of the toggle file gets to finish before the mode is read.
    readonly property int toggleRemoveSettleMs: 400

    function check(cond, label) {
        root.checks++
        if (!cond) {
            root.failures.push(label)
            console.log("GLASSM FAIL " + label)
        }
    }
    function eight() { return Math.round(Flea.Glass.alpha * 255) }
    function reload() { Flea.Theme.hyprEvent("configreloaded") }
    function act(fn) { return function () { fn(); return true } }
    function wait(test) { return function () { return test() } }
    function settle(ms) {
        var until = 0
        return function () {
            if (until === 0) until = Date.now() + ms
            if (Date.now() < until) return false
            until = 0
            return true
        }
    }

    function buildSteps() {
        var s = [root.act(function () { Flea.Glass.focused = true; if (root.glass !== "-") Flea.Glass.glassAlpha = Number(root.glass); Flea.Glass.launch() }),
                 root.act(function () {
                     root.check(root.eight() === root.expect, root.mode + " launch alpha " + root.eight() + " is not " + root.expect)
                     root.check(Flea.Glass.on === (root.expect < 255), "on does not follow the alpha " + root.expect)
                     if (!Flea.Glass.usesDefault || Flea.Glass.mode === "opaque") {
                         var c = Flea.Theme.color, opaque = c.opaquePalette
                         root.check(String(c.foreground) === String(opaque.foreground) && String(c.muted) === String(opaque.muted) && String(c.metadata) === String(opaque.metadata), "an override or Opaque lifted the palette's text")
                     }
                 })]
        if (root.mode === "reload") s = s.concat(root.reloadSteps())
        if (root.mode === "socket") s = s.concat(root.socketSteps())
        if (root.mode === "edge") s.push(root.act(root.transparentEdges))
        root.steps = s
    }

    // Near the AA boundary, neither white nor black ink can be lifted further; the ground must protect both focus states.
    function transparentEdges() {
        var inks = ["#ffffff", "#000000"], backdrops = ["#ffffff", "#000000"], focuses = [true, false]
        for (var i = 0; i < inks.length; i++) {
            Flea.Theme.applyColors('background = "#757575"\ndark_background = "#757575"\nforeground = "' + inks[i] + '"\n')
            for (var f = 0; f < focuses.length; f++) {
                Flea.Glass.focused = focuses[f]
                var c = Flea.Theme.color, a = Flea.Glass.alpha
                var roles = [c.foreground, c.muted, c.metadata, c.error, c.errorOnSurface, c.symlink, c.executable]
                var planes = [c.background, c.surface], worst = Infinity
                for (var r = 0; r < roles.length; r++)
                    for (var p = 0; p < planes.length; p++)
                        for (var b = 0; b < backdrops.length; b++)
                            worst = Math.min(worst, Contrast.ratio(String(roles[r]), Contrast.hexOf(Contrast.over(String(planes[p]), a, backdrops[b]))))
                root.check(worst >= Flea.Theme.textContrast, "edge ink=" + inks[i] + " focus=" + focuses[f] + " alpha=" + root.eight() + " ratio=" + worst)
                var nominal = focuses[f] ? 251 : 245
                root.check(root.eight() >= nominal, "edge alpha is thinner than Omarchy's ground")
                var prior = Math.min(Contrast.ratio(inks[i], Contrast.hexOf(Contrast.over(String(c.background), (root.eight() - 1) / 255, backdrops[0]))),
                    Contrast.ratio(inks[i], Contrast.hexOf(Contrast.over(String(c.background), (root.eight() - 1) / 255, backdrops[1]))))
                root.check(root.eight() === nominal || prior < Flea.Theme.textContrast, "edge alpha rose beyond the first legible step")
                console.log("GLASSM EDGE ink=" + inks[i] + " focus=" + focuses[f] + " alpha=" + root.eight() + " ratio=" + worst)
            }
        }
    }
    // The launch was glassy at 191; a reload that finds no toggle goes to Omarchy's default, and one that finds it comes back.
    function reloadSteps() {
        return [
            root.wait(function () { return Commons.Style.cornerRadius === 10 }),
            root.settle(root.startupSettleMs),
            root.act(function () { rounding.setText("0\n"); Flea.Theme.hyprEvent("workspace") }),
            root.settle(root.eventSettleMs),
            root.act(function () { root.check(Commons.Style.cornerRadius === 10, "a workspace event moved the corner radius") }),
            root.act(function () { Quickshell.execDetached(["rm", "-f", root.toggles + "/window-glassy.lua"]) }),
            root.settle(root.toggleRemoveSettleMs),
            root.act(function () { root.check(Flea.Glass.mode === "glassy", "the mode moved before any reload"); root.reload() }),
            root.wait(function () { return Commons.Style.cornerRadius === 0 }),
            root.act(function () {
                root.check(Flea.Glass.mode === "transparent", "a reload without the toggle left mode " + Flea.Glass.mode)
                root.check(root.eight() === 251, "focused transparent without a theme value drew " + root.eight())
                opaque.setText("return\n")
            }),
            root.act(function () { root.reload() }),
            root.wait(function () { return Flea.Glass.mode === "opaque" }),
            root.act(function () { root.check(root.eight() === 255, "opaque drew " + root.eight()); glassy.setText("return -- written again\n") }),
            root.act(function () { root.reload() }),
            root.wait(function () { return Flea.Glass.mode === "glassy" }),
            root.act(function () { root.check(root.eight() === 191, "glassy again drew " + root.eight()) })
        ]
    }

    // Hyprland's own event stream: a workspace event sent after the rounding changed moves nothing, and configreloaded moves the radius.
    function socketSteps() {
        return [
            root.wait(function () { return Commons.Style.cornerRadius === 10 }),
            root.settle(root.startupSettleMs),
            // The stand-in sends its workspace event only once ws exists, so it arrives after the rounding file reads 0.
            root.act(function () { rounding.setText("0\n"); ws.setText("ws\n") }),
            root.wait(function () { wsSent.reload(); return wsSent.text() === "sent\n" }),
            root.settle(root.eventSettleMs),
            root.act(function () { root.check(Commons.Style.cornerRadius === 10, "a workspace event moved the corner radius"); go.setText("go\n") }),
            root.wait(function () { return Commons.Style.cornerRadius === 0 })
        ]
    }

    function report() {
        stepper.running = false
        console.log("GLASSM DONE checks=" + root.checks + " failed=" + root.failures.length)
        Quickshell.execDetached(["kill", String(Quickshell.processId)])
    }
    Component.onCompleted: root.buildSteps()

    FileView { id: go; path: root.roundingFile.replace(/rounding$/, "go"); printErrors: false; blockWrites: true }
    FileView { id: ws; path: root.roundingFile.replace(/rounding$/, "ws"); printErrors: false; blockWrites: true }
    FileView { id: wsSent; path: root.roundingFile.replace(/rounding$/, "ws-sent"); printErrors: false; blockLoading: true }
    FileView { id: rounding; path: root.roundingFile; printErrors: false; blockWrites: true }
    FileView { id: opaque; path: root.toggles + "/window-opaque.lua"; printErrors: false; blockWrites: true }
    FileView { id: glassy; path: root.toggles + "/window-glassy.lua"; printErrors: false; blockWrites: true }

    Timer {
        id: stepper
        interval: 50
        running: true
        repeat: true
        onTriggered: {
            if (root.stepIndex >= root.steps.length) { root.report(); return }
            if (root.steps[root.stepIndex]() === true) {
                root.stepIndex++
                root.stepTicks = 0
                return
            }
            if (++root.stepTicks > root.stepTickLimit) {
                root.check(false, "step " + root.stepIndex + " never completed")
                root.report()
            }
        }
    }
}
