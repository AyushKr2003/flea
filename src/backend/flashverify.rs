// The verify pass, the tail and the wipe; TECH.md sections 5 and 6 beside the write loop.
use crate::backend::flash::{CHUNK_BYTES, WIPE_BYTES};
use crate::backend::flashwrite::{full_pread, full_pwrite, Fail};
use std::os::fd::AsRawFd;
use std::os::raw::c_int;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::channel;

// fcntl commands, declared here rather than taking a crate.
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_DIRECT: c_int = 0o40000;
// The logical block size O_DIRECT writes move in; a shorter tail goes buffered.
const BLOCK_BYTES: usize = 512;
extern "C" {
    fn fcntl(fd: c_int, cmd: c_int, arg: c_int) -> c_int;
    fn fsync(fd: c_int) -> c_int;
}

// True for the block descriptor the helper hands back, false for a test's regular file.
fn is_block(file: &std::fs::File) -> bool {
    use std::os::unix::fs::FileTypeExt;
    file.metadata().map(|m| m.file_type().is_block_device()).unwrap_or(false)
}

// The O_DIRECT flag without touching any other status flag.
fn direct_on(file: &std::fs::File) -> bool {
    unsafe { fcntl(file.as_raw_fd(), F_GETFL, 0) & O_DIRECT != 0 }
}

// Only ever called on a block descriptor; a regular file keeps whatever flags it opened with.
fn set_direct(file: &std::fs::File, on: bool) {
    if !is_block(file) {
        return;
    }
    let flags = unsafe { fcntl(file.as_raw_fd(), F_GETFL, 0) };
    let next = if on { flags | O_DIRECT } else { flags & !O_DIRECT };
    if next != flags {
        unsafe { fcntl(file.as_raw_fd(), F_SETFL, next) };
    }
}

// Reads every written byte back from the drive and compares each chunk's XXH64 with the table;
// total is the written count, so the last chunk is read at its written length and not a full 4 MiB.
pub fn verify(dest: &std::fs::File, table: &[u64], total: u64, cancel: &AtomicBool, on_progress: &mut dyn FnMut(u64)) -> Result<(), Fail> {
    verify_at(dest, table, total, cancel, on_progress).map(|_| ())
}

fn verify_at(dest: &std::fs::File, table: &[u64], total: u64, cancel: &AtomicBool, on_progress: &mut dyn FnMut(u64)) -> Result<u64, Fail> {
    let fd = dest.as_raw_fd();
    let (work_tx, work_rx) = channel::<(usize, Vec<u8>)>();
    // Receiver is not Sync, so the two hashing threads share it behind a lock, as the pool does.
    let work_rx = std::sync::Mutex::new(work_rx);
    let (done_tx, done_rx) = channel::<(usize, u64)>();
    std::thread::scope(|scope| {
        for _ in 0..2 {
            let work_rx = &work_rx;
            let done_tx = done_tx.clone();
            scope.spawn(move || {
                loop {
                    let next = work_rx.lock().map(|guard| guard.recv().ok()).unwrap_or(None);
                    match next {
                        Some((index, bytes)) => {
                            let digest = crate::backend::xxh64::hash(&bytes);
                            if done_tx.send((index, digest)).is_err() {
                                return;
                            }
                        }
                        None => return,
                    }
                }
            });
        }
        drop(done_tx);
        let mut buf = super::flashwrite::chunk_buf();
        let mut pending: std::collections::HashMap<usize, u64> = std::collections::HashMap::new();
        let mut next = 0;
        let mut read_bytes: u64 = 0;
        for (index, want) in table.iter().enumerate() {
            if cancel.load(Ordering::Relaxed) {
                return Err(Fail::Cancelled);
            }
            // The last chunk is as long as the write left it, so no zero tail past it is hashed in.
            let want_len = (total - read_bytes).min(CHUNK_BYTES as u64) as usize;
            if want_len == 0 {
                return Err(Fail::Io("the drive ended before the image".to_string()));
            }
            let n = full_pread(fd, &mut buf[..want_len], read_bytes).map_err(|e| Fail::Io(e.to_string()))?;
            if n != want_len {
                return Err(Fail::Io("the drive ended before the image".to_string()));
            }
            work_tx.send((index, buf[..n].to_vec())).map_err(|_| Fail::Io("the hash workers went away".to_string()))?;
            read_bytes += n as u64;
            on_progress(read_bytes);
            while let Ok((got, digest)) = done_rx.try_recv() {
                pending.insert(got, digest);
            }
            while pending.contains_key(&next) {
                let digest = pending.remove(&next).unwrap_or(0);
                if digest != table[next] {
                    return Err(Fail::Io(format!("mismatch:{}", next * CHUNK_BYTES)));
                }
                next += 1;
            }
            let _ = want;
        }
        drop(work_tx);
        while next < table.len() {
            let (got, digest) = done_rx.recv().map_err(|_| Fail::Io("the hash workers went away".to_string()))?;
            pending.insert(got, digest);
            while pending.contains_key(&next) {
                let digest = pending.remove(&next).unwrap_or(0);
                if digest != table[next] {
                    return Err(Fail::Io(format!("mismatch:{}", next * CHUNK_BYTES)));
                }
                next += 1;
            }
        }
        Ok(read_bytes)
    })
}

// Zeroes the first and last MiB and flushes, so a cancelled flash reads as blank, never half bootable.
pub fn wipe_ends(dest: &std::fs::File, drive_bytes: u64) -> bool {
    let fd = dest.as_raw_fd();
    let zeros = vec![0u8; WIPE_BYTES as usize];
    let first = WIPE_BYTES.min(drive_bytes);
    let last_start = drive_bytes.saturating_sub(WIPE_BYTES);
    if full_pwrite(fd, &zeros[..first as usize], 0).is_err() {
        return false;
    }
    if full_pwrite(fd, &zeros[..(drive_bytes - last_start) as usize], last_start).is_err() {
        return false;
    }
    unsafe { fsync(fd) == 0 }
}

// The tail shorter than a block cannot go through O_DIRECT; only a block descriptor takes this path.
pub fn write_tail(dest: &std::fs::File, buf: &[u8], offset: u64) -> std::io::Result<()> {
    let was = direct_on(dest);
    if is_block(dest) && !buf.is_empty() && buf.len() % BLOCK_BYTES != 0 {
        set_direct(dest, false);
        let out = full_pwrite(dest.as_raw_fd(), buf, offset);
        set_direct(dest, was);
        return out;
    }
    full_pwrite(dest.as_raw_fd(), buf, offset)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::testdir::TestDir;

    fn target(dir: &TestDir, name: &str, bytes: usize) -> std::fs::File {
        let path = dir.join(name);
        let file = std::fs::OpenOptions::new().read(true).write(true).create(true).truncate(true).open(&path).unwrap();
        file.set_len(bytes as u64).unwrap();
        file
    }

    fn image(dir: &TestDir, name: &str, bytes: usize, seed: u8) -> std::path::PathBuf {
        let path = dir.join(name);
        let body: Vec<u8> = (0..bytes).map(|n| (n % 251) as u8 ^ seed).collect();
        std::fs::write(&path, &body).unwrap();
        path
    }

    #[test]
    fn a_write_then_verify_round_trips_against_a_file() {
        let d = TestDir::new("flashverify-roundtrip");
        let src = image(&d, "a.img", 9_000_000, 3);
        let dest = target(&d, "drive.img", 16_000_000);
        let cancel = AtomicBool::new(false);
        let mut seen = 0;
        let (table, written) = super::super::flashwrite::write_stream(&super::super::flashwrite::Job { image: &src, kind: "img", member: "", dest: &dest, drive_bytes: 16_000_000, cancel: &cancel, stall: super::super::flashwrite::stall_limit() }, &mut |_, _| seen += 1).unwrap();
        assert_eq!((table.len(), written), (3, 9_000_000), "9 MiB over 4 MiB chunks is three digests");
        assert!(seen > 0);
        verify(&dest, &table, written, &cancel, &mut |_| {}).unwrap();
    }

    #[test]
    fn a_byte_flipped_between_write_and_verify_fails_at_its_chunk() {
        let d = TestDir::new("flashverify-verifyhook");
        let src = image(&d, "a.img", 9_000_000, 5);
        let dest = target(&d, "drive.img", 16_000_000);
        let cancel = AtomicBool::new(false);
        let (table, written) = super::super::flashwrite::write_stream(&super::super::flashwrite::Job { image: &src, kind: "img", member: "", dest: &dest, drive_bytes: 16_000_000, cancel: &cancel, stall: super::super::flashwrite::stall_limit() }, &mut |_, _| {}).unwrap();
        {
            use std::io::{Seek, SeekFrom, Write};
            let mut raw = std::fs::OpenOptions::new().write(true).open(d.join("drive.img")).unwrap();
            raw.seek(SeekFrom::Start(super::super::flash::CHUNK_BYTES as u64 + 10)).unwrap();
            raw.write_all(&[0xFF]).unwrap();
        }
        let err = verify(&dest, &table, written, &cancel, &mut |_| {}).unwrap_err();
        match err {
            Fail::Io(msg) => assert_eq!(msg, format!("mismatch:{}", super::super::flash::CHUNK_BYTES)),
            other => panic!("a flipped byte must fail verify, got {:?}", std::mem::discriminant(&other)),
        }
    }

    #[test]
    fn a_cancel_mid_write_leaves_both_ends_zero() {
        let d = TestDir::new("flashverify-cancel");
        let src = image(&d, "a.img", 12_000_000, 7);
        let dest = target(&d, "drive.img", 12_000_000);
        let cancel = AtomicBool::new(false);
        let mut calls = 0;
        let out = super::super::flashwrite::write_stream(&super::super::flashwrite::Job { image: &src, kind: "img", member: "", dest: &dest, drive_bytes: 12_000_000, cancel: &cancel, stall: super::super::flashwrite::stall_limit() }, &mut |_, _| {
            calls += 1;
            if calls == 1 {
                cancel.store(true, Ordering::Relaxed);
            }
        });
        assert!(matches!(out, Err(Fail::Cancelled)));
        assert!(wipe_ends(&dest, 12_000_000));
        let body = std::fs::read(d.join("drive.img")).unwrap();
        assert!(body[..WIPE_BYTES as usize].iter().all(|b| *b == 0), "the first MiB is zero");
        assert!(body[body.len() - WIPE_BYTES as usize..].iter().all(|b| *b == 0), "the last MiB is zero");
    }


    #[test]
    fn direct_stays_off_on_a_regular_file() {
        let d = TestDir::new("flashverify-direct");
        let dest = target(&d, "drive.img", 4096);
        assert!(!is_block(&dest));
        set_direct(&dest, false);
        assert!(!direct_on(&dest));
        write_tail(&dest, &[1u8; 100], 0).unwrap();
    }
}
