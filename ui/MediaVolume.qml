import QtQuick
import "." as Flea

// Media040's level on the Quick Look strip: a track that sets Flea.MediaSound's volume live and stores it on release; mute leaves it alone.
Flea.MediaTrack {
    id: root

    // Any contact at all, so a host that hides the strip over a video can re-arm its own timer.
    signal touched()

    // True while this track's own press holds the level, so closing Quick Look under a button still down lets it go.
    property bool pressing: false

    fraction: Flea.MediaSound.volume / 100

    Component.onDestruction: if (root.pressing) Flea.MediaSound.held = -1

    Accessible.role: Accessible.Slider
    Accessible.name: "Volume"

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onPressed: function (mouse) {
            root.pressing = true
            root.touched()
            Flea.MediaSound.setVolume(Math.round(100 * root.fractionAt(mouse.x)))
        }
        onPositionChanged: function (mouse) {
            root.touched()
            if (pressed)
                Flea.MediaSound.setVolume(Math.round(100 * root.fractionAt(mouse.x)))
        }
        onReleased: {
            root.pressing = false
            root.touched()
            Flea.MediaSound.keepVolume()
        }
        // A stolen grab ends the drag like a release, so the level heard is the level kept.
        onCanceled: {
            root.pressing = false
            Flea.MediaSound.keepVolume()
        }
    }
}
