pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

// shell.toml's [flea] background-alpha through Omarchy's reader, and Omarchy's Window Transparency mode: one plane per pixel, content opaque; AGENTS.md "Theme roles and sources".
QtObject {
    id: root

    readonly property string key: "flea.background-alpha"
    // Flea's own Glassy ground, held at today's look until the step 6 pick moves it in this one line.
    property real glassAlpha: 1
    // "opaque", "glassy" or "transparent" (Omarchy's default), read from its toggle files by reread().
    property string mode: "transparent"
    property bool hasOpaque: false
    property bool hasGlassy: false
    // Set once by launch(), before the window exists, because a Wayland surface's format is fixed at creation.
    property bool clear: false
    // In whole 8-bit steps, so a value that rounds to 1 is 1; an opaque launch holds 1 until the next launch.
    readonly property real alpha: root.clear ? root.stepped(root.wanted()) : 1
    // False keeps every plane on its own opaque role, so a stock theme draws exactly what it drew before.
    readonly property bool on: root.alpha < 1
    readonly property color background: root.on ? Util.alpha(Theme.color.background, root.alpha) : Theme.color.background
    readonly property color surface: root.on ? Util.alpha(Theme.color.surface, root.alpha) : Theme.color.surface

    readonly property string toggleDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/toggles/hypr"
    // A file test and not omarchy-hyprland-window-transparency, which needs OMARCHY_PATH that ssh and some launchers lack.
    property FileView opaqueFile: FileView {
        path: root.toggleDir + "/window-opaque.lua"
        printErrors: false
        onLoaded: root.hasOpaque = true
        onLoadFailed: root.hasOpaque = false
    }
    property FileView glassyFile: FileView {
        path: root.toggleDir + "/window-glassy.lua"
        printErrors: false
        onLoaded: root.hasGlassy = true
        onLoadFailed: root.hasGlassy = false
    }
    // Hyprland reloads its config for a Window Transparency change, with no theme switch.
    property Connections reloads: Connections {
        target: Theme
        function onConfigReloaded() { root.reread() }
    }

    // Sample input: 0.34 answers 87/255, 0.999 answers 1.
    function stepped(value) { return Math.round(value * 255) / 255 }

    // One shell.toml's value: -1 when it sets none, the clamped number, or 1 for what is not a number.
    function valueIn(values) {
        var v = values ? values[root.key] : undefined
        if (typeof v !== "string" || v.length === 0) return -1
        var n = Number(v)
        return isFinite(n) ? Util.clampAlpha(n) : 1
    }
    // The user's value wins, opaque is 1, glassy takes the theme's value else glassAlpha, transparent the theme's else 1.
    function wanted() {
        var user = root.valueIn(Commons.Color.userShellValues)
        if (user >= 0) return user
        if (root.mode === "opaque") return 1
        var theme = root.valueIn(Commons.Color.themeShellValues)
        if (theme >= 0) return theme
        return root.mode === "glassy" ? root.glassAlpha : 1
    }

    function reread() {
        root.opaqueFile.reload()
        root.glassyFile.reload()
        root.opaqueFile.waitForJob()
        root.glassyFile.waitForJob()
        root.mode = root.hasGlassy ? "glassy" : root.hasOpaque ? "opaque" : "transparent"
    }

    // Color's two shell readers load asynchronously; waiting here lands both before the decision.
    function launch() {
        Commons.Color.shellFile.waitForJob()
        Commons.Color.userShellFile.waitForJob()
        root.reread()
        root.clear = root.stepped(root.wanted()) < 1
    }
}
