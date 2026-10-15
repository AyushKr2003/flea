pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons

// Built only for a mapped row; the original glyph supplies its slot, ink and ceiling.
Loader {
    id: root

    required property Item owner
    required property Item glyph
    active: !root.owner.thumbDrawn && root.owner.langSlug !== ""
    x: root.glyph.x
    y: root.glyph.y
    width: root.glyph.width
    height: root.glyph.height
    sourceComponent: LangMark {
        anchors.fill: parent
        maxSize: root.glyph.maxSize
        slug: root.owner.langSlug
        color: root.glyph.color
        strokeWidth: root.glyph.strokeWidth
        roundCaps: ViewState.hyprlandIcons && Style.cornerRadius > 0
    }
    onStatusChanged: if (status === Loader.Error) throw new Error("LangMark.qml did not load: Loader status " + status)
}
