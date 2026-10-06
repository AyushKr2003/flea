.import "../../ui/js/Archive.js" as Archive
.import "../../ui/js/ArchiveOps.js" as ArchiveOps
.import "../../ui/js/Menu.js" as Menu
.import "../../ui/js/Ops.js" as Ops

// Archives040: the password flows, the compress submenu and the disk-image rule. New checks live
// here rather than in ops.js or menu.js, which keep the ceilings S2 is de-slopping.
function menuState(changes) {
    var value = { hasRow: true, selectionCount: 1, rowMode: 0o100644, clipboardAvailable: false,
        hiddenActions: ["delete", "openTerminal", "moveto", "copyto", "properties", "permissions",
            "copyAs", "pasteAs", "invertSelection"],
        archiveFormats: ["zip"], canExtract: true, rowIsArchive: false }
    for (var key in changes) value[key] = changes[key]
    return value
}
function menuEntry(rows, action) {
    return rows.filter(function (r) { return r.action === action })[0] || {}
}

function run(check) {
    // An extract stashes its source for the retry, the cards host opens over resolved
    // paths, and both submits carry the secret to the wire.
    var pwSent = []
    var pwPane = { path: "/d", cursorIndex: 0,
        rowFor: function () { return { n: "backup.7z", d: false } },
        join: function (a, b) { return a + "/" + b },
        sticky: function () {},
        extractPwSource: null,
        backend: {
            extract: function (path, dest, id) { pwSent.push("extract:" + path + "|" + dest) },
            compressPw: function (paths, dest, format, password, encrypt, id) {
                pwSent.push([paths.length, dest, format, password === "s3cret", encrypt, id].join("|")) },
            extractPw: function (path, dest, password, id) {
                pwSent.push(["extract", path, dest, password === "s3cret", id].join("|")) },
            askPaths: function (idx) { pwSent.push("ask:" + idx.join(",")) }
        } }
    var pwCards = { compressPwSource: null,
        openCompressDialog: function (source, leaf, holder) {
            pwSent.push("dialog:" + source.paths.length + ":" + leaf) } }
    Ops.extract(pwPane, 0)
    check("an extract stashes its source for the password retry",
          pwPane.extractPwSource ? pwPane.extractPwSource.path + "|" + pwPane.extractPwSource.dest : "lost",
          "/d/backup.7z|/d/backup")
    ArchiveOps.compressPwResolved(pwCards, pwPane, ["/d/a", "/d/b"], 3)
    check("the cards host opens over the resolved paths",
          pwSent.join(",") + "|" + pwCards.compressPwSource.paths.length
          + "|" + pwCards.compressPwSource.menuId,
          "extract:/d/backup.7z|/d/backup,dialog:2:d|2|3")
    ArchiveOps.submitCompressPw(pwPane, pwCards.compressPwSource, "7z", "Archive.7z", "s3cret", true)
    check("the submit carries the secret to the wire, never the card",
          pwSent[pwSent.length - 1], "2|/d/Archive.7z|7z|true|true|3")
    ArchiveOps.submitExtractPw(pwPane, "s3cret")
    check("the retry reuses the stashed destination",
          pwSent[pwSent.length - 1], "extract|/d/backup.7z|/d/backup|true|0")
    var askPane = { path: "/d", selectedIndices: function () { return [0, 1] },
        join: function (a, b) { return a + "/" + b }, sticky: function () {},
        backend: { askPaths: function (idx) { pwSent.push("ask:" + idx.join(",")) } } }
    ArchiveOps.openCompressPw(askPane, 5, pwCards)
    check("without paths the selection is asked under a deliver claim",
          pwSent[pwSent.length - 1] + "|" + askPane.pathsPending.kind
          + "|" + (typeof askPane.pathsPending.deliver),
          "ask:0,1|compressPw|function")
    askPane.pathsPending.deliver(["/d/a", "/d/b"])
    check("and the reply opens the dialog with its menu id",
          pwSent[pwSent.length - 1] + "|" + pwCards.compressPwSource.menuId,
          "dialog:2:d|5")

    // The compress submenu ends with the password row where 7z is installed.
    var withPw = menuEntry(Menu.listingEntries(menuState({ archiveFormats: ["zip", "7z"] })), "compress")
    check("the submenu is the probed table plus the password row",
          withPw.submenu.map(function (r) { return r.separator === true ? "sep" : r.id }).join("|"),
          "zip|7z|sep|compressPw")
    check("and the password row wears the key mark",
          withPw.submenu[withPw.submenu.length - 1].glyph, "key")
    check("without 7z the password row is hidden",
          menuEntry(Menu.listingEntries(menuState({ archiveFormats: ["zip"] })), "compress").submenu.length, 1)
    check("a disk image offers no Extract row at all",
          menuEntry(Menu.listingEntries(menuState({ rowIsArchive: true, archiveName: "debian-13.iso" })), "extract").action, undefined)

    // The extract card's routing reads backend codes, never sentences: an encrypted archive
    // opens the card, a wrong answer reopens it, and anything else messages.
    check("an encrypted archive opens the extract card",
          Archive.doneAction(false, "encrypted"), "password")
    check("a wrong answer reopens it", Archive.doneAction(false, "wrong-password"), "wrong")
    check("any other failure messages", Archive.doneAction(false, "the archive tool failed"), "")
    check("and a success never cards", Archive.doneAction(true, ""), "")
    check("the wrong-password sentence is one template filled once",
          Archive.wrongPasswordSentence("backup.7z"),
          "That password did not open backup.7z.")
    check("the card titles are whole sentences, never joined fragments",
          Archive.compressTitle(1) + "|" + Archive.compressTitle(3) + "|"
          + Archive.encryptedTitle("backup.7z") + "|"
          + ArchiveOps.compressSticky(3, "7z"),
          "Compress 1 item|Compress 3 items|backup.7z is encrypted|Compressing 3 items to .7z")
    check("the card titles the stashed leaf",
          Archive.stashedLeaf({ path: "/d/backup.7z" }) + "|" + Archive.stashedLeaf(null), "backup.7z|")
}
