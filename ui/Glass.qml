pragma Singleton
import QtQuick
import qs.Commons
import qs.Commons as Commons

// shell.toml's [flea] background-alpha through Omarchy's reader: one plane per pixel, content opaque; AGENTS.md "Theme roles and sources".
QtObject {
    id: root

    readonly property string key: "flea.background-alpha"
    // Set once by launch(), before the window exists, because a Wayland surface's format is fixed at creation.
    property bool clear: false
    // In whole 8-bit steps, so a value that rounds to 1 is 1; an opaque launch holds 1 until the next launch.
    readonly property real alpha: root.clear ? root.stepped(Commons.Color.pickAlpha(root.key, 1)) : 1
    // False keeps every plane on its own opaque role, so a stock theme draws exactly what it drew before.
    readonly property bool on: root.alpha < 1
    readonly property color background: root.on ? Util.alpha(Theme.color.background, root.alpha) : Theme.color.background
    readonly property color surface: root.on ? Util.alpha(Theme.color.surface, root.alpha) : Theme.color.surface

    // Sample input: 0.34 answers 87/255, 0.999 answers 1.
    function stepped(value) { return Math.round(value * 255) / 255 }

    // Color's two shell readers load asynchronously; waiting here lands both before the decision.
    function launch() {
        Commons.Color.shellFile.waitForJob()
        Commons.Color.userShellFile.waitForJob()
        root.clear = root.stepped(Commons.Color.pickAlpha(root.key, 1)) < 1
    }
}
