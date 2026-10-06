use super::*;
use crate::backend::fifotest::{mkfifo, within};
use crate::backend::testdir::TestDir;
use std::cell::Cell;
#[test]
fn the_file_round_trips_the_devices() {
    let key = crate::figurecache::digest(b"k");
    let devices = vec![(0x8086, 0xa788, 1), (0x10de, 0x27e0, 2)];
    assert_eq!(parse(&render(&key, &devices), &key), Some(devices));
}
#[test]
fn bad_files_are_misses() {
    let key = crate::figurecache::digest(b"k");
    let good = render(&key, &[(0x8086, 0xa788, 1)]);
    assert_eq!(parse("", &key), None, "empty");
    assert_eq!(parse(&good.lines().take(2).collect::<Vec<_>>().join("\n"), &key), None, "truncated");
    assert_eq!(parse(&"x".repeat(MAX_FILE_BYTES as usize + 1), &key), None, "oversized");
    assert_eq!(parse(&good.replacen(VERSION, "flea-vulkan-probe 2", 1), &key), None, "wrong version");
    assert_eq!(parse(&good, "other"), None, "wrong key");
    assert_eq!(parse("flea-vulkan-probe 1\n{key}\nnot hex here\n".replace("{key}", &key).as_str(), &key), None, "garbled");
    let error = format!("{VERSION}\n{key}\nerror vkCreateInstance answered -9\n");
    assert_eq!(parse(&error, &key), None, "an error line");
}
#[test]
fn a_hit_returns_the_stored_result_without_calling_the_probe() {
    let t = TestDir::new("vkkey-hit");
    let path = t.join("vulkan-probe");
    let key = crate::figurecache::digest(b"hit");
    let stored = vec![(0x8086, 0xa788, 1)];
    write_cached(&path, &render(&key, &stored));
    let calls = Cell::new(0);
    let probe = || -> ProbeResult { calls.set(calls.get() + 1); Ok(vec![(1, 2, 3)]) };
    let answer = get(Some(key.as_str()), Some(&path), false, &probe);
    assert_eq!(answer, Ok(stored));
    assert_eq!(calls.get(), 0);
}
#[test]
fn a_miss_calls_once_and_writes_the_file() {
    let t = TestDir::new("vkkey-miss");
    let path = t.join("vulkan-probe");
    let key = crate::figurecache::digest(b"miss");
    let calls = Cell::new(0);
    let probe = || -> ProbeResult { calls.set(calls.get() + 1); Ok(vec![(0x8086, 0xa788, 1)]) };
    let answer = get(Some(key.as_str()), Some(&path), false, &probe);
    assert_eq!(calls.get(), 1);
    assert_eq!(read_cached(&path, &key), Some(vec![(0x8086, 0xa788, 1)]));
    assert_eq!(answer, Ok(vec![(0x8086, 0xa788, 1)]));
}
#[test]
fn off_calls_and_writes_nothing() {
    let t = TestDir::new("vkkey-off");
    let path = t.join("vulkan-probe");
    let key = crate::figurecache::digest(b"off");
    let calls = Cell::new(0);
    let probe = || -> ProbeResult { calls.set(calls.get() + 1); Ok(vec![(9, 9, 9)]) };
    let answer = get(Some(key.as_str()), Some(&path), true, &probe);
    assert_eq!(calls.get(), 1);
    assert_eq!(answer, Ok(vec![(9, 9, 9)]));
    assert!(!path.exists());
}
#[test]
fn a_fifo_at_the_cache_path_is_a_miss_that_never_blocks() {
    let t = TestDir::new("vkkey-fifo");
    let path = t.join("vulkan-probe");
    mkfifo(&path);
    let key = crate::figurecache::digest(b"fifo");
    let answer = within("a fifo at the cache path", move || read_cached(&path, &key));
    assert_eq!(answer, None);
}
#[test]
fn an_err_answer_is_probed_every_launch_and_never_written() {
    let t = TestDir::new("vkkey-err");
    let path = t.join("vulkan-probe");
    let key = crate::figurecache::digest(b"err");
    let calls = Cell::new(0);
    let probe = || -> ProbeResult { calls.set(calls.get() + 1); Err(String::from("no loader")) };
    let first = get(Some(key.as_str()), Some(&path), false, &probe);
    assert_eq!(first, Err(String::from("no loader")));
    assert!(!path.exists(), "an Err answer must write no file");
    let _ = get(Some(key.as_str()), Some(&path), false, &probe);
    assert_eq!(calls.get(), 2, "the next get must probe again");
}
#[test]
fn no_key_probes_and_writes_nothing() {
    let t = TestDir::new("vkkey-none");
    let path = t.join("vulkan-probe");
    let calls = Cell::new(0);
    let probe = || -> ProbeResult { calls.set(calls.get() + 1); Ok(vec![(0x8086, 0xa788, 1)]) };
    let answer = get(None, Some(&path), false, &probe);
    assert_eq!(answer, Ok(vec![(0x8086, 0xa788, 1)]));
    assert!(!path.exists(), "no key means no file");
    let _ = get(None, Some(&path), false, &probe);
    assert_eq!(calls.get(), 2, "no key probes every launch");
}
// Trailing blanks keep every prefix of the file parseable, so only the size cap can refuse the oversized one.
#[test]
fn a_file_past_the_size_cap_is_a_miss_even_when_its_lines_are_valid() {
    let t = TestDir::new("vkkey-big");
    let path = t.join("vulkan-probe");
    let key = crate::figurecache::digest(b"big");
    let good = render(&key, &[(0x8086, 0xa788, 1)]);
    std::fs::write(&path, &good).unwrap();
    assert_eq!(read_cached(&path, &key), Some(vec![(0x8086, 0xa788, 1)]), "the same file under the cap");
    let mut big = good.clone();
    big.insert_str(big.len() - 1, &" ".repeat(MAX_FILE_BYTES as usize));
    assert!(big.len() as u64 > MAX_FILE_BYTES);
    std::fs::write(&path, &big).unwrap();
    assert_eq!(read_cached(&path, &key), None);
}
