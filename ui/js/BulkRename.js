.pragma library

.import "Format.js" as Format

// Every user-facing string is one whole template with %1 slots, filled in one place (ruling 16, no qsTr).
var WORDS = {
    footerPair: "%1 renamed · %2 unchanged",
    footerInvalid: "%1 renamed · %2 unchanged · %3 invalid",
    renameButton: "Rename %1",
    cardTitle: "Rename %1 items",
    sameLine: "same as line %1"
}
function applyFindReplace(oldNames, find, replace) {
    var out = []
    for (var i = 0; i < oldNames.length; i++) {
        if (!find) out.push(oldNames[i])
        else out.push(String(oldNames[i]).split(find).join(replace))
    }
    return out
}

// Sample input: "trip/4123.HEIC" at line 4 names "contains /".
function reasonFor(name, index, allNew, oldNames) {
    var text = String(name)
    if (text.length === 0) return "empty"
    if (text.indexOf("/") >= 0) return "contains /"
    if (text === "." || text === ".." || text.indexOf("\u0000") >= 0
            || text.indexOf("\r") >= 0 || text.indexOf("\n") >= 0) return "invalid"
    for (var j = index + 1; j < allNew.length; j++) {
        if (String(allNew[j]) === text) return WORDS.sameLine.replace("%1", j + 1)
    }
    return ""
}

// Counts split renamed, unchanged and invalid over the live rules alone; the backend refuses a name taken outside the batch.
function counts(oldNames, newNames) {
    var renamed = 0, unchanged = 0, invalid = 0
    for (var i = 0; i < newNames.length; i++) {
        if (reasonFor(newNames[i], i, newNames, oldNames) !== "") invalid += 1
        else if (String(newNames[i]) === String(oldNames[i])) unchanged += 1
        else renamed += 1
    }
    return { renamed: renamed, unchanged: unchanged, invalid: invalid }
}

// Sample input: 5, 1, 0 names "5 renamed \u00b7 1 unchanged".
function footer(renamed, unchanged, invalid) {
    if (invalid > 0)
        return WORDS.footerInvalid.replace("%1", Format.count(renamed)).replace("%2", Format.count(unchanged)).replace("%3", Format.count(invalid))
    return WORDS.footerPair.replace("%1", Format.count(renamed)).replace("%2", Format.count(unchanged))
}

// The Rename button label carries the live renamed count.
function renameLabel(renamed) {
    return WORDS.renameButton.replace("%1", Format.count(renamed))
}

// The card names its count once; it only opens over several rows, so one plural form holds.
function title(count) {
    return WORDS.cardTitle.replace("%1", Format.count(count))
}
