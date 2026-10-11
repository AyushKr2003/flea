// Dispatcher and choice tests: extension matching, format routing, the largest-valid
// rule with its tie-break, and the hostile shapes the brief names, proved end to end.
use super::*;
use crate::backend::rawexif as ex;
use crate::backend::testdir::TestDir;

fn jpeg(w: u16, h: u16) -> Vec<u8> {
    let mut v = vec![0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x08, 1, 2, 3, 4, 5, 6];
    v.extend_from_slice(&[0xFF, 0xC0, 0x00, 0x0B, 0x08]);
    v.extend_from_slice(&h.to_be_bytes());
    v.extend_from_slice(&w.to_be_bytes());
    v.extend_from_slice(&[0x01, 0x01, 0x22, 0x00, 0xFF, 0xD9]);
    v
}

// A TIFF chaining one IFD per JPEG pair: header(8) + 4 IFDs (30 bytes each) + blobs.
// Each pair lives in its own IFD because one IFD holds one pair, not four.
fn tiff_chain(blobs: &[&[u8]]) -> Vec<u8> {
    let mut b = b"II*\x00".to_vec();
    b.extend_from_slice(&8u32.to_le_bytes());
    let mut offs = Vec::new();
    let mut at = 8u32;
    for i in 0..blobs.len() {
        let next = if i + 1 < blobs.len() { at + 30 } else { 0 };
        b.extend_from_slice(&2u16.to_le_bytes());
        for tag in [0x0201u16, 0x0202] {
            b.extend_from_slice(&tag.to_le_bytes());
            b.extend_from_slice(&4u16.to_le_bytes());
            b.extend_from_slice(&1u32.to_le_bytes());
            offs.push(b.len());
            b.extend_from_slice(&0u32.to_le_bytes());
        }
        b.extend_from_slice(&next.to_le_bytes());
        at = next;
    }
    let mut base = b.len() as u32;
    for (i, blob) in blobs.iter().enumerate() {
        b[offs[2 * i]..offs[2 * i] + 4].copy_from_slice(&base.to_le_bytes());
        b[offs[2 * i + 1]..offs[2 * i + 1] + 4].copy_from_slice(&(blob.len() as u32).to_le_bytes());
        base += blob.len() as u32;
    }
    for blob in blobs {
        b.extend_from_slice(blob);
    }
    b
}

// A TIFF with a single JPEG pair in IFD0: 8 + 2 + 24 + 4 = 38 bytes before the blob.
pub(super) fn tiff_one(off: u32, len: u32) -> Vec<u8> {
    let mut b = b"II*\x00".to_vec();
    b.extend_from_slice(&8u32.to_le_bytes());
    b.extend_from_slice(&2u16.to_le_bytes());
    for (tag, v) in [(0x0201u16, off), (0x0202, len)] {
        b.extend_from_slice(&tag.to_le_bytes());
        b.extend_from_slice(&4u16.to_le_bytes());
        b.extend_from_slice(&1u32.to_le_bytes());
        b.extend_from_slice(&v.to_le_bytes());
    }
    b.extend_from_slice(&0u32.to_le_bytes());
    b
}

fn write(d: &TestDir, name: &str, bytes: &[u8]) -> std::path::PathBuf {
    let p = d.join(name);
    std::fs::write(&p, bytes).unwrap();
    p
}

// A baseline JPEG buried behind segs 60 KiB APP1 segments, so one validation walks ~segs*60 KiB.
pub(super) fn fat_jpeg(w: u16, h: u16, segs: usize) -> Vec<u8> {
    let mut v = vec![0xFF, 0xD8];
    for _ in 0..segs {
        v.extend_from_slice(&[0xFF, 0xE1]);
        v.extend_from_slice(&60002u16.to_be_bytes());
        v.extend_from_slice(&vec![0u8; 60000]);
    }
    v.extend_from_slice(&[0xFF, 0xC0, 0x00, 0x0B, 0x08]);
    v.extend_from_slice(&h.to_be_bytes());
    v.extend_from_slice(&w.to_be_bytes());
    v.extend_from_slice(&[0x01, 0x01, 0x22, 0x00, 0xFF, 0xD9]);
    v
}

#[test]
fn sof_validation_stops_when_the_mib_is_spent() {    let d = TestDir::new("rawsofbudget");
    // Five mediums walk ~240 KiB each past the 1 MiB budget; the huge one riding last is
    // never validated, so a medium wins despite losing on pixels. Exact byte arithmetic,
    // not timing: four spends cannot reach the budget and five must exceed it.
    let med = fat_jpeg(320, 240, 4);
    let huge = jpeg(640, 480);
    let blobs: [&[u8]; 6] = [&med, &med, &med, &med, &med, &huge];
    let p = write(&d, "budget.cr2", &tiff_chain(&blobs));
    let (preview, _) = inspect(&p).expect("inspects");
    assert_eq!(preview.map(|v| (v.width, v.height)), Some((320, 240)));
}

#[test]
fn extensions_match_case_insensitively_on_the_basename() {
    for good in ["a.cr2", "A.CR3", "x.nef", "x.NRW", "x.arw", "x.sr2", "x.srf", "x.dng", "x.raf", "x.orf", "x.rw2", "x.pef", "/tmp/dir/a.DNG"] {
        assert!(is_raw_name(good), "{}", good);
    }
    for bad in ["a.jpg", "a.tif", "a.cr2x", "noext", "", "a.", ".cr2.bak", "cr2"] {
        assert!(!is_raw_name(bad), "{}", bad);
    }
}

#[test]
fn the_largest_valid_preview_wins_and_length_breaks_ties() {
    let d = TestDir::new("rawchoice");
    let small = jpeg(160, 120);
    let big = jpeg(640, 480);
    let big2 = jpeg(640, 480);
    // big2 carries a longer APP0 tail, so the same pixels lose nothing on length.
    let mut big2 = big2;
    big2.extend_from_slice(&[0u8; 64]);
    let junk = vec![7u8; 200];
    let blobs: [&[u8]; 4] = [&small, &big, &big2, &junk];
    let f = tiff_chain(&blobs);
    // Blob i starts past the four IFDs at 8 + 4*30 = 128, laid back to back.
    let mut want_off = 128u32;
    let mut offs = Vec::new();
    for blob in &blobs {
        offs.push(want_off);
        want_off += blob.len() as u32;
    }
    let p = write(&d, "choice.cr2", &f);    let (preview, _) = inspect(&p).expect("inspects");
    let pv = preview.expect("a valid candidate exists");
    assert_eq!((pv.width, pv.height), (640, 480));
    assert_eq!(pv.length, big2.len() as u64, "equal pixels break the tie by length");
    assert_eq!(pv.offset, offs[2] as u64);
}

#[test]
fn a_non_jpeg_candidate_is_quietly_skipped() {
    let d = TestDir::new("rawnojpeg");
    // One pair pointing at the file's own tail, where the junk starts.
    let mut f = tiff_one(38, 64);
    f.extend_from_slice(&[7u8; 64]);
    let p = write(&d, "junk.cr2", &f);
    let (preview, facts) = inspect(&p).expect("a recognised file inspects");
    assert!(preview.is_none(), "junk bytes are no preview");
    assert_eq!(facts, RawFacts::default());
}

#[test]
fn overflow_and_past_eof_candidates_validate_to_nothing() {
    let d = TestDir::new("rawoverflow");
    // offset + length overflows u64 and points past the file at once.
    let mut f = tiff_one(u32::MAX, u32::MAX);
    f.extend_from_slice(&[0u8; 16]);
    let p = write(&d, "over.cr2", &f);
    let (preview, _) = inspect(&p).expect("inspects");
    assert!(preview.is_none(), "an unrepresentable range is not read");
}

#[test]
fn header_reads_are_counted_and_stop_at_one_mib() {
    let d = TestDir::new("rawbudget");
    let p = write(&d, "big.cr2", &vec![0u8; 2 * 1024 * 1024]);
    let mut ctx = Ctx::open(&p).expect("opens");
    assert!(ctx.read_at(0, 600 * 1024).is_some());
    assert!(ctx.read_at(0, 424 * 1024).is_some(), "exactly at the budget still reads");
    assert!(ctx.read_at(0, 1).is_none(), "past it nothing reads, and nothing panics");
    // Blobs ride outside the budget but inside their own cap and the file.
    assert!(ctx.read_blob(0, 262_144).is_some());
    assert!(ctx.read_blob(0, 2 * 1024 * 1024).is_none(), "over the blob cap");
    assert!(ctx.read_blob(u64::MAX - 10, 100).is_none(), "overflow is not a read");
}

#[test]
fn unknown_bytes_empty_and_directories_inspect_to_none() {
    let d = TestDir::new("rawdispatch");
    let png = write(&d, "a.png", &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0, 1, 2, 3, 4, 5]);
    assert!(inspect(&png).is_none(), "a PNG is not a RAW");
    let txt = d.file("a.txt", "plain text, sixteen+ bytes of it here");
    assert!(inspect(&txt).is_none());
    let empty = write(&d, "empty.cr2", &[]);
    assert!(inspect(&empty).is_none(), "an empty file carries no magic");
    let short = write(&d, "short.cr2", b"II*\x00");
    assert!(inspect(&short).is_none(), "a header fragment is not a TIFF");
}

// A frame JPEG with a chosen SOF marker: C0 baseline, C3 lossless raw, and the rest.
fn jpeg_sof(marker: u8, w: u16, h: u16) -> Vec<u8> {
    let mut v = vec![0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x08, 1, 2, 3, 4, 5, 6];
    v.extend_from_slice(&[0xFF, marker, 0x00, 0x0B, 0x08]);
    v.extend_from_slice(&h.to_be_bytes());
    v.extend_from_slice(&w.to_be_bytes());
    v.extend_from_slice(&[0x01, 0x01, 0x22, 0x00, 0xFF, 0xD9]);
    v
}

enum Sv {
    N(u16, u32),
    A(Vec<u32>),
}

// Minimal LE strip-chain builder for the shaped fixtures: blobs first, then chained IFDs.
struct Sb {
    b: Vec<u8>,
}

impl Sb {
    fn new() -> Sb {
        let mut b = b"II*\x00".to_vec();
        b.extend_from_slice(&8u32.to_le_bytes());
        Sb { b }
    }

    fn blob(&mut self, data: &[u8]) -> u32 {
        let off = self.b.len() as u32;
        self.b.extend_from_slice(data);
        off
    }

    fn ifd(&mut self, entries: Vec<(u16, Sv)>, next: u32) -> u32 {
        let off = self.b.len() as u32;
        self.b.extend_from_slice(&(entries.len() as u16).to_le_bytes());
        let mut patches = vec![];
        for (tag, ev) in entries {
            self.b.extend_from_slice(&tag.to_le_bytes());
            match ev {
                Sv::N(typ, v) => {
                    self.b.extend_from_slice(&typ.to_le_bytes());
                    self.b.extend_from_slice(&1u32.to_le_bytes());
                    if typ == 3 {
                        self.b.extend_from_slice(&(v as u16).to_le_bytes());
                        self.b.extend_from_slice(&[0, 0]);
                    } else {
                        self.b.extend_from_slice(&v.to_le_bytes());
                    }
                }
                Sv::A(vs) => {
                    self.b.extend_from_slice(&4u16.to_le_bytes());
                    self.b.extend_from_slice(&(vs.len() as u32).to_le_bytes());
                    patches.push((self.b.len(), vs));
                    self.b.extend_from_slice(&0u32.to_le_bytes());
                }
            }
        }
        self.b.extend_from_slice(&next.to_le_bytes());
        for (pos, vs) in patches {
            let doff = self.b.len() as u32;
            for v in vs {
                self.b.extend_from_slice(&v.to_le_bytes());
            }
            self.b[pos..pos + 4].copy_from_slice(&doff.to_le_bytes());
        }
        off
    }

    fn set_ifd0(&mut self, off: u32) {
        self.b[4..8].copy_from_slice(&off.to_le_bytes());
    }
}

fn strip(off: u32, len: u32, comp: u32, nst: Option<u32>) -> Vec<(u16, Sv)> {
    let mut v = vec![
        (ex::STRIP_OFF, Sv::N(4, off)),
        (ex::STRIP_LEN, Sv::N(4, len)),
        (ex::COMPRESSION, Sv::N(3, comp)),
    ];
    if let Some(n) = nst {
        // NewSubfileType rides along as inert data: the SOF rule alone decides, 0 or 1.
        v.push((0x00FE, Sv::N(4, n)));
    }
    v
}

#[test]
fn a_cr2_shaped_file_prefers_ifd0_and_refuses_sof3() {
    let d = TestDir::new("rawcr2shape");
    let big = jpeg(1620, 1080);
    let small = jpeg(160, 120);
    let raw = jpeg_sof(0xC3, 3000, 2000);
    let mut t = Sb::new();
    let bo = t.blob(&big);
    let so = t.blob(&small);
    let ro = t.blob(&raw);
    let i3 = t.ifd(strip(ro, raw.len() as u32, 6, None), 0);
    let i2 = t.ifd(vec![(0x0100, Sv::N(4, 100))], i3);
    let i1 = t.ifd(
        vec![(ex::JPEG_OFF, Sv::N(4, so)), (ex::JPEG_LEN, Sv::N(4, small.len() as u32))],
        i2,
    );
    let i0 = t.ifd(strip(bo, big.len() as u32, 6, None), i1);
    t.set_ifd0(i0);
    let p = write(&d, "a.cr2", &t.b);
    let (preview, _) = inspect(&p).expect("inspects");
    let pv = preview.expect("IFD0's preview validates");
    // The SOF3 "raw" claims more pixels, so this also proves the refusal, not just the order.
    assert_eq!((pv.width, pv.height), (1620, 1080));
}

#[test]
fn a_dng_shaped_file_prefers_the_reduced_subifd_over_sof3_raw() {
    let d = TestDir::new("rawdngshape");
    let prev = jpeg(800, 600);
    let raw = jpeg_sof(0xC3, 2000, 1500);
    let flat = vec![9u8; 64];
    let mut t = Sb::new();
    let fo = t.blob(&flat);
    let ro = t.blob(&raw);
    let po = t.blob(&prev);
    let a = t.ifd(strip(ro, raw.len() as u32, 7, Some(0)), 0);
    let b = t.ifd(strip(po, prev.len() as u32, 7, Some(1)), 0);
    let ifd0 = t.ifd(
        vec![
            (ex::STRIP_OFF, Sv::N(4, fo)),
            (ex::STRIP_LEN, Sv::N(4, flat.len() as u32)),
            (ex::COMPRESSION, Sv::N(3, 1)),
            (ex::SUB_IFD, Sv::A(vec![a, b])),
        ],
        0,
    );
    t.set_ifd0(ifd0);
    let p = write(&d, "a.dng", &t.b);
    let (preview, _) = inspect(&p).expect("inspects");
    assert_eq!(preview.map(|v| (v.width, v.height)), Some((800, 600)));
}
