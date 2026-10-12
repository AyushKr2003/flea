// Extraction tests on synthetic RAWs: a TIFF with one embedded JPEG, and the cache beside it in a sandbox.
use super::*;
use crate::backend::rawexif as ex;
use crate::backend::aliases::Aliases;
use crate::backend::rawtiff::tests::{jpeg, pair, write, Ev, Tb};
use crate::backend::testdir::TestDir;
use crate::backend::thumbcache::{png_text, Cache};
use crate::backend::metareq::read_in;
use crate::backend::thumbs::{input_for, run_one_in, Job, Outcome, Tables};
use crate::backend::thumbspec::Thumbnailers;
use crate::backend::thumbwrite::write_marker;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::sync::Arc;
use std::time::Duration;

// A TIFF whose IFD0 names the JPEG as its JpgFromRaw-style pair, and optionally the turn the camera stored.
fn raw_with(d: &TestDir, name: &str, jpg: &[u8], turn: Option<u32>) -> PathBuf {
    let mut t = Tb::new(true);
    let off = t.blob(jpg);
    let mut entries = pair(off, jpg.len());
    if let Some(o) = turn {
        entries.insert(0, (ex::ORIENTATION, Ev::T(3, o)));
    }
    let ifd0 = t.ifd(entries, 0);
    t.set_ifd0(ifd0);
    write(d, name, &t.b)
}

fn set_mtime(path: &Path, secs: u64) {
    let f = std::fs::OpenOptions::new().write(true).open(path).unwrap();
    f.set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(secs)).unwrap();
}

// The same JPEG with 80 KB of COM segments after SOI, so its bytes run past 64 KiB.
fn padded(base: &[u8]) -> Vec<u8> {
    let mut v = vec![0xFF, 0xD8];
    for _ in 0..2 {
        v.extend_from_slice(&[0xFF, 0xFE, 0x9C, 0x42]);
        v.extend_from_slice(&[0u8; 40000]);
    }
    v.extend_from_slice(&base[2..]);
    v
}

// An Exif JPEG that already names a turn of its own.
fn jpeg_turned(w: u16, h: u16, turn: u16) -> Vec<u8> {
    let mut seg = EXIF_ORIENT;
    seg[EXIF_ORIENT_AT..EXIF_ORIENT_AT + 2].copy_from_slice(&turn.to_le_bytes());
    let base = jpeg(w, h);
    [&base[..2], &seg[..], &base[2..]].concat()
}

#[test]
fn a_raw_extracts_once_per_mtime_and_again_when_it_changes() {
    let d = TestDir::new("rawprev-once");
    let cache = d.join("cache");
    let src = raw_with(&d, "a.cr2", &jpeg(1620, 1080), None);
    set_mtime(&src, 1_700_000_000);
    let first = ensure_in(&cache, &src).expect("a preview");
    assert_eq!((first.width, first.height, first.orientation), (1620, 1080, 1));
    assert_eq!(std::fs::read(&first.file).unwrap(), jpeg(1620, 1080));
    let before = std::fs::metadata(&first.file).unwrap();

    // The same version again walks nothing: the source is now garbage with the old mtime, and the copy is served untouched.
    let kept = src.metadata().unwrap().modified().unwrap();
    std::fs::write(&src, b"not a raw any more").unwrap();
    std::fs::OpenOptions::new().write(true).open(&src).unwrap().set_modified(kept).unwrap();
    let again = ensure_in(&cache, &src).expect("served from the copy");
    assert_eq!((again.width, again.height), (1620, 1080));
    let after = std::fs::metadata(&again.file).unwrap();
    assert_eq!((before.ino(), before.mtime_nsec()), (after.ino(), after.mtime_nsec()), "a fresh copy was rewritten");

    // A changed file extracts again.
    let src = raw_with(&d, "a.cr2", &jpeg(800, 600), None);
    set_mtime(&src, 1_700_000_100);
    let changed = ensure_in(&cache, &src).expect("the new preview");
    assert_eq!((changed.width, changed.height), (800, 600));
    assert_eq!(std::fs::read(&changed.file).unwrap(), jpeg(800, 600));
}

#[test]
fn a_symlink_planted_at_the_cache_path_is_replaced_and_never_written_through() {
    let d = TestDir::new("rawprev-link");
    let cache = d.join("cache");
    let src = raw_with(&d, "b.cr2", &jpeg(640, 480), None);
    set_mtime(&src, 1_700_000_000);
    let victim = d.file("victim.jpg", "keep me");
    set_mtime(&victim, 1_700_000_000);
    std::fs::create_dir(&cache).unwrap();
    std::os::unix::fs::symlink(&victim, copy_path(&cache, &src)).unwrap();
    let got = ensure_in(&cache, &src).expect("a preview");
    assert_eq!(std::fs::read(&victim).unwrap(), b"keep me", "the extraction wrote through the link");
    assert!(!std::fs::symlink_metadata(&got.file).unwrap().file_type().is_symlink());
    assert_eq!(std::fs::read(&got.file).unwrap(), jpeg(640, 480));
}

#[test]
fn the_copy_is_private_and_a_leftover_temp_does_not_survive() {
    let d = TestDir::new("rawprev-mode");
    let cache = d.join("cache").join("flea").join("raw");
    let got = ensure_in(&cache, &raw_with(&d, "c.cr2", &jpeg(640, 480), None)).expect("a preview");
    assert_eq!(std::fs::metadata(&got.file).unwrap().permissions().mode() & 0o777, FILE_MODE);
    assert_eq!(std::fs::metadata(&cache).unwrap().permissions().mode() & 0o777, DIR_MODE);
    assert_eq!(std::fs::read_dir(&cache).unwrap().count(), 1);
}

#[test]
fn the_turn_is_added_only_when_the_jpeg_names_none() {
    let d = TestDir::new("rawprev-turn");
    let cache = d.join("cache");
    let plain = jpeg(1620, 1080);
    let got = ensure_in(&cache, &raw_with(&d, "p.cr2", &plain, Some(6))).expect("a preview");
    assert_eq!(got.orientation, 6);
    let bytes = std::fs::read(&got.file).unwrap();
    assert_eq!(bytes.len(), plain.len() + EXIF_ORIENT.len());
    assert_eq!((&bytes[..2], &bytes[38..]), (&plain[..2], &plain[2..]));

    // The JPEG's own turn wins over the RAW's.
    let own = jpeg_turned(1620, 1080, 8);
    let kept = ensure_in(&cache, &raw_with(&d, "o.cr2", &own, Some(6))).expect("a preview");
    assert_eq!(kept.orientation, 8);
    assert_eq!(std::fs::read(&kept.file).unwrap(), own);

    // No turn in the RAW, or the identity turn, adds nothing.
    for (name, turn) in [("n.cr2", None), ("i.cr2", Some(1))] {
        let got = ensure_in(&cache, &raw_with(&d, name, &plain, turn)).expect("a preview");
        assert_eq!((got.orientation, std::fs::read(&got.file).unwrap()), (1, plain.clone()), "{name}");
    }
}

#[test]
fn a_file_with_no_preview_reports_none_and_writes_nothing() {
    let d = TestDir::new("rawprev-none");
    let cache = d.join("cache");
    let mut t = Tb::new(true);
    let ifd0 = t.ifd(vec![(ex::ORIENTATION, Ev::T(3, 6))], 0);
    t.set_ifd0(ifd0);
    assert!(ensure_in(&cache, &write(&d, "bare.cr2", &t.b)).is_none());
    assert!(ensure_in(&cache, &d.file("note.cr2", "plain text")).is_none());
    assert!(ensure_in(&cache, &d.join("missing.cr2")).is_none());
    assert!(!cache.exists() || std::fs::read_dir(&cache).unwrap().count() == 0);
}

#[test]
fn a_jpgfromraw_past_64_kib_is_copied_whole() {
    let d = TestDir::new("rawprev-rw2");
    let pic = padded(&jpeg(1920, 1080));
    assert!(pic.len() > 65_536);
    let mut t = Tb { b: b"IIU\x00\x08\x00\x00\x00".to_vec(), le: true };
    let ifd0 = t.ifd(vec![(ex::RW2_JPGFROMRAW, Ev::B(7, pic.clone()))], 0);
    t.set_ifd0(ifd0);
    let got = ensure_in(&d.join("cache"), &write(&d, "big.rw2", &t.b)).expect("the preview");
    assert_eq!((got.width, got.height), (1920, 1080));
    assert_eq!(std::fs::read(&got.file).unwrap(), pic);
}

#[test]
fn two_threads_extracting_one_file_both_get_a_whole_copy() {
    let d = TestDir::new("rawprev-race");
    let cache = d.join("cache");
    let pic = padded(&jpeg(1000, 700));
    let src = raw_with(&d, "r.cr2", &pic, None);
    let ends: Vec<_> = (0..4)
        .map(|_| {
            let (cache, src) = (cache.clone(), src.clone());
            std::thread::spawn(move || ensure_in(&cache, &src).map(|e| (e.width, e.height)))
        })
        .collect();
    for end in ends {
        assert_eq!(end.join().unwrap(), Some((1000, 700)));
    }
    assert_eq!(std::fs::read(copy_path(&cache, &src)).unwrap(), pic);
    assert_eq!(std::fs::read_dir(&cache).unwrap().count(), 1, "a temp survived");
}

// A thumbnailer for image/jpeg that fails unless its input starts with the JPEG magic, and then writes the PNG it was given as printf escapes.
fn jpeg_only_thumbnailer(png: &[u8]) -> Thumbnailers {
    let octal: String = png.iter().map(|b| format!(r"\\{:03o}", b)).collect();
    let script = format!(r#"[ \"$(head -c 2 \"$0\" | od -An -tx1 | tr -d ' ')\" = ffd8 ] && printf '{octal}' > \"$1\""#);
    let body = format!("[Thumbnailer Entry]\nTryExec=/bin/sh\nExec=/bin/sh -c \"{script}\" %i %o\nMimeType=image/jpeg;\n");
    Thumbnailers::from_entries(&[("jpeg.thumbnailer".to_string(), body)], &Aliases::from_str(""))
}

fn job(path: &Path, mime: &str) -> Job {
    Job { path: path.to_path_buf(), mtime: 1_700_000_000, mime: mime.to_string(), trace: None }
}

fn tables(d: &TestDir, png: &[u8]) -> Tables {
    let aliases = Arc::new(Aliases::from_str("image/x-panasonic-raw2 image/x-panasonic-rw2\n"));
    Tables { aliases, specs: Arc::new(jpeg_only_thumbnailer(png)), cache: Cache::at(d.join("cache").join("thumbnails")), worker: None }
}

// Where the route puts its copies in a test: inside the sandbox, never the user's cache.
fn raw_dir(d: &TestDir) -> PathBuf {
    d.join("cache").join("flea").join("raw")
}

#[test]
fn the_thumbnailer_of_a_camera_raw_is_handed_the_embedded_jpeg_and_a_jpeg_is_handed_itself() {
    let d = TestDir::new("rawprev-input");
    let png = d.join("one.png");
    write_marker(&png, "file:///x", 0).unwrap();
    let png = std::fs::read(&png).unwrap();
    let t = tables(&d, &png);
    let src = raw_with(&d, "t.rw2", &jpeg(1620, 1080), None);
    let plain = write(&d, "plain.jpg", &jpeg(10, 10));
    let bare = write(&d, "bare.rw2", b"II*\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00");
    let dir = raw_dir(&d);
    let (copy, own, none) = (
        input_for(&t, &job(&src, "image/x-panasonic-raw2"), &dir),
        input_for(&t, &job(&plain, "image/jpeg"), &dir),
        input_for(&t, &job(&bare, "image/x-panasonic-rw2"), &dir),
    );
    let copy = copy.expect("the copy");
    assert_eq!(copy, copy_path(&dir, &src));
    assert_eq!(own, Some(plain));
    assert_eq!(none, None, "a RAW with no preview has nothing to hand over");
    // The spec's own program, run unjailed on that input, writes the PNG only because the input is the JPEG.
    let spec = t.specs.for_mime("image/x-panasonic-raw2", &t.aliases).unwrap();
    let out = d.join("out.png");
    let (_, inner) = crate::backend::thumbargv::argv(spec, &copy, &out, 256).unwrap();
    assert!(std::process::Command::new(&inner[0]).args(&inner[1..]).status().unwrap().success());
    assert_eq!(std::fs::read(&out).unwrap(), png);
    let (_, inner) = crate::backend::thumbargv::argv(spec, &src, &out, 256).unwrap();
    assert!(!std::process::Command::new(&inner[0]).args(&inner[1..]).status().unwrap().success(), "the RAW itself passed the JPEG check");
}

#[test]
fn a_camera_raw_is_thumbnailed_under_its_own_key() {
    if crate::backend::sandboxprobe::skipped() {
        return;
    }
    let d = TestDir::new("rawprev-thumb");
    let png = d.join("one.png");
    write_marker(&png, "file:///x", 0).unwrap();
    let t = tables(&d, &std::fs::read(&png).unwrap());
    let src = raw_with(&d, "t.rw2", &jpeg(1620, 1080), None);
    let bare = write(&d, "bare.rw2", b"II*\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00");
    let dir = raw_dir(&d);
    let (done, none) = (run_one_in(&t, &mut job(&src, "image/x-panasonic-raw2"), &dir), run_one_in(&t, &mut job(&bare, "image/x-panasonic-rw2"), &dir));
    let Outcome::Ready(out) = done else { panic!("the RAW was not thumbnailed") };
    assert_eq!(out, t.cache.large_path(&uri_for(&src)));
    let bytes = std::fs::read(&out).unwrap();
    assert_eq!(png_text(&bytes, "Thumb::URI"), Some(uri_for(&src)));
    assert_eq!(png_text(&bytes, "Thumb::MTime"), Some("1700000000".to_string()));
    assert!(matches!(none, Outcome::Failed));
    assert!(!d.join("cache").join("thumbnails").join("fail").exists(), "a RAW with no preview was recorded as broken");
}

// A RAW whose embedded JPEG is jpeg(w, 100), with its mtime set, so the copy's mtime orders the eviction.
fn aged(d: &TestDir, name: &str, w: u16, secs: u64) -> PathBuf {
    let src = raw_with(d, name, &jpeg(w, 100), None);
    set_mtime(&src, secs);
    src
}

#[test]
fn the_cache_holds_its_count_by_dropping_the_oldest_raw_and_never_the_copy_just_made() {
    let d = TestDir::new("rawprev-evict-count");
    let cache = d.join("cache");
    let (old, mid, new) = (aged(&d, "o.cr2", 100, 1_000), aged(&d, "m.cr2", 200, 2_000), aged(&d, "n.cr2", 300, 3_000));
    for src in [&new, &mid] {
        ensure_bounded(&cache, src, 2, u64::MAX).expect("a preview");
    }
    // The oldest RAW arrives last: it is the copy just made, so it stays and the older of the others goes.
    let got = ensure_bounded(&cache, &old, 2, u64::MAX).expect("a preview");
    assert!(got.file.exists(), "the copy just made was evicted");
    assert!(copy_path(&cache, &new).exists(), "the newest RAW's copy went");
    assert!(!copy_path(&cache, &mid).exists(), "the older RAW's copy stayed over the bound");
    assert_eq!(std::fs::read_dir(&cache).unwrap().count(), 2);
}

#[test]
fn the_cache_holds_its_bytes_and_keeps_a_lone_copy_larger_than_the_bound() {
    let d = TestDir::new("rawprev-evict-bytes");
    let cache = d.join("cache");
    let (a, b) = (aged(&d, "a.cr2", 100, 1_000), aged(&d, "b.cr2", 200, 2_000));
    let first = ensure_bounded(&cache, &a, usize::MAX, 1).expect("a preview");
    assert!(first.file.exists(), "a lone copy over the byte bound was dropped");
    let second = ensure_bounded(&cache, &b, usize::MAX, 1).expect("a preview");
    assert!(second.file.exists() && !first.file.exists(), "the older copy stayed over the byte bound");
}

#[test]
fn a_stale_temp_is_swept_and_a_recent_one_and_a_foreign_file_are_left() {
    let d = TestDir::new("rawprev-evict-temp");
    let cache = d.join("cache");
    std::fs::create_dir_all(&cache).unwrap();
    let stale = d.file("cache/dead.123.0.tmp", "x");
    let recent = d.file("cache/live.124.0.tmp", "x");
    let foreign = d.file("cache/notes.txt", "x");
    set_mtime(&stale, 1_000);
    ensure_bounded(&cache, &aged(&d, "t.cr2", 100, 2_000), 8, u64::MAX).expect("a preview");
    assert!(!stale.exists(), "a dead writer's temp stayed");
    assert!(recent.exists() && foreign.exists(), "a live temp or a foreign file was removed");
}

#[test]
fn a_meta_read_of_a_raw_carries_the_copy_and_leaves_the_files_own_pixels_unknown() {
    let d = TestDir::new("rawprev-meta");
    let cache = raw_dir(&d);
    let src = raw_with(&d, "m.cr2", &jpeg(1620, 1080), Some(6));
    let m = read_in(&src, false, false, None, &cache);
    let raw = m.raw.expect("the copy");
    assert_eq!((raw.width, raw.height, raw.orientation), (1620, 1080, 6));
    assert!(raw.file.starts_with(&cache), "the copy was not written under the directory the read was given");
    assert_eq!((m.width, m.height, m.orientation), (0, 0, 1), "the RAW's own pixels are unknown, the preview's are not its own");
    let plain = write(&d, "p.jpg", &jpeg(10, 10));
    let p = read_in(&plain, false, false, None, &cache);
    assert!(p.raw.is_none() && (p.width, p.height) == (10, 10));
}
