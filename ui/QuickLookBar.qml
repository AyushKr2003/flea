import QtQuick
import "." as Flea

// The Quick Look strip: kind mark, name, count, the Rendered | Source segment where the kind has both views, and close.
// No fill of its own: Quick Look's surface is already the chrome colour and rounds the corners this bar sits under.
Item {
    id: root

    property string markName: "file"
    property string name: ""
    // Empty hides the count; it hides too once the name has given up all its room.
    property string countLabel: ""
    // True draws the segment, and view is the word of it that shows.
    property bool views: false
    property string view: "rendered"
    // The keyboard is on the close mark; Quick Look's key handler owns the walk, as the PDF viewer's controls do.
    property bool closeFocused: false

    signal closeRequested
    // The view a pointer chose, which is never the one already showing.
    signal viewRequested(string view)

    height: Theme.chromeHeight
    readonly property real ruleOpacity: 0.12
    // Where the right-hand group starts: the name and the count give way to it, it never gives way to them.
    readonly property real trail: root.views ? segment.x : barClose.x
    readonly property bool countShown: root.countLabel.length > 0
        && barName.x + 2 * Theme.spacing.gap + barLines.implicitWidth <= root.trail

    // The render suite reads the bar's order off these rects, the way PdfViewer.buttonFor opens its buttons.
    function geometry() {
        return { mark: barMark, markName: barMark.name, name: barName, nameEnd: barName.x + Math.min(barName.width, barName.implicitWidth),
            lines: barLines, countShown: root.countShown, close: barClose, bar: root, height: root.height,
            segment: root.views ? segment : null, rendered: root.cell(0), source: root.cell(1) }
    }

    function cell(i) {
        for (var k = 0; k < segment.children.length; k++)
            if (segment.children[k].index === i)
                return segment.children[k]
        return null
    }

    function closeState() { var c = barClose.mapToItem(null, barClose.width / 2, barClose.height / 2); return { hovered: barClose.hovered, pressed: barClose.pressed, focused: barClose.keyboardFocused, centre: Math.round(c.x) + " " + Math.round(c.y) } }

    Rectangle {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: Theme.spacing.hairline
        color: Theme.color.foreground
        opacity: root.ruleOpacity
    }

    // The kind's mark of the LanguageMarks set, in foreground and centred above the rule like the PDF viewer's kind mark.
    Flea.Glyph {
        id: barMark
        anchors.left: parent.left
        anchors.leftMargin: Theme.spacing.rowPaddingX
        y: Math.round((parent.height - Theme.spacing.hairline - height) / 2)
        width: Theme.chromeMarkSize
        height: Theme.chromeMarkSize
        name: root.markName
        color: Theme.color.foreground
    }

    // corner: a filename is arbitrary text, so PlainText, the same rule every name on this surface follows.
    Text {
        id: barName
        anchors.left: barMark.right
        anchors.leftMargin: Theme.spacing.gap
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, Math.max(0, root.trail - x - 2 * Theme.spacing.gap
            - (root.countShown ? barLines.implicitWidth : 0)))
        text: root.name
        color: Theme.color.foreground
        font.family: Theme.font.family
        font.pixelSize: Theme.font.caption
        textFormat: Text.PlainText
        elide: Text.ElideMiddle
    }

    Text {
        id: barLines
        anchors.left: barName.right
        anchors.leftMargin: Theme.spacing.gap
        anchors.verticalCenter: parent.verticalCenter
        text: root.countLabel
        visible: root.countShown
        color: Theme.color.muted
        font.family: Theme.font.family
        font.pixelSize: Theme.font.caption
        textFormat: Text.PlainText
    }

    // The strip's own size of Settings' segmented control: the current word and its frame in foreground, the other muted, no wash, the keyboard never here.
    Flea.SettingsSegment {
        id: segment
        visible: root.views
        anchors.right: barClose.left
        anchors.rightMargin: Theme.spacing.gap
        y: Math.round((parent.height - Theme.spacing.hairline - height) / 2)
        cellHeight: Theme.chromeControlHeight
        options: ["Rendered", "Source"]
        value: root.view === "source" ? "Source" : "Rendered"
        onPicked: function (index) { root.viewRequested(index === 1 ? "source" : "rendered") }
    }

    Flea.ChromeButton {
        id: barClose
        gesturePolicy: TapHandler.ReleaseWithinBounds
        ruleRows: Theme.spacing.hairline
        anchors.right: parent.right
        anchors.rightMargin: Theme.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        glyph: "x"
        keyboardFocused: root.closeFocused
        accessName: "Close"
        onActivated: root.closeRequested()
    }
}
