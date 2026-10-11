import QtQuick
import qs.Commons
import "." as Flea
import "js/Format.js" as Format
import "js/Thumbs.js" as Thumbs

// The Quick Look's image pane, reached only through Preview.qml's Loader. It draws the file itself:
// the 256 px cache file the column draws would be an eightfold upscale on a surface this size.
Item {
    id: root

    property string path: ""

    // The row's cache file, held by Quick Look while this decodes: drawn between the
    // ground and the picture, so it is never hidden by one nor covers the other.
    property string interimThumb: ""
    property real interimX: 0
    property real interimY: 0
    property real interimWidth: 0
    property real interimHeight: 0
    property bool interimVisible: false
    readonly property bool interimReady: interimPicture.status === Image.Ready

    // The same name the media and PDF panes give their unreadable state, so Preview.qml tests one property; failed only with no thumbnail to stand in, and a decoding one keeps loading.
    readonly property bool failed: root.pictureFailed && interimPicture.status !== Image.Ready && interimPicture.status !== Image.Loading
    // Every state is terminal: a decode ends Ready or Error, and a vanished file ends Error too.
    readonly property string status: {
        if (root.failed) return "This image could not be read."
        return (picture.status === Image.Ready || root.fallbackShown) ? "image" : "loading"
    }
    // The original's pixels for the thumbnail fit, from Preview.qml's meta reply; 0 while unknown.
    property real origW: 0
    property real origH: 0
    // The final decode refused; the thumbnail below stands in when it decoded.
    readonly property bool pictureFailed: picture.status === Image.Error
    readonly property bool fallbackShown: root.pictureFailed && root.interimReady
    readonly property string name: root.path.substring(root.path.lastIndexOf("/") + 1)

    // The pixmap reader decodes only the final, one request at a time; it waits a turn after the build because Preview.qml binds the path before the thumbnail.
    property bool armed: false
    readonly property bool interimSettled: root.armed && interimPicture.status !== Image.Loading
    Timer {
        running: true
        interval: 0
        onTriggered: root.armed = true
    }

    // The letterbox ground the video pane uses: a photo almost never matches the surface's proportions.
    Rectangle {
        anchors.fill: parent
        color: Theme.color.background
    }

    // The cached thumbnail at once, sized to the final's rect by the caller; it stays as the picture at the column fit when the final cannot decode.
    Image {
        id: interimPicture
        readonly property real ownFit: Thumbs.fitScale(root.width, root.height, implicitWidth, implicitHeight,
            Thumbs.posterLimit(false, implicitWidth, implicitHeight, root.origW, root.origH))
        x: root.fallbackShown ? Math.round((root.width - width) / 2) : root.interimX
        y: root.fallbackShown ? Math.round((root.height - height) / 2) : root.interimY
        width: root.fallbackShown ? implicitWidth * ownFit : root.interimWidth
        height: root.fallbackShown ? implicitHeight * ownFit : root.interimHeight
        // Only while the decode runs: a final with transparent pixels would show it through.
        visible: root.interimVisible && root.status === "loading" || root.fallbackShown
        source: root.interimThumb.length > 0 ? Format.fileUri(root.interimThumb) : ""
        fillMode: Image.Stretch
        // A cache thumbnail decodes on the GUI thread in about a millisecond: the reader cannot drop a running decode.
        asynchronous: false
        cache: false
    }

    // Stretch, in an item sized to the fit of what was decoded: Qt then decodes the exact fit and never enlarges
    // in the decode, where Fit decoded a covering size (2099x3149 for a portrait photo, 34680x1156 for a 3000x100
    // banner, measured). A small picture draws at its own size, centred; only an SVG keeps Fit, which Stretch would distort.
    readonly property bool vector: /\.svgz?$/i.test(root.path)
    // The drawn picture itself, for ui/Ipc.qml's previewPictureRect: the item is sized to the
    // fit of what was decoded, so its rect is the picture and not the surface it is centred on.
    readonly property Item pictureItem: root.fallbackShown ? interimPicture : picture
    Image {
        id: picture
        readonly property real fit: Thumbs.fitScale(root.width, root.height, implicitWidth, implicitHeight, 1)
        x: root.vector ? 0 : Math.round((root.width - width) / 2)
        y: root.vector ? 0 : Math.round((root.height - height) / 2)
        width: root.vector ? root.width : implicitWidth * fit
        height: root.vector ? root.height : implicitHeight * fit
        visible: picture.status === Image.Ready
        // Format.fileUri, not a concatenation: a # or a ? in the name would truncate a hand-built URI.
        source: root.path.length > 0 && root.interimSettled ? Format.fileUri(root.path) : ""
        fillMode: root.vector ? Image.PreserveAspectFit : Image.Stretch
        // A phone keeps a portrait photo's turn in EXIF, and Qt leaves it unapplied unless asked.
        autoTransform: true
        asynchronous: true
        cache: false
        // Decoded no larger than the surface: the same 6016x3900 PNG is 94 MB of texture at full size
        // and 8 MB bound to this box's 2099x1156 surface, measured, for 17 ms more decode.
        // corner: a zero here means unbounded to Qt, so the floor is 1 and never 0.
        sourceSize.width: Math.max(1, Math.round(root.width))
        sourceSize.height: Math.max(1, Math.round(root.height))
    }

    // A failed decode is a mark and a sentence, never a bare ground: the blank-frame class again otherwise.
    Column {
        anchors.centerIn: parent
        width: parent.width - 2 * Theme.spacing.rowPaddingX
        spacing: Theme.spacing.gap
        visible: root.failed

        Flea.Glyph {
            anchors.horizontalCenter: parent.horizontalCenter
            // A failure mark stands alone, so it takes the pane-state ceiling States.dc.html draws at 40.
            maxSize: Theme.stateMarkSize
            width: Theme.stateMarkSize
            height: Theme.stateMarkSize
            name: "alert"
            color: Theme.color.error
        }

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.status
            color: Theme.color.foreground
            font.family: Theme.font.family
            font.pixelSize: Theme.font.body
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
        }

        // corner: a filename is arbitrary text, so PlainText, the same rule every name on this surface follows.
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.name
            color: Theme.color.muted
            font.family: Theme.font.family
            font.pixelSize: Theme.font.caption
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
        }
    }
}
