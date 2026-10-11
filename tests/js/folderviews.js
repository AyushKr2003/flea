.import "../../ui/js/FolderViews.js" as FolderViews
.import "../../ui/js/Settings.js" as Settings
.import "sourcefixture.js" as Source

function run(check) {
    check("the browser modes are List, Columns and Grid", FolderViews.MODES.join(","), "list,columns,grid")
    check("a missing map has no folder view", FolderViews.get(null, "/a"), "")
    var one = FolderViews.set({}, "/home/gm", "grid")
    check("a folder records its Grid choice", FolderViews.get(one, "/home/gm"), "grid")
    check("and another folder remains unset", FolderViews.has(one, "/home/gm/Downloads"), false)
    var both = FolderViews.set(one, "/home/gm/Downloads", "list")
    check("two folders retain independent choices", FolderViews.get(both, "/home/gm"), "grid")
    check("and Downloads has its own List choice", FolderViews.get(both, "/home/gm/Downloads"), "list")
    check("a saved folder wins only while the setting is on", FolderViews.viewFor(both, "/home/gm", "columns", true), "grid")
    check("otherwise the global fallback stays in effect", FolderViews.viewFor(both, "/home/gm", "columns", false), "columns")
    check("an unvisited folder uses the global fallback", FolderViews.viewFor(both, "/home/gm/Pictures", "columns", true), "columns")
    check("a malformed mode falls back safely", FolderViews.viewFor({"/a": "dual"}, "/a", "list", true), "list")
    check("the dual-pane window layout is never a folder view", FolderViews.MODES.indexOf("dual"), -1)
    check("remembering needs both the setting and a path", FolderViews.shouldRemember(true, "/a"), true)
    check("and an empty path cannot create an entry", FolderViews.shouldRemember(true, ""), false)
    check("and disabling the setting prevents a write", FolderViews.shouldRemember(false, "/a"), false)
    var full = {}
    for (var i = 0; i < FolderViews.MAX; i++)
        full = FolderViews.set(full, "/d" + i, "list")
    var over = FolderViews.set(full, "/new", "columns")
    check("the map is capped", Object.keys(over).length, FolderViews.MAX)
    check("and evicts its oldest entry", FolderViews.has(over, "/d0"), false)
    check("while retaining its newest entry", FolderViews.get(over, "/new"), "columns")
    var rows = Settings.rows("view", { data: {} })
    var remember = rows.filter(function (row) { return row.id === "rememberViewPerFolder" })[0] || {}
    check("Settings exposes the per-folder view switch", remember.label, "Remember view mode per folder")
    check("and it ships off for backwards compatibility", remember.on, false)
    check("Pane resolves a directory through the new helper", Source.source("ui/Pane.qml").indexOf("FolderViews.viewFor") >= 0, true)
    var chooser = Source.slice(Source.source("ui/Pane.qml"), "function chooseView(mode)", "function focusPreviewColumn()")
    check("a folder-view choice tests Pane's Trash host, not a missing root property", chooser.indexOf("!trashHost.opened") >= 0, true)
    check("and it cannot throw through an undefined root Trash property", chooser.indexOf("root.trashHost") < 0, true)
    check("navigation restores the destination view before listing", Source.source("ui/js/Nav.js").indexOf("pane.restoreView(newPath)") >= 0, true)
}
