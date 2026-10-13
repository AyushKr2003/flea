// Each value is the literal shell double-quoted text stored in user-dirs.dirs.
var cases = [
    ["escaped quote", '"$HOME/Photo\\"Inbox"', '/home/test/Photo"Inbox'],
    ["escaped backslash", '"$HOME/Photo\\\\Inbox"', '/home/test/Photo\\Inbox'],
    ["escaped dollar", '"$HOME/Photo\\$HOME"', '/home/test/Photo$HOME'],
    ["escaped leading dollar", '"/media/\\$HOME/Inbox"', '/media/$HOME/Inbox'],
    ["escaped backquote", '"$HOME/Photo\\`Inbox"', '/home/test/Photo`Inbox'],
    ["leading HOME token", '"$HOME/Inbox"', '/home/test/Inbox'],
    ["absolute path", '"/media/Inbox"', '/media/Inbox'],
    ["surrounding whitespace", '  "$HOME/Inbox"  ', '/home/test/Inbox'],
    ["unterminated value", '"$HOME/Inbox', null],
    ["dangling escape", '"$HOME/Inbox\\', null],
    ["concatenated quotes", '"$HOME/Photo"Inbox"', null],
    ["trailing content", '"$HOME/Inbox"junk', null],
    ["unsupported escape", '"$HOME/Photo\\q"', null],
    ["unescaped dollar", '"$HOME/Photo$HOME"', null],
    ["unescaped backquote", '"$HOME/Photo`Inbox"', null],
    ["HOME is not a leading token", '"/media/$HOME/Inbox"', null],
    ["HOME token has a suffix", '"$HOMEwork/Inbox"', null],
    ["single-quoted value", "'$HOME/Inbox'", null],
    ["unquoted value", '$HOME/Inbox', null]
]

function body(value) {
    return 'XDG_DOWNLOAD_DIR=' + value + '\nXDG_PICTURES_DIR="$HOME"\nXDG_VIDEOS_DIR="$HOME"'
}
