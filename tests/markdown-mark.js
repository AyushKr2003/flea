// The mark a Quick Look bar draws, read off its Shape for the Markdown render suite.

// The path the bar's mark cell strokes, read off its drawn Shape and not off the name property that chose it.
function drawnPath(mark) {
    for (var i = 0; i < mark.children.length; i++) {
        var shape = mark.children[i];
        for (var j = 0; shape.data && j < shape.data.length; j++) {
            var elements = shape.data[j].pathElements;
            if (elements && elements.length > 0 && elements[0].path !== undefined)
                return String(elements[0].path);
        }
    }
    return "";
}

// The mark the bar draws is the board's Markdown mark, whatever markName was set to.
function markError(g, tokens) {
    var drawn = drawnPath(g.mark);
    if (drawn !== tokens.markdownPath)
        return "the bar draws the path \"" + drawn + "\", want the Markdown mark \"" + tokens.markdownPath + "\"";
    return "";
}
