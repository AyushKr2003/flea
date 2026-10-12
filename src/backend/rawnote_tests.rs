// MakerNote fixtures in the vendors' own layouts (Nikon, Olympus new and old, Pentax), and notes the walk must skip without entering.
use super::*;
use crate::backend::rawexif as ex;
use crate::backend::rawtiff::inspect_file;
use crate::backend::rawtiff::tests::{at, jpeg, patch, write, Ev, Log, Tb, PLACE};
use crate::backend::rawembed::Ctx;
use crate::backend::testdir::TestDir;

fn order_bytes(le: bool) -> &'static [u8] {
    if le {
        b"II"
    } else {
        b"MM"
    }
}

// One IFD of LONG tags then a zero next pointer; the values are written as given, so a placeholder survives for patching.
fn ifd_of(le: bool, entries: &[(u16, u32)]) -> Vec<u8> {
    let w16 = |v: u16| if le { v.to_le_bytes() } else { v.to_be_bytes() };
    let w32 = |v: u32| if le { v.to_le_bytes() } else { v.to_be_bytes() };
    let mut b = w16(entries.len() as u16).to_vec();
    for &(tag, value) in entries {
        b.extend_from_slice(&w16(tag));
        b.extend_from_slice(&w16(4));
        b.extend_from_slice(&w32(1));
        b.extend_from_slice(&w32(value));
    }
    b.extend_from_slice(&w32(0));
    b
}

// Sample input: "Nikon\0" 02 10 00 00, then "MM\0*" and the IFD offset 8 at +10, then the IFD; offsets count from that header.
pub(crate) fn nikon_note(le: bool, entries: &[(u16, u32)]) -> Vec<u8> {
    let mut b = b"Nikon\x00\x02\x10\x00\x00".to_vec();
    b.extend_from_slice(order_bytes(le));
    b.extend_from_slice(&if le { 42u16.to_le_bytes() } else { 42u16.to_be_bytes() });
    b.extend_from_slice(&if le { 8u32.to_le_bytes() } else { 8u32.to_be_bytes() });
    b.extend_from_slice(&ifd_of(le, entries));
    b
}

// Sample input: "OLYMPUS\0" "II" 03 00, then the IFD at +12; offsets count from the note's start.
fn olympus_note(le: bool, entries: &[(u16, u32)]) -> Vec<u8> {
    let mut b = b"OLYMPUS\x00".to_vec();
    b.extend_from_slice(order_bytes(le));
    b.extend_from_slice(&[0x03, 0x00]);
    b.extend_from_slice(&ifd_of(le, entries));
    b
}

// Sample input: "OLYMP\0" 01 00, then the IFD at +8 in the file's byte order; offsets count from the file.
fn olymp_note(le: bool, entries: &[(u16, u32)]) -> Vec<u8> {
    let mut b = b"OLYMP\x00\x01\x00".to_vec();
    b.extend_from_slice(&ifd_of(le, entries));
    b
}

// Sample input: "AOC\0" "MM", then the IFD at +6; offsets count from the file.
pub(crate) fn aoc_note(le: bool, entries: &[(u16, u32)]) -> Vec<u8> {
    let mut b = b"AOC\x00".to_vec();
    b.extend_from_slice(order_bytes(le));
    b.extend_from_slice(&ifd_of(le, entries));
    b
}

// A TIFF whose IFD0 holds the note, with the JPEG after it; the note's placeholder becomes offset(note start, JPEG start).
fn with_note(le: bool, note_le: bool, note: &[u8], pic: &[u8], offset: impl Fn(u64, u64) -> u64) -> (Vec<u8>, u64) {
    let mut t = Tb::new(le);
    let ifd0 = t.ifd(vec![(ex::MAKER_NOTE, Ev::B(7, note.to_vec()))], 0);
    t.set_ifd0(ifd0);
    let jb = t.blob(pic) as u64;
    let note_at = at(&t.b, &note[..8]);
    patch(&mut t.b, note_le, offset(note_at, jb) as u32);
    (t.b, jb)
}

fn candidates(d: &TestDir, name: &str, bytes: &[u8]) -> Vec<(u64, u64)> {
    let p = write(d, name, bytes);
    inspect_file(&mut Ctx::open(&p).expect("opens")).expect("walks").0
}

#[test]
fn a_nikon_type_3_note_has_its_tiff_header_at_plus_10() {
    let d = TestDir::new("rawnikon");
    let pic = jpeg(500, 400);
    for le in [true, false] {
        let note = nikon_note(le, &[(ex::JPEG_OFF, PLACE), (ex::JPEG_LEN, pic.len() as u32)]);
        let (bytes, jb) = with_note(le, le, &note, &pic, |n, jb| jb - (n + 10));
        assert_eq!(candidates(&d, "a.nef", &bytes), vec![(jb, pic.len() as u64)], "little-endian {}", le);
    }
}

#[test]
fn a_new_olympus_note_counts_its_offsets_from_its_own_start() {
    let d = TestDir::new("rawolynew");
    let pic = jpeg(300, 220);
    // The note's byte order may differ from the file's, since it names its own.
    for (file_le, note_le) in [(true, true), (true, false), (false, true)] {
        let note = olympus_note(note_le, &[(ex::OLY_PREVIEW_START, PLACE), (ex::OLY_PREVIEW_LEN, pic.len() as u32)]);
        let (bytes, jb) = with_note(file_le, note_le, &note, &pic, |n, jb| jb - n);
        assert_eq!(candidates(&d, "a.orf", &bytes), vec![(jb, pic.len() as u64)], "file {} note {}", file_le, note_le);
    }
}

#[test]
fn an_old_olymp_note_counts_its_offsets_from_the_file() {
    let d = TestDir::new("rawolyold");
    let pic = jpeg(300, 220);
    for le in [true, false] {
        let note = olymp_note(le, &[(ex::OLY_PREVIEW_START, PLACE), (ex::OLY_PREVIEW_LEN, pic.len() as u32)]);
        let (bytes, jb) = with_note(le, le, &note, &pic, |_, jb| jb);
        assert_eq!(candidates(&d, "a.orf", &bytes), vec![(jb, pic.len() as u64)], "little-endian {}", le);
    }
}

#[test]
fn a_pentax_aoc_note_names_its_byte_order_and_counts_from_the_file() {
    let d = TestDir::new("rawaoc");
    let pic = jpeg(160, 120);
    for (file_le, note_le) in [(false, false), (true, true), (true, false)] {
        let note = aoc_note(note_le, &[(ex::JPEG_OFF, PLACE), (ex::JPEG_LEN, pic.len() as u32)]);
        let (bytes, jb) = with_note(file_le, note_le, &note, &pic, |_, jb| jb);
        assert_eq!(candidates(&d, "a.pef", &bytes), vec![(jb, pic.len() as u64)], "file {} note {}", file_le, note_le);
    }
}

// Offers the note at `at` with `total` bytes to the walk, answering every read it made and what it collected.
fn offer(data: &[u8], at: u64, total: u32) -> (Vec<(u64, usize)>, Vec<(u64, u64)>) {
    let mut src = Log { data, reads: Vec::new() };
    let mut w = Walk::new();
    let loc = IfdLoc { base: 0, little_endian: true, depth: 0, in_sub_ifd: false, index_in_chain: 0, is_exif: false, olympus_base: None };
    let _ = makernote(&mut src, &mut w, &loc, 7, total, &(at as u32).to_le_bytes());
    (src.reads, w.cands)
}

// The note's bytes then filler that would form a walkable IFD, so a read past the value would not simply fail.
fn after(note: &[u8]) -> Vec<u8> {
    let mut data = note.to_vec();
    data.extend_from_slice(&ifd_of(true, &[(ex::JPEG_OFF, 0), (ex::JPEG_LEN, 64)]));
    data.resize(data.len() + 64, 0);
    data
}

#[test]
fn a_note_is_skipped_after_one_signature_read_or_none() {
    // Too short for any header: no read at all.
    let short = after(b"Nikon\x00\x02");
    assert!(offer(&short, 0, 7).0.is_empty(), "7 bytes is skipped before a read");
    // No known signature: the signature window is read once and the note is not entered.
    let junk = after(b"PENTAXFAKE-not-a-tiff-header!!");
    assert_eq!(offer(&junk, 0, 30).0, vec![(0, 30)]);
    // The control: a whole note reads past its signature, so the log tells entering from skipping.
    let whole = nikon_note(true, &[(ex::JPEG_OFF, 0), (ex::JPEG_LEN, 64)]);
    assert!(offer(&whole, 0, whole.len() as u32).0.len() > 1, "an entered note reads its TIFF header and IFD");
}

#[test]
fn a_note_cut_inside_its_header_is_never_read_past_its_value() {
    // Nikon cut in the middle of its TIFF header: 14 of the 18 bytes the header and its first count need.
    let nikon = after(&nikon_note(true, &[(ex::JPEG_OFF, 0), (ex::JPEG_LEN, 64)])[..14]);
    assert_eq!(offer(&nikon, 0, 14), (vec![(0, 14)], vec![]));
    // Olympus cut after its byte order and version: the IFD count at +12 lies outside the note.
    let olympus = after(&olympus_note(true, &[(ex::OLY_PREVIEW_START, 0), (ex::OLY_PREVIEW_LEN, 64)])[..12]);
    assert_eq!(offer(&olympus, 0, 12), (vec![(0, 12)], vec![]));
    // Pentax with no byte order after its signature is not a note this walk knows.
    let aoc = after(b"AOC\x00\x00\x00\x00\x00\x00\x00\x00\x00");
    assert_eq!(offer(&aoc, 0, 12), (vec![(0, 12)], vec![]));
}

#[test]
fn a_skipped_note_is_not_a_failure() {
    let d = TestDir::new("rawnoteskip");
    let mut t = Tb::new(true);
    let ifd0 = t.ifd(vec![(ex::MAKER_NOTE, Ev::B(7, b"PENTAXFAKE-not-a-tiff-header!!".to_vec()))], 0);
    t.set_ifd0(ifd0);
    assert!(candidates(&d, "a.pef", &t.b).is_empty());
}
