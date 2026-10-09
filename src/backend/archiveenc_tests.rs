use super::*;

// `7z l -slt` on a content-encrypted .7z, exit 0 (captured on minipc, 7-Zip 26.03).
const CONTENT_ENCRYPTED: &str = "Path = one.7z\nType = 7z\nPhysical Size = 200231\nMethod = LZMA2:18 7zAES\n\n----------\nPath = a.txt\nSize = 5\nPacked Size = 32\nCRC = 5F1E2D3C\nEncrypted = +\nMethod = LZMA2:18 7zAES:19\nBlock = 0\n\nPath = b.bin\nSize = 99\nEncrypted = +\nMethod = LZMA2:18 7zAES:19\n";
// The same listing for a plain archive, exit 0.
const PLAIN: &str = "Path = plain.7z\nType = 7z\nMethod = LZMA2:18\n\n----------\nPath = a.txt\nSize = 5\nEncrypted = -\nMethod = LZMA2:18\n";
// A header-encrypted .7z with stdin closed: exit 255 and no listing at all.
const HEADER_ENCRYPTED: &str = "\nBreak signaled\n\n\nEnter password:";

// The verdict over a whole listing text, the way the streaming scan reads it line by line.
fn listing_encrypted(code: Option<i32>, stdout: &str) -> bool {
    verdict(code, stdout.lines().any(encrypted_key))
}

#[test]
fn a_header_encrypted_archive_is_told_by_the_break_exit() {
    assert!(listing_encrypted(Some(255), HEADER_ENCRYPTED));
    assert!(listing_encrypted(Some(255), ""), "the words are never read, so an empty stdout answers the same");
}

#[test]
fn encrypted_entries_are_told_by_their_technical_key() {
    assert!(listing_encrypted(Some(0), CONTENT_ENCRYPTED));
    assert!(listing_encrypted(Some(0), "Path = a\r\nEncrypted = +\r\n"), "a CRLF listing reads the same");
}

#[test]
fn a_plain_archive_is_never_encrypted() {
    assert!(!listing_encrypted(Some(0), PLAIN));
    assert!(!listing_encrypted(Some(0), ""));
}

// A key past the piece bound is one long line, not a key line; scan() joins pieces first.
#[test]
fn a_key_split_past_the_piece_bound_is_not_a_key_line() {
    let mut name = "y".repeat(LINE_MAX as usize - "Path = ".len());
    name.push_str("Encrypted = +");
    assert!(!scan(std::io::Cursor::new(format!("Path = {}\n", name))));
    assert!(scan(std::io::Cursor::new("Path = a\r\nEncrypted = +\r\n")));
    assert!(scan(std::io::Cursor::new("Path = a\nEncrypted = +")), "a last line with no newline still counts");
}

// The tail of a line past LINE_LIMIT is drained, never read as a fresh line, and the next whole line still counts.
#[test]
fn the_tail_of_a_line_past_the_limit_is_never_a_key_line() {
    let long = format!("Path = {}Encrypted = +\n", "y".repeat(LINE_LIMIT as usize - "Path = ".len()));
    assert!(!scan(std::io::Cursor::new(long.clone())));
    assert!(scan(std::io::Cursor::new(format!("{long}Encrypted = +\n"))), "the whole line after the drained one is read");
}

// A member named like the key is a Path value, and a failed listing proves nothing.
#[test]
fn only_a_key_line_on_a_clean_listing_counts() {
    assert!(!listing_encrypted(Some(0), "Path = Encrypted = +\nEncrypted = -\n"));
    assert!(!listing_encrypted(Some(2), CONTENT_ENCRYPTED), "a corrupt archive is not an encrypted one");
    assert!(!listing_encrypted(None, CONTENT_ENCRYPTED), "a killed probe proves nothing");
}
