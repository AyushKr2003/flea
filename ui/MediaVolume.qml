import QtQuick
import "." as Flea

// Media040's level on the Quick Look strip: a media track that reads Flea.MediaSound's volume and sets
// it from the pointer. Unlike the seek there is no player position to fight, so a press or drag sets
// the level live and the release stores it. Mute does not move it: the track draws the level while muted.
Flea.MediaTrack {
    id: root

    // Any contact at all, so a host that hides the strip over a video can re-arm its own timer.
    signal touched()

    fraction: Flea.MediaSound.volume / 100

    Accessible.role: Accessible.Slider
    Accessible.name: "Volume"

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onPressed: function (mouse) {
            root.touched()
            Flea.MediaSound.setVolume(Math.round(100 * root.fractionAt(mouse.x)))
        }
        onPositionChanged: function (mouse) {
            root.touched()
            if (pressed)
                Flea.MediaSound.setVolume(Math.round(100 * root.fractionAt(mouse.x)))
        }
        onReleased: {
            root.touched()
            Flea.MediaSound.keepVolume()
        }
        // A stolen grab ends the drag like a release, so the level heard is the level kept.
        onCanceled: Flea.MediaSound.keepVolume()
    }
}
