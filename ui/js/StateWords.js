.pragma library

.import "Format.js" as Format

// The state word an errored menu row says in its hint slot, beside the red label (MenuAdditions040).
// One table, keyed by trigger: a word is a fixed value here, never a provider's reason passed through.
var WORDS = {
    taildropFolder: "files only",
    taildropSignedOut: "signed out",
    taildropNoPeers: "no devices",
    taildropDown: "offline",
    localsendFolder: "files only",
    localsendNoPeers: "no devices",
    dropboxSignedOut: "signed out",
    dropboxDown: "not running",
    permissionsLink: "symlink",
    permissionsSpecial: "special file",
    permissionsNotYours: "not yours"
}

function isFolder(mode) { return ((Number(mode) || 0) & Format.S_IFMT) === Format.S_IFDIR }

// Sample input: { rowMode: 0o040755, taildropCode: "" }, or { rowMode: 0o100644, taildropCode: "signedOut" }; codes are ui/js/Taildrop.js status().
function taildrop(p) {
    if (isFolder(p.rowMode)) return WORDS.taildropFolder
    if (p.taildropCode === "signedOut") return WORDS.taildropSignedOut
    return p.taildropCode === "noPeers" ? WORDS.taildropNoPeers : WORDS.taildropDown
}

// Sample input: { rowMode: 0o040755 }. The send finds nobody on the network for any other cause.
function localsend(p) {
    return isFolder(p.rowMode) ? WORDS.localsendFolder : WORDS.localsendNoPeers
}

// Sample input: { dropboxCode: "signedOut" }; codes are ui/js/Dropbox.js account() and status().
function dropbox(p) {
    return p.dropboxCode === "signedOut" ? WORDS.dropboxSignedOut : WORDS.dropboxDown
}

// A link names itself; any other kind that is neither a file nor a folder, or no readable mode at all, is special.
function permissions(mode) {
    return ((Number(mode) || 0) & Format.S_IFMT) === Format.S_IFLNK ? WORDS.permissionsLink : WORDS.permissionsSpecial
}
