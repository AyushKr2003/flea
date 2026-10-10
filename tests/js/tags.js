.import "../../ui/js/Tags.js" as Tags
.import "../../ui/js/Menu.js" as Menu
.import "menu.js" as MenuSuite
.import "../../ui/js/Messages.js" as Messages

function run(check) {
    var routed = []
    var tagRoot = {settagged: function (m) { routed.push("settagged:" + m.ok) },
                   tagStatesResult: function (m) { routed.push("tagStatesResult:" + m.id) }}
    Messages.route(tagRoot, {t: "settagged", ok: 2, op: "remove"})
    Messages.route(tagRoot, {t: "tagstates", id: 3, applied: ["Red"], mixed: [], listing: 7})
    check("each tag message reaches its own Backend signal", routed.join(","), "settagged:2,tagStatesResult:3")
    check("seven names in menu order", Tags.NAMES.join(","), "Red,Orange,Yellow,Green,Blue,Purple,Gray")
    check("a tag on every file is applied", Tags.stateFor([["Red"], ["Red", "Blue"]], "Red"), "applied")
    check("a tag on some files is mixed", Tags.stateFor([["Red"], ["Blue"]], "Red"), "mixed")
    check("a tag on no file is absent", Tags.stateFor([["Red"], ["Blue"]], "Green"), "absent")
    check("an empty selection is absent, not applied", Tags.stateFor([], "Red"), "absent")
    check("statesFor reports every name", Tags.statesFor([["Red"], ["Blue"]]).Red, "mixed")
    check("statesFor reports an untouched name absent", Tags.statesFor([["Red"], ["Blue"]]).Green, "absent")
    check("one item is singular", Tags.statusLine(1, "Red"), "Tagged 1 item Red \u00b7 z undoes")
    check("three items are plural", Tags.statusLine(3, "Red"), "Tagged 3 items Red \u00b7 z undoes")
    check("clearing one item is singular", Tags.clearedLine(1), "Removed all tags from 1 item \u00b7 z undoes")
    check("clearing three items is plural", Tags.clearedLine(3), "Removed all tags from 3 items \u00b7 z undoes")
    check("removing from one item is singular", Tags.removedLine(1, "Red"), "Removed Red from 1 item \u00b7 z undoes")
    check("removing from three items is plural", Tags.removedLine(3, "Red"), "Removed Red from 3 items \u00b7 z undoes")
    check("an add answer says Tagged", Tags.changedLine("add", 2, "Blue"), "Tagged 2 items Blue \u00b7 z undoes")
    check("a remove answer says Removed", Tags.changedLine("remove", 2, "Blue"), "Removed Blue from 2 items \u00b7 z undoes")
    check("a clear answer says all tags", Tags.changedLine("clear", 1, ""), "Removed all tags from 1 item \u00b7 z undoes")
    var read = Tags.statesFrom(["Red"], ["Blue"])
    check("a backend read gives each name its state", [read.Red, read.Blue, read.Green].join(","), "applied,mixed,absent")
    check("the flyout names seven tags then remove-all", Tags.tagEntries({Red: "absent"}).map(function (e) { return e.separator === true ? "sep" : e.id }).join(","),
        "Red,Orange,Yellow,Green,Blue,Purple,Gray,sep,__clear__")
    check("the flyout carries each tag digit", Tags.tagEntries({}).filter(function (e) { return e.tagRow }).map(function (e) { return e.tagRow.digit }).join(""), "1234567")
    check("the flyout carries the mixed bar", Tags.tagEntries({Red: "mixed"}).filter(function (e) { return e.id === "Red" })[0].tagRow.state, "mixed")
    check("the flyout keys swatches by name", Tags.tagEntries({}).filter(function (e) { return e.id === "Red" })[0].tagRow.swatch, "Red")
    check("the flyout hints each row with its digit", Tags.tagEntries({}).filter(function (e) { return e.keyHint }).map(function (e) { return e.keyHint }).join(""), "1234567")
    check("the rail lists only tags in use, in menu order", Tags.railEntries({Blue: true, Red: true}).map(function (e) { return e.tag }).join(","), "Red,Blue")
    check("the rail rows carry their digit", Tags.railEntries({Gray: true}).map(function (e) { return e.digit }).join(","), "7")
    var file = Menu.listingEntries(MenuSuite.state({ tagSubmenu: Tags.tagEntries({Red: "absent"}, false) }))
    check("Tags follows Add to Favorites with its flyout", MenuSuite.entry(file, "tags").submenu.length, 9)
    check("the flyout spans seven tags, a separator and remove-all",
          MenuSuite.entry(file, "tags").submenu.map(function (r) { return r.separator === true ? "sep" : r.id }).join(","), "Red,Orange,Yellow,Green,Blue,Purple,Gray,sep,__clear__")
    var states = Tags.statesFor([["Red", "Blue"], ["Red"]])
    check("the flyout carries each state", Tags.tagEntries(states).filter(function (r) { return r.id === "Red" || r.id === "Blue" }).map(function (r) { return r.tagRow.state }).join(","), "applied,mixed")
    check("Tags row follows Add to Favorites", MenuSuite.actions(file).split(",").slice(-3).join(","), "addFavourite,tags,toggleHidden")
    check("a menu with no flyout offers no Tags row, as where the filesystem cannot store tags", MenuSuite.entry(Menu.listingEntries(MenuSuite.state({})), "tags").action, undefined)
    var window = [{ n: "a", tg: ["Red", "Blue"] }, { n: "b" }]
    var use = {}
    var seen = Tags.stamp(window, false, use, true)
    check("a tagged row latches the slot for every row of the reply", seen.latched + "|" + window[0].shown + "|" + window[1].shown, "true|true|true")
    check("the tags seen are recorded", Object.keys(use).join(","), "Red,Blue")
    check("a first sighting reports growth", seen.grew, true)
    var later = [{ n: "c" }]
    check("the slot stays for a later reply of the same folder", Tags.stamp(later, true, use, false).latched + "|" + later[0].shown, "true|true")
    check("a fresh listing without a tagged row drops the slot", Tags.stamp(later, true, use, true).latched + "|" + later[0].shown, "false|false")
    check("a folder with no tagged row never draws the slot", Tags.stamp([{ n: "d" }], false, {}, false).latched, false)
    check("a tag already seen reports no growth", Tags.stamp([{ n: "e", tg: ["Red"] }], false, use, false).grew, false)
}
