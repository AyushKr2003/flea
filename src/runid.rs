// The run card's TOCTOU recheck (R3): the ask carries the file's identity, and Run refuses when the file behind the path is no longer the one named.
use std::os::unix::fs::MetadataExt;
use std::path::Path;

#[derive(Debug, PartialEq, Clone, Copy)]
pub struct FileId {
    // dev, ino, size and mtime, the four fields a swap or a retargeted symlink moves.
    pub dev: u64,
    pub ino: u64,
    pub size: u64,
    pub mtime_s: i64,
    pub mtime_ns: i64,
}

// None when the path cannot be stat'ed at all, which the caller refuses fail closed.
pub fn capture(path: &Path) -> Option<FileId> {
    let meta = std::fs::metadata(path).ok()?;
    Some(FileId {
        dev: meta.dev(),
        ino: meta.ino(),
        size: meta.len(),
        mtime_s: meta.mtime(),
        mtime_ns: meta.mtime_nsec(),
    })
}

impl FileId {
    // Every field must still agree; one changed field is a changed file.
    pub fn matches(&self, other: &FileId) -> bool {
        self == other
    }

    // The card's own argv spelling, or None for text that names no identity.
    pub fn parse(dev: &str, ino: &str, size: &str, mtime_s: &str, mtime_ns: &str) -> Option<FileId> {
        Some(FileId {
            dev: dev.parse().ok()?,
            ino: ino.parse().ok()?,
            size: size.parse().ok()?,
            mtime_s: mtime_s.parse().ok()?,
            mtime_ns: mtime_ns.parse().ok()?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::testdir::TestDir;

    #[test]
    fn a_captured_identity_matches_itself_and_nothing_else() {
        let dir = TestDir::new("runid-match");
        let path = dir.path().join("tool.sh");
        std::fs::write(&path, b"#!/bin/sh\ntrue\n").expect("the fixture is written");
        let id = capture(&path).expect("a written file has an identity");
        assert!(id.matches(&id));
        let mut other = id;
        other.size += 1;
        assert!(!id.matches(&other));
        other = id;
        other.ino += 1;
        assert!(!id.matches(&other));
        other = id;
        other.dev += 1;
        assert!(!id.matches(&other));
        other = id;
        other.mtime_ns += 1;
        assert!(!id.matches(&other));
    }

    #[test]
    fn a_missing_file_has_no_identity_and_junk_parses_to_none() {
        let dir = TestDir::new("runid-missing");
        assert_eq!(capture(&dir.path().join("nowhere")), None);
        assert_eq!(FileId::parse("8", "9", "10", "11", "12").map(|id| id.ino), Some(9));
        assert_eq!(FileId::parse("8", "nine", "10", "11", "12"), None);
    }
}
