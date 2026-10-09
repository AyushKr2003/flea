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
    Some(id_of(&meta))
}

fn id_of(meta: &std::fs::Metadata) -> FileId {
    FileId {
        dev: meta.dev(),
        ino: meta.ino(),
        size: meta.len(),
        mtime_s: meta.mtime(),
        mtime_ns: meta.mtime_nsec(),
    }
}

// The kind and the identity off one open file description, so a swap between the head read and the identity stat cannot pair two files (R3); the FileId still follows symlinks, because File::open resolves them the way metadata does.
pub struct Opened {
    pub id: FileId,
    pub head: Vec<u8>,
    pub mode: u32,
    pub uid: u32,
    pub gid: u32,
}

// The first HEAD_LEN bytes the classifier reads off the same description.
pub const HEAD_LEN: usize = 4096;

// The caller's own execute bits, the way access(X_OK) reads them.
const S_IXUSR: u32 = 0o100;
const S_IXGRP: u32 = 0o010;
const S_IXOTH: u32 = 0o001;

// True when the caller's own execute bit is set on an opened file: owner, else group, else other, with root taking any bit rather than checking ownership.
pub fn executable_by_caller(opened: &Opened) -> bool {
    if caller_uid() == 0 {
        return opened.mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0;
    }
    if caller_uid() == opened.uid {
        return opened.mode & S_IXUSR != 0;
    }
    if caller_gid() == opened.gid || caller_groups().contains(&opened.gid) {
        return opened.mode & S_IXGRP != 0;
    }
    opened.mode & S_IXOTH != 0
}

extern "C" {
    fn geteuid() -> u32;
    fn getegid() -> u32;
    fn getgroups(size: std::os::raw::c_int, list: *mut u32) -> std::os::raw::c_int;
}

fn caller_uid() -> u32 {
    unsafe { geteuid() }
}

fn caller_gid() -> u32 {
    unsafe { getegid() }
}

// The supplementary groups beside the effective one, empty when the list cannot be read.
fn caller_groups() -> Vec<u32> {
    let count = unsafe { getgroups(0, std::ptr::null_mut()) };
    if count <= 0 {
        return Vec::new();
    }
    let mut groups = vec![0u32; count as usize];
    let got = unsafe { getgroups(count, groups.as_mut_ptr()) };
    if got < 0 {
        return Vec::new();
    }
    groups.truncate(got as usize);
    groups
}

// One open, one fstat and one head read off the same description; None when the path cannot be opened at all, which every caller refuses fail closed.
pub fn snapshot(path: &Path) -> Option<Opened> {
    use std::io::Read;
    use std::os::unix::fs::OpenOptionsExt;
    // A FIFO or device is judged by stat and never opened; the open is nonblocking and its own fstat catches a later swap.
    if !std::fs::metadata(path).is_ok_and(|m| m.file_type().is_file()) {
        return None;
    }
    let mut file = std::fs::OpenOptions::new().read(true).custom_flags(crate::oflags::O_NONBLOCK).open(path).ok()?;
    let meta = file.metadata().ok()?;
    if !meta.file_type().is_file() {
        return None;
    }
    let mut head = Vec::new();
    file.by_ref().take(HEAD_LEN as u64).read_to_end(&mut head).ok()?;
    Some(Opened { id: id_of(&meta), head, mode: meta.mode(), uid: meta.uid(), gid: meta.gid() })
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

    #[test]
    fn snapshot_never_opens_a_fifo() {
        use std::os::unix::fs::OpenOptionsExt;
        use std::time::Duration;
        let dir = TestDir::new("runid-fifo");
        let fifo = dir.path().join("pipe");
        assert!(std::process::Command::new("mkfifo").arg(&fifo).status().expect("mkfifo starts").success());
        // A writer blocks opening until some reader opens the fifo, so it stays blocked only if the snapshot never opened it.
        let (tx, rx) = std::sync::mpsc::channel();
        let writer_path = fifo.clone();
        let writer = std::thread::spawn(move || {
            let opened = std::fs::OpenOptions::new().write(true).open(&writer_path);
            tx.send(()).expect("the writer reports");
            opened
        });
        std::thread::sleep(Duration::from_millis(300));
        assert!(snapshot(&fifo).is_none(), "a fifo snapshots");
        assert!(rx.recv_timeout(Duration::from_millis(500)).is_err(), "snapshot opened the fifo and released its writer");
        let reader = std::fs::OpenOptions::new().read(true).custom_flags(crate::oflags::O_NONBLOCK).open(&fifo);
        assert!(reader.is_ok(), "the test's own reader releases the writer");
        assert!(writer.join().expect("the writer joins").is_ok(), "the writer opened once a reader came");
    }
}
