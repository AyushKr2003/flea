.import "../../ui/js/BulkRename.js" as BulkRename

// Bulk rename card decisions: Find/Replace, live per-line reasons, footer counts.
function run(check) {
    check("find replaces every hit",
        BulkRename.applyFindReplace(["IMG_1.HEIC", "notes.txt"], "IMG_", "trip-").join(","),
        "trip-1.HEIC,notes.txt")
    check("empty find leaves names alone",
        BulkRename.applyFindReplace(["a.txt"], "", "x").join(","), "a.txt")
    var old = ["IMG_4120.HEIC", "IMG_4121.MOV"]
    var fresh = BulkRename.applyFindReplace(old, "IMG_", "trip-")
    check("duplicate names name the other line",
        BulkRename.reasonFor("trip-4121.MOV", 0, ["trip-4121.MOV", "trip-4121.MOV"], old), "same as line 2")
    check("a slash is refused with the board reason",
        BulkRename.reasonFor("trip/4123.HEIC", 3, ["a", "b", "c", "trip/4123.HEIC"], old), "contains /")
    check("an empty name is refused",
        BulkRename.reasonFor("", 0, ["", "b"], old), "empty")
    check("an unchanged name carries no reason",
        BulkRename.reasonFor("IMG_4120.HEIC", 0, ["IMG_4120.HEIC", "x"], old), "")
    check("footer names renamed and unchanged",
        BulkRename.footer(5, 1, 0), "5 renamed \u00b7 1 unchanged")
    check("footer names invalid too",
        BulkRename.footer(3, 1, 2), "3 renamed \u00b7 1 unchanged \u00b7 2 invalid")
    check("the card title carries the count",
        BulkRename.title(6), "Rename 6 items")
    check("counts split renamed, unchanged and invalid",
        JSON.stringify(BulkRename.counts(["a", "b", "c"], ["a", "b2", "b2"])),
        JSON.stringify({renamed: 1, unchanged: 1, invalid: 1}))
    check("a short newNames reads empty, never undefined",
        BulkRename.nameAt(["a"], 0) + "|" + BulkRename.nameAt(["a"], 1), "a|")
    check("the Tab order walks Find Replace lines buttons",
        BulkRename.focusStops(2).join(","), "find,replace,line 1,line 2,edit,cancel,rename")
    check("Tab from Replace enters the first name line",
        BulkRename.nextStop("replace", false, 2), "line 1")
    check("Tab from the last line reaches Edit in terminal",
        BulkRename.nextStop("line 2", false, 2), "edit")
    check("Shift+Tab from the first line returns to Replace",
        BulkRename.nextStop("line 1", true, 2), "replace")
    check("Tab wraps from Rename to Find",
        BulkRename.nextStop("rename", false, 2), "find")
}
