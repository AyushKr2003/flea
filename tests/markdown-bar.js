// Geometry assertions for the Markdown Quick Look bar against RenderedPreviews, read off MarkdownPane.barGeometry().

// ql_bar: the mark, the name, the muted count right after it, the Rendered | Source segment, then close.
function barError(g, tokens) {
    if (!g)
        return "the pane exposes no bar geometry";
    if (!g.segment || !g.rendered || !g.source)
        return "the bar exposes no Rendered | Source segment";
    if (g.markName !== "markdown")
        return "the bar mark is " + g.markName + ", want markdown";
    if (g.mark.width !== tokens.chromeMark || g.mark.x !== tokens.padX)
        return "the mark is " + g.mark.width + " px at " + g.mark.x + ", want " + tokens.chromeMark + " at " + tokens.padX;
    if (g.height !== tokens.chromeHeight)
        return "the bar is " + g.height + " px tall, want " + tokens.chromeHeight;
    if (!g.ready)
        return "the count never became ready";
    if (!(g.mark.x < g.name.x && g.name.x < g.lines.x && g.lines.x < g.segment.x && g.segment.x < g.close.x))
        return "order by x is mark " + g.mark.x + " name " + g.name.x + " count " + g.lines.x + " segment " + g.segment.x + " close " + g.close.x;
    if (g.name.x - (g.mark.x + g.mark.width) !== tokens.gap)
        return "the name starts " + (g.name.x - (g.mark.x + g.mark.width)) + " px after the mark, want " + tokens.gap;
    if (g.lines.x - g.nameEnd !== tokens.gap)
        return "the count starts " + (g.lines.x - g.nameEnd) + " px after the name's text, want " + tokens.gap;
    return segmentError(g, tokens) || inkError(g, "rendered", tokens) || pressError(g.bar, g.close, g.segment);
}

// The cell's word: the Text a segment cell draws, whether or not the pane around it is shown.
function wordOf(cell) {
    for (var i = 0; i < cell.children.length; i++)
        if (typeof cell.children[i].text === "string")
            return cell.children[i];
    return null;
}

// RenderedPreviews: two framed words 2 px apart at the strip's control height, centred above the rule, one gap before close.
function segmentError(g, tokens) {
    if (g.rendered.height !== tokens.controlHeight || g.source.height !== tokens.controlHeight || g.segment.height !== tokens.controlHeight)
        return "the segment is " + g.rendered.height + " and " + g.source.height + " px tall, want " + tokens.controlHeight;
    var top = Math.round((g.height - tokens.hairline - g.segment.height) / 2);
    if (g.segment.y !== top)
        return "the segment sits at y " + g.segment.y + ", want " + top + " above the rule";
    if (g.lines.x + g.lines.implicitWidth > g.segment.x)
        return "the count ends at " + (g.lines.x + g.lines.implicitWidth) + ", past the segment at " + g.segment.x;
    if (g.close.x - (g.segment.x + g.segment.width) !== tokens.gap)
        return "the segment ends " + (g.close.x - (g.segment.x + g.segment.width)) + " px before close, want " + tokens.gap;
    if (g.source.x - (g.rendered.x + g.rendered.width) !== tokens.segmentGap)
        return "the two words are " + (g.source.x - (g.rendered.x + g.rendered.width)) + " px apart, want " + tokens.segmentGap;
    var words = [[g.rendered, "Rendered"], [g.source, "Source"]];
    for (var i = 0; i < words.length; i++) {
        var word = wordOf(words[i][0]);
        if (!word || word.text !== words[i][1])
            return "the " + (i === 0 ? "first" : "second") + " word is " + (word ? word.text : "absent") + ", want " + words[i][1];
        if (Math.abs(words[i][0].width - (word.implicitWidth + 2 * tokens.gap)) > 0.001)
            return words[i][1] + " is " + words[i][0].width + " px wide, want its text " + word.implicitWidth + " plus two gaps of " + tokens.gap;
        if (word.font.pixelSize !== tokens.caption)
            return words[i][1] + " is set at " + word.font.pixelSize + " px, want the caption " + tokens.caption;
    }
    return "";
}

// The current word and its frame draw in the foreground, the other in muted, and no cell is filled or washed.
function inkError(g, view, tokens) {
    var cells = [[g.rendered, view === "rendered", "Rendered"], [g.source, view === "source", "Source"]];
    for (var i = 0; i < cells.length; i++) {
        var cell = cells[i][0];
        var want = cells[i][1] ? tokens.foreground : tokens.muted;
        var word = wordOf(cell);
        if (String(cell.border.color) !== want || String(word.color) !== want)
            return cells[i][2] + " draws its frame " + cell.border.color + " and word " + word.color + ", want " + want + " with " + view + " showing";
        if (cell.border.width !== tokens.hairline || cell.color.a !== 0)
            return cells[i][2] + " has a " + cell.border.width + " px frame over fill alpha " + cell.color.a + ", want " + tokens.hairline + " and none";
    }
    return "";
}

// Over a word the pointer is a pointing hand and nothing more: no wash and no frame item sits in the cell.
function hoverError(g) {
    var cells = [g.rendered, g.source];
    for (var i = 0; i < cells.length; i++) {
        var hover = null;
        for (var k = 0; k < cells[i].data.length; k++)
            if (cells[i].data[k].hovered !== undefined)
                hover = cells[i].data[k];
        if (!hover || hover.cursorShape !== Qt.PointingHandCursor)
            return "word " + i + " shows " + (hover ? hover.cursorShape : "no hover handler") + " over it, want the pointing hand";
        for (var c = 0; c < cells[i].children.length; c++)
            if (cells[i].children[c].border !== undefined)
                return "word " + i + " holds a wash or frame item " + cells[i].children[c];
    }
    return "";
}

// Every press target inside the bar belongs to the close button or to a word of the segment: an item owning a TapHandler or MouseArea is a control.
function pressError(bar, close, segment) {
    var stack = [bar], strays = [];
    while (stack.length) {
        var item = stack.pop();
        var owned = item.data || [];
        for (var i = 0; i < owned.length; i++) {
            if (owned[i].acceptedButtons !== undefined && !isWithin(item, close) && !isWithin(item, segment))
                strays.push(String(item));
            if (owned[i].data !== undefined)
                stack.push(owned[i]);
        }
    }
    return strays.length ? "the bar holds a press target besides close and the segment: " + strays.join(", ") : "";
}

function isWithin(item, ancestor) {
    for (var node = item; node; node = node.parent)
        if (node === ancestor)
            return true;
    return false;
}

// Tab walks to the close mark alone: nothing in the segment takes Qt focus or the Tab stop the dialogs' segmented rows can take.
function tabWalkError(g) {
    var stack = [g.segment];
    while (stack.length) {
        var item = stack.pop();
        if (item.activeFocus || item.activeFocusOnTab || item.focus || item.tabStop)
            return "the segment item " + item + " takes the keyboard (focus " + item.focus + ", tab stop " + item.activeFocusOnTab + "/" + item.tabStop + ")";
        for (var i = 0; i < item.children.length; i++)
            stack.push(item.children[i]);
    }
    return "";
}

// A name too long for the bar takes the room up to the count, and the count sits one gap before the segment.
function nameRoomError(g, tokens) {
    if (!g)
        return "the long-name pane exposes no bar geometry";
    if (!(g.name.width < g.name.implicitWidth))
        return "the name did not elide, so the room is not tested (" + g.name.width + "/" + g.name.implicitWidth + ")";
    var rightGap = g.segment.x - (g.lines.x + g.lines.implicitWidth);
    if (rightGap !== tokens.gap)
        return "the count ends " + rightGap + " px before the segment, want " + tokens.gap + " (name " + g.name.x + "+" + g.name.width
            + " count " + g.lines.x + "+" + g.lines.implicitWidth + " segment " + g.segment.x + " bar " + g.bar.width + ")";
    return "";
}

// The bar with views off, as the code and text panes draw it: no word of the segment shows and the count ends one gap before close.
function plainBarError(g, tokens) {
    if (!g)
        return "the plain bar exposes no geometry";
    if (g.segment !== null)
        return "the plain bar still exposes a segment";
    if (g.rendered.visible || g.source.visible)
        return "the plain bar still draws a word of the segment";
    if (g.markName !== "markdown")
        return "the plain bar mark is " + g.markName + ", want markdown";
    if (!(g.name.width < g.name.implicitWidth))
        return "the plain bar's name did not elide (" + g.name.width + "/" + g.name.implicitWidth + ")";
    if (!g.countShown)
        return "the plain bar hides its count";
    if (!(g.mark.x < g.name.x && g.name.x < g.lines.x && g.lines.x < g.close.x))
        return "order by x is mark " + g.mark.x + " name " + g.name.x + " count " + g.lines.x + " close " + g.close.x;
    var rightGap = g.close.x - (g.lines.x + g.lines.implicitWidth);
    if (rightGap !== tokens.gap)
        return "the count ends " + rightGap + " px before close, want " + tokens.gap;
    return "";
}

// What a bar draws that must not move or shrink when the room does, as numbers that outlive the width change.
function fixedSizes(g) {
    return { rendered: g.rendered.width, source: g.source.width, segment: g.segment.width, close: g.close.width, height: g.segment.height,
        right: g.bar.width - g.segment.x, countWidth: g.lines.implicitWidth, nameX: g.name.x };
}

// A width at which the name still has room to elide but the count has none: half the count short of the room that shows it.
function hidingWidth(was, tokens) {
    return was.nameX + 2 * tokens.gap + was.countWidth + was.right - Math.ceil(was.countWidth / 2) - 1;
}

// A narrower bar: the segment and close keep their size and distance from the right edge and the name gives way first, then the count hides.
function squeezeError(was, g, tokens, countHides) {
    var now = fixedSizes(g);
    var keys = ["rendered", "source", "segment", "close", "height", "right"];
    for (var i = 0; i < keys.length; i++)
        if (now[keys[i]] !== was[keys[i]])
            return "the " + keys[i] + " is " + now[keys[i]] + " at " + g.bar.width + " px, was " + was[keys[i]] + " when wide";
    if (g.segment.x < g.name.x + g.name.width + tokens.gap)
        return "the segment at " + g.segment.x + " overlaps the name ending at " + (g.name.x + g.name.width);
    if (g.countShown === countHides)
        return "the count is " + (g.countShown ? "shown" : "hidden") + " at " + g.bar.width + " px, want it " + (countHides ? "hidden" : "shown");
    if (!countHides && g.lines.x + g.lines.implicitWidth > g.segment.x)
        return "the count ends at " + (g.lines.x + g.lines.implicitWidth) + ", past the segment at " + g.segment.x;
    return "";
}
