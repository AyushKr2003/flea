// The write pipeline against plain files and stand-in unpackers.
use super::*;
use crate::backend::flash::{CHUNK_BYTES, CHUNK_COUNT};
use crate::backend::testdir::TestDir;
use std::sync::Mutex;

const IMAGE_BYTES: usize = 5_000_000;
const SMALL_DRIVE_BYTES: u64 = 1_000_000;
const TINY_IMAGE_BYTES: usize = 500_000;
const PIPE_DRIVE_BYTES: u64 = 4_000_000;
// Twelve chunks from a producer, against a pool of four.
const FAST_STREAM_BYTES: usize = 12 * CHUNK_BYTES;
const FAST_DRIVE_BYTES: u64 = 16 * CHUNK_BYTES as u64;
// How long the held writer waits for the reader to run out of buffers; only a broken bound ever waits it out.
const STARVE_WAIT: Duration = Duration::from_secs(10);

fn target(dir: &TestDir, name: &str, bytes: u64) -> std::fs::File {
    let path = dir.join(name);
    let file = std::fs::OpenOptions::new().read(true).write(true).create(true).truncate(true).open(&path).unwrap();
    file.set_len(bytes).unwrap();
    file
}

fn image(dir: &TestDir, name: &str, bytes: usize, seed: u8) -> std::path::PathBuf {
    let path = dir.join(name);
    let body: Vec<u8> = (0..bytes).map(|n| (n % 251) as u8 ^ seed).collect();
    std::fs::write(&path, &body).unwrap();
    path
}

#[test]
fn a_silent_unpacker_ends_decompress_on_a_zero_stall() {
    let d = TestDir::new("flashwrite-stall");
    let src = image(&d, "a.img.xz", 1000, 9);
    let dest = target(&d, "drive.img", PIPE_DRIVE_BYTES);
    let cancel = AtomicBool::new(false);
    let mut job = Job::new(&src, "xz", "", &dest, PIPE_DRIVE_BYTES, &cancel);
    job.stall = Duration::ZERO;
    job.decompressor = Some(vec!["/usr/bin/sleep".to_string(), "60".to_string()]);
    let out = write_stream(&job, &mut |_, _| {});
    assert!(matches!(out, Err(Fail::Decompress(_))), "a silent producer is a stall");
}

#[test]
fn an_image_outgrowing_its_drive_ends_nospace() {
    let d = TestDir::new("flashwrite-nospace");
    let src = image(&d, "a.img", IMAGE_BYTES, 11);
    let dest = target(&d, "drive.img", SMALL_DRIVE_BYTES);
    let cancel = AtomicBool::new(false);
    let out = write_stream(&Job::new(&src, "img", "", &dest, SMALL_DRIVE_BYTES, &cancel), &mut |_, _| {});
    assert!(matches!(out, Err(Fail::NoSpace)));
}

#[test]
fn b11_a_producer_far_ahead_of_the_writer_holds_only_the_pool() {
    let d = TestDir::new("flashwrite-bound");
    let src = image(&d, "a.img.gz", 1000, 13);
    let dest = target(&d, "drive.img", FAST_DRIVE_BYTES);
    let cancel = AtomicBool::new(false);
    let (tell, hear) = std::sync::mpsc::channel::<u64>();
    let tell = Mutex::new(tell);
    let hook = move |read: u64| {
        let _ = tell.lock().map(|t| t.send(read));
    };
    let mut job = Job::new(&src, "gz", "", &dest, FAST_DRIVE_BYTES, &cancel);
    job.decompressor = Some(vec!["/bin/sh".to_string(), "-c".to_string(), format!("head -c {FAST_STREAM_BYTES} /dev/zero")]);
    job.on_starved = Some(&hook);
    // The writer is held in its first progress call until the reader reports it ran out of buffers.
    let mut held_at = None;
    let mut first = true;
    let out = write_stream(&job, &mut |_, _| {
        if std::mem::take(&mut first) {
            held_at = hear.recv_timeout(STARVE_WAIT).ok();
        }
    });
    let (_, written) = out.unwrap_or_else(|f| panic!("the flash failed: {f:?}"));
    assert_eq!(written, FAST_STREAM_BYTES as u64, "the whole stream still lands");
    assert_eq!(held_at, Some((CHUNK_COUNT * CHUNK_BYTES) as u64), "the reader stopped at exactly the pool, with one buffer held by the writer");
}

// A6: a write that fails keeps its cause and the offset it failed at, for the log line flashop prints.
#[test]
fn a6_a_failed_write_carries_its_cause_and_offset() {
    let d = TestDir::new("flashwrite-offset");
    let src = image(&d, "a.img", TINY_IMAGE_BYTES, 3);
    let dest = target(&d, "drive.img", PIPE_DRIVE_BYTES);
    let readonly = std::fs::File::open(d.join("drive.img")).unwrap();
    let cancel = AtomicBool::new(false);
    drop(dest);
    match write_stream(&Job::new(&src, "img", "", &readonly, PIPE_DRIVE_BYTES, &cancel), &mut |_, _| {}) {
        Err(Fail::Io(detail)) => assert!(detail.contains("at offset 0"), "the offset of the first write is named: {detail}"),
        other => panic!("a write to a read-only descriptor must fail io, got {other:?}"),
    }
}
