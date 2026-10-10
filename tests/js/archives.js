.import "../../ui/js/Archive.js" as Archive
.import "../../ui/js/ArchiveOps.js" as ArchiveOps
.import "../../ui/js/Menu.js" as Menu
.import "../../ui/js/Ops.js" as Ops
.import "sourcefixture.js" as Source

// The password flows, the compress submenu and the disk-image rule, kept out of ops.js and menu.js, which hold their ceilings.
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

// A call that throws is one failed check, not a harness that dies without a tally.
function attempt(fn) {
    try { return fn() } catch (e) { return "threw: " + e }
}

function run(check) {
    var pwSent = []
    var pwPane = { path: "/d", cursorIndex: 0,
        rowFor: function () { return { n: "backup.7z", d: false } },
        join: function (a, b) { return a + "/" + b },
        sticky: function () {},
        backend: {
            extract: function (path, dest, id) { pwSent.push("extract:" + path + "|" + dest) },
            compressPw: function (paths, dest, format, password, encrypt, id) {
                pwSent.push([paths.length, dest, format, password === "s3cret", encrypt, id].join("|")) },
            extractPw: function (path, dest, password, id) {
                pwSent.push(["extract", path, dest, password === "s3cret", id].join("|")) },
            askPaths: function (idx) { pwSent.push("ask:" + idx.join(",")) }
        } }
    var opened = []
    var pwCards = { openCompressDialog: function (source, leaf, holder) { opened.push(source); pwSent.push("dialog:" + source.paths.length + ":" + leaf) } }
    Ops.extract(pwPane, 0)
    check("AB4: an extract sends its paths and keeps no stash on the pane",
          pwSent.join(",") + "|" + ("extractPwSource" in pwPane), "extract:/d/backup.7z|/d/backup|false")
    ArchiveOps.compressPwResolved(pwCards, pwPane, ["/d/a", "/d/b"], 3)
    check("AB1: the cards host opens over the resolved paths and the menu id",
          pwSent[pwSent.length - 1] + "|" + opened[0].menuId, "dialog:2:d|3")
    ArchiveOps.submitCompressPw(pwPane, opened[0], "7z", "Archive.7z", "s3cret", true)
    check("the submit carries the secret to the wire, never the card",
          pwSent[pwSent.length - 1] + "|" + JSON.stringify(opened[0]).indexOf("s3cret"), "2|/d/Archive.7z|7z|true|true|3|-1")
    ArchiveOps.submitExtractPw(pwPane, { path: "/d/backup.7z", dest: "/d/backup" }, "s3cret")
    check("AB4: the retry goes to the source the card was opened over",
          pwSent[pwSent.length - 1], "extract|/d/backup.7z|/d/backup|true|0")
    var before = pwSent.length
    ArchiveOps.submitExtractPw(pwPane, null, "s3cret")
    check("AB4: a retry with no source sends nothing", pwSent.length, before)
    var refusedPane = { path: "/d", join: function (a, b) { return a + "/" + b },
        sticky: function (line) { pwSent.push("sticky:" + line) },
        backend: { queueing: true, compressPw: function () { pwSent.push("queued-compress") } } }
    ArchiveOps.submitCompressPw(refusedPane, { paths: ["/d/a"], menuId: 0 }, "7z", "Archive.7z", "s3cret", true)
    check("AB4: a queueing send leaves no stale sticky line", pwSent[pwSent.length - 1], "queued-compress")
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
          pwSent[pwSent.length - 1] + "|" + opened[opened.length - 1].menuId,
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

    // The extract card's routing reads backend codes, never sentences.
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
    check("AB4: the card titles the leaf of the source it opened over",
          attempt(function () { return Archive.sourceLeaf({ path: "/d/backup.7z" }) + "|" + Archive.sourceLeaf(null) }), "backup.7z|")
    check("AB8: a busy card is one whole sentence per verb",
          attempt(function () { return Archive.cardBusySentence("compress") }), "Another password card is open. Answer it, then compress again.")
    check("AB9: the dead helpers are gone", typeof Archive.hasSevenZip + "|" + typeof Archive.stashedLeaf, "undefined|undefined")

    // Sources: send's log, the card host fails loud, and the compress card has no busy state; the queue and the cards are driven in archivecards.js.
    var sendBody = Source.slice(Source.source("ui/Backend.qml"), "function send(object)", "// One composition")
    check("AB3: send's one log names the command and never the request",
          JSON.stringify(sendBody.match(/console\.[^\n]*/g)), '["console.warn(\\"Backend refused command \\" + object.c); return }"]')
    var hostBody = Source.slice(Source.source("ui/WindowBody.qml"), "function openArchiveCards()", "Loader {")
    check("AB6: the cards host fails loud, naming the file and the component's error",
          ["Component.Ready", "errorString()", "ArchiveCards.qml did not build"].map(function (t) { return hostBody.indexOf(t) >= 0 }).join("|"),
          "true|true|true")
    check("AB9: the compress card has no busy state that never turns on",
          Source.source("ui/ArchiveCompressDialog.qml").indexOf("busy") < 0, true)
    // AB2 runs on the real card: tests/archive-threat.qml "AB2 pair" and tests/js/archivecards.js F22.
}
