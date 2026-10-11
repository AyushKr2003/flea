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
    var ids = rows.map(function (row) { return row.id })
    var remember = rows[ids.indexOf("rememberViewPerFolder")] || {}
    var sorted = rows[ids.indexOf("rememberSort")] || {}
    check("Settings exposes the per-folder view switch", remember.label, "Remember each folder's view")
    check("and it ships off for backwards compatibility", remember.on, false)
    check("and it sits right after the last-used view", ids.indexOf("rememberViewPerFolder") - ids.indexOf("view"), 1)
    check("and it is the sort switch's shape: a check, one glyph, no caption",
          [remember.kind, typeof remember.glyph, remember.caption].join("|"), [sorted.kind, typeof sorted.glyph, sorted.caption].join("|"))
    var pane = Source.source("ui/Pane.qml")
    check("Pane resolves a directory through the new helper", pane.indexOf("FolderViews.viewFor") >= 0, true)
    var folder = Source.slice(pane, "readonly property string viewFolder", "// Dual draws lists")
    check("a folder's view is kept for no search, no Recent and no Trash standing over it",
          ["searchMode.length === 0", "recentMode.length === 0", "!trashHost.opened"].every(function (term) { return folder.indexOf(term) >= 0 }), true)
    var chooser = Source.slice(pane, "function chooseView(mode)", "function focusPreviewColumn()")
    check("a folder-view choice stores only for that folder, never the path under a search, Recent or Trash",
          chooser.indexOf("root.viewFolder") >= 0 && chooser.indexOf("root.path") < 0 && chooser.indexOf("root.trashHost") < 0, true)
    check("and choosing Dual, or any view while in Dual, sets the standing view first, and Dual itself stores no folder's",
          chooser.indexOf('mode === "dual" || root.dualMode') >= 0 && chooser.indexOf('if (mode === "dual")\n            return') >= 0, true)
    check("a list-only pane hands its view to the window and stores nothing itself",
          chooser.indexOf("if (root.listOnly) {\n            root.viewRequested(mode)") >= 0, true)
    var desired = Source.slice(pane, "function desiredView(path)", "function restoreView(path)")
    check("Dual draws the list in both panes, whatever the folder holds", desired.indexOf("root.dualMode") >= 0, true)
    var restore = Source.slice(pane, "id: preferences", "Connections {")
    check("a settled preference restores the view of the folder the pane lists", restore.indexOf("root.restoreView(root.viewFolder)") >= 0, true)
    check("navigation restores the destination view before listing", Source.source("ui/js/Nav.js").indexOf("pane.restoreView(newPath)") >= 0, true)
    check("a tab restore hands its folder to the pane to decide", Source.source("ui/js/Tabs.js").indexOf("pane.adoptView(item.path, item.viewMode)") >= 0, true)
    var winbody = Source.source("ui/WindowBody.qml")
    var chrome = Source.slice(winbody, "onViewChosen:", "// The path bar's four.")
    check("the chrome's view buttons send every choice to the primary pane, which the keys reach too", chrome.indexOf("primaryPane.chooseView(mode)") >= 0 && chrome.indexOf("changeKey") < 0, true)
    check("and the secondary pane's view choice takes the chrome's own route", winbody.indexOf("onViewRequested: function (mode) { chrome.viewChosen(mode) }") >= 0, true)
    var focus = Source.source("ui/js/Focus.js")
    check("and the three view keys call that same route",
          ['case "viewList": root.chooseView("list")', 'case "viewColumns": root.chooseView("columns")', 'case "viewGrid": root.chooseView("grid")'].every(function (line) { return focus.indexOf(line) >= 0 }), true)
    var picker = ["ui/PickerWindow.qml", "ui/PickerChrome.qml", "ui/PickerList.qml", "ui/PickerGrid.qml"].map(Source.source).join("")
    check("the picker keeps its own view and never touches the folder map or its switch",
          picker.indexOf("folderViews") < 0 && picker.indexOf("rememberViewPerFolder") < 0 && picker.indexOf("FolderViews") < 0, true)
}
