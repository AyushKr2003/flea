.pragma library

.import "Format.js" as Format

// Which rows get an Extract, and what a new archive is called. The backend never sends an is-archive
// flag: the client is given the icon name and never the MIME type, so this is the whole mechanism.

// Longest form first, so ".tar.gz" is matched before ".gz" could be. Flea reads rar and cannot write
// one, so .rar is here, where Extract is decided, and never in the compress submenu, which is the
// table src/backend/archive.rs probed. Archives040 widens the same rule to packages and disk images,
// which 7z reads in the same sandboxed path; a disk image lists only and never extracts.
var EXTENSIONS = [".tar.zst", ".tar.bz2", ".tar.gz", ".tar.xz", ".tgz", ".tar", ".zip", ".7z", ".rar",
    ".appimage", ".cpio", ".cab", ".jar", ".apk", ".rpm", ".deb", ".iso"]

// A disk image lists in the archive preview and is never extracted.
var LIST_ONLY = [".iso"]

function isArchive(name) {
    var lower = String(name).toLowerCase()
    for (var i = 0; i < EXTENSIONS.length; i++) {
        if (lower.length > EXTENSIONS[i].length && lower.indexOf(EXTENSIONS[i], lower.length - EXTENSIONS[i].length) !== -1) {
            return true
        }
    }
    return false
}

// The name an extract unpacks into: the archive's own, with every archive extension taken off.
function extractDir(name) {
    var text = String(name)
    var lower = text.toLowerCase()
    for (var i = 0; i < EXTENSIONS.length; i++) {
        if (lower.length > EXTENSIONS[i].length && lower.indexOf(EXTENSIONS[i], lower.length - EXTENSIONS[i].length) !== -1) {
            return text.substring(0, text.length - EXTENSIONS[i].length)
        }
    }
    return text
}

// One row compresses under its own name; several compress under the directory holding them.
function archiveStem(names, parentLeaf) {
    if (names.length === 1) {
        return stripExtension(names[0])
    }
    return parentLeaf.length > 0 ? parentLeaf : "archive"
}

function stripExtension(name) {
    var text = String(name)
    var cut = text.lastIndexOf(".")
    return cut > 0 ? text.substring(0, cut) : text
}

// The compress submenu is the table the backend probed, so no 7zip means no .7z; the sheet reads each leaf "Compress to .zip".
function formatEntries(formats) {
    var out = []
    for (var i = 0; i < formats.length; i++) {
        out.push({ id: formats[i], label: "." + formats[i], sheetLabel: "Compress to ." + formats[i] })
    }
    return out
}

// Whether an installed tool reads this archive: .7z needs 7z, .zip/.rar either tool, tar bsdtar,
// and every widened format 7z alone. A disk image lists only, so it never extracts anywhere.
function canExtract(name, extraction) {
    var lower = String(name).toLowerCase()
    var caps = extraction || ({})
    if (isListOnly(name)) return false
    if (hasSuffix(lower, ".7z")) return caps.sevenZip === true
    if (hasSuffix(lower, ".zip") || hasSuffix(lower, ".rar")) return caps.zip === true
    if (isSevenSuffix(lower)) return caps.sevenZip === true
    return caps.archive === true
}

// A disk image lists in the archive preview and is never extracted.
function isListOnly(name) {
    var lower = String(name).toLowerCase()
    for (var i = 0; i < LIST_ONLY.length; i++) {
        if (hasSuffix(lower, LIST_ONLY[i])) return true
    }
    return false
}

// The widened tail of EXTENSIONS, which only 7z reads; tar and the zip class keep their own rules.
function isSevenSuffix(lower) {
    var tails = [".appimage", ".cpio", ".cab", ".jar", ".apk", ".rpm", ".deb", ".iso"]
    for (var i = 0; i < tails.length; i++) {
        if (hasSuffix(lower, tails[i])) return true
    }
    return false
}

// The missing program for a disabled Extract: only bsdtar offers "tar" and only 7z offers "7z".
function extractHint(formats) {
    var table = formats || []
    if (table.indexOf("7z") >= 0) return "bsdtar is not installed"
    if (table.indexOf("tar") >= 0) return "7-Zip is not installed"
    return "No archive tool is installed"
}

// Ui/js/Menu.js's Extract row: absent for none, disabled with its reason for no reader, and absent
// for a disk image, which lists only and never extracts.
function extractEntry(entry, p, count) {
    if (!p.rowIsArchive || count !== 1) return false
    if (isListOnly(p.archiveName || "")) return false
    if (p.canExtract !== true) {
        entry.disabled = true
        entry.hint = extractHint(p.archiveFormats)
        entry.hintWrap = true
    }
    return true
}

function hasSuffix(lower, suffix) {
    return lower.length >= suffix.length && lower.indexOf(suffix, lower.length - suffix.length) !== -1
}

// The compress submenu's last row after its separator, which opens the password dialog. Hidden where
// 7z is missing, because zip's ZipCrypto is broken encryption and bsdtar writes none at all.
function passwordEntry(formats) {
    var table = formats || []
    if (table.indexOf("7z") < 0) return []
    return [{ separator: true },
        { id: "compressPw", label: "With password…", glyph: "key" }]
}

// Whether 7z is installed, which is what shows the password row above.
function hasSevenZip(formats) {
    return (formats || []).indexOf("7z") >= 0
}

// One whole sentence per count for the compress card's title: the singular names itself and the
// plural fills one template, so no caller joins a fragment.
function compressTitle(count) {
    if (count === 1) return "Compress 1 item"
    return "Compress %1 items".replace("%1", Format.count(count))
}

// The extract card's title from the same template rule.
function encryptedTitle(leaf) {
    return "%1 is encrypted".replace("%1", leaf)
}

// An encrypted archive asks for its password, and a wrong answer asks again: the backend's two
// markers, both codes, never sentences. Exact match, the way "cancelled" already routes.
function needsPassword(err) {
    return String(err) === "encrypted"
}

function wrongPassword(err) {
    return String(err) === "wrong-password"
}

// The card's sentence for a wrong answer: one template filled by one function, so no caller
// joins the leaf onto a fragment.
function wrongPasswordSentence(leaf) {
    return "That password did not open %1.".replace("%1", leaf)
}

// What an extract's terminal line does: "password" opens the extract card, "wrong" reopens it
// with its sentence, and "" messages in the status slot like any write error.
function doneAction(ok, err) {
    if (!ok && needsPassword(err)) return "password"
    if (!ok && wrongPassword(err)) return "wrong"
    return ""
}

// The extract card's title leaf, from the source the first attempt stashed.
function stashedLeaf(source) {
    var path = source && source.path ? String(source.path) : ""
    var cut = path.lastIndexOf("/")
    return cut >= 0 ? path.substring(cut + 1) : path
}
