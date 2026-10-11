// MakerNote fixtures: notes whose signatures bound them (Nikon, Olympus) and notes that
// do not (unknown, truncated, inline), so the walk enters only what it can bound.
use crate::backend::rawexif as ex;
use crate::backend::rawtiff::inspect_file;
use crate::backend::rawembed::Ctx;
use crate::backend::testdir::TestDir;

fn tsize(t: u16) -> usize {
    match t {
        1 | 2 | 6 | 7 => 1,
        3 | 8 => 2,
        4 | 9 | 11 => 4,
        _ => 8,
    }
}

enum Ev {
    B(u16, Vec<u8>),
}

struct Tb {
    b: Vec<u8>,
}

impl Tb {
    fn new() -> Tb {
        let mut b = b"II*\x00".to_vec();
        b.extend_from_slice(&[0, 0, 0, 0]);
        Tb { b }
    }

    fn w16(&mut self, v: u16) {
        let b = v.to_le_bytes();
        self.b.extend_from_slice(&b);
    }

    fn w32(&mut self, v: u32) {
        let b = v.to_le_bytes();
        self.b.extend_from_slice(&b);
    }

    fn blob(&mut self, data: &[u8]) -> u32 {
        let off = self.b.len() as u32;
        self.b.extend_from_slice(data);
        off
    }

    fn ifd(&mut self, entries: Vec<(u16, Ev)>, next: u32) -> u32 {
        let off = self.b.len() as u32;
        self.w16(entries.len() as u16);
        let mut patches: Vec<(usize, Vec<u8>)> = Vec::new();
        for (tag, ev) in entries {
            self.w16(tag);
            match ev {
                Ev::B(typ, data) => {
                    let cnt = (data.len() / tsize(typ)) as u32;
                    self.w16(typ);
                    self.w32(cnt);
                    if data.len() <= 4 {
                        let mut pad = data;
                        pad.resize(4, 0);
                        self.b.extend_from_slice(&pad);
                    } else {
                        patches.push((self.b.len(), data));
                        self.w32(0);
                    }
                }
            }
        }
        self.w32(next);
        for (pos, data) in patches {
            let doff = self.b.len() as u32;
            self.b.extend_from_slice(&data);
            self.b[pos..pos + 4].copy_from_slice(&doff.to_le_bytes());
        }
        off
    }

    fn set_ifd0(&mut self, off: u32) {
        self.b[4..8].copy_from_slice(&off.to_le_bytes());
    }
}

fn jpeg(w: u16, h: u16) -> Vec<u8> {
    let mut v = vec![0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x08, 1, 2, 3, 4, 5, 6];
    v.extend_from_slice(&[0xFF, 0xC0, 0x00, 0x0B, 0x08]);
    v.extend_from_slice(&h.to_be_bytes());
    v.extend_from_slice(&w.to_be_bytes());
    v.extend_from_slice(&[0x01, 0x01, 0x22, 0x00, 0xFF, 0xD9]);
    v
}

fn write(d: &TestDir, name: &str, bytes: &[u8]) -> std::path::PathBuf {
    let p = d.join(name);
    std::fs::write(&p, bytes).unwrap();
    p
}

#[test]
fn a_nikon_makernote_is_bounded_and_walked() {
    let d = TestDir::new("rawnikon");
    let mut t = Tb::new();
    let pic = jpeg(500, 400);
    // The note's sub-IFD stores offsets relative to the note's own TIFF header, so the
    // JPEG offset is patched once the layout is known; the placeholder keeps it unique.
    const PLACE: u32 = 0xDEADBEEF;
    let mut note = b"Nikon\x00\x02\x10II*\x00".to_vec();
    // The sub-IFD follows the note's 8-byte TIFF header directly.
    note.extend_from_slice(&8u32.to_le_bytes());
    note.extend_from_slice(&2u16.to_le_bytes());
    note.extend_from_slice(&ex::JPEG_OFF.to_le_bytes());
    note.extend_from_slice(&4u16.to_le_bytes());
    note.extend_from_slice(&1u32.to_le_bytes());
    note.extend_from_slice(&PLACE.to_le_bytes());
    note.extend_from_slice(&ex::JPEG_LEN.to_le_bytes());
    note.extend_from_slice(&4u16.to_le_bytes());
    note.extend_from_slice(&1u32.to_le_bytes());
    note.extend_from_slice(&(pic.len() as u32).to_le_bytes());
    note.extend_from_slice(&0u32.to_le_bytes());
    let ifd0 = t.ifd(vec![(ex::MAKER_NOTE, Ev::B(7, note))], 0);
    t.set_ifd0(ifd0);
    let jb = t.blob(&pic);
    let bytes = t.b.clone();
    let noff = bytes.windows(6).position(|w| w == b"Nikon\x00").expect("the note is in the file") as u64;
    let rel = (jb as u64).checked_sub(noff + 8).expect("the JPEG sits past the note") as u32;
    let at = bytes.windows(4).position(|w| w == &PLACE.to_le_bytes()).expect("one placeholder");
    t.b[at..at + 4].copy_from_slice(&rel.to_le_bytes());
    let p = write(&d, "a.nef", &t.b);
    let ctx = Ctx::open(&p).expect("opens");
    let (cands, _) = inspect_file(&mut { ctx }).expect("walks");
    assert_eq!(cands, vec![(jb as u64, pic.len() as u64)]);
}

#[test]
fn an_olympus_makernote_preview_counts_from_its_own_header() {
    // Exact layout, every offset known: header(8) IFD0(18) note(46) JPEG.
    // Note TIFF header at 34, sub-IFD at 42, JPEG at 72, so start reads 38.
    let d = TestDir::new("rawoly");
    let pic = jpeg(300, 220);
    let mut b = b"II*\x00".to_vec();
    b.extend_from_slice(&8u32.to_le_bytes());
    b.extend_from_slice(&1u16.to_le_bytes());
    b.extend_from_slice(&ex::MAKER_NOTE.to_le_bytes());
    b.extend_from_slice(&7u16.to_le_bytes());
    b.extend_from_slice(&46u32.to_le_bytes());
    b.extend_from_slice(&26u32.to_le_bytes());
    b.extend_from_slice(&0u32.to_le_bytes());
    b.extend_from_slice(b"OLYMPUS\x00II*\x00");
    b.extend_from_slice(&8u32.to_le_bytes());
    b.extend_from_slice(&2u16.to_le_bytes());
    b.extend_from_slice(&ex::OLY_PREVIEW_START.to_le_bytes());
    b.extend_from_slice(&4u16.to_le_bytes());
    b.extend_from_slice(&1u32.to_le_bytes());
    b.extend_from_slice(&38u32.to_le_bytes());
    b.extend_from_slice(&ex::OLY_PREVIEW_LEN.to_le_bytes());
    b.extend_from_slice(&4u16.to_le_bytes());
    b.extend_from_slice(&1u32.to_le_bytes());
    b.extend_from_slice(&(pic.len() as u32).to_le_bytes());
    b.extend_from_slice(&0u32.to_le_bytes());
    assert_eq!(b.len(), 72, "the JPEG lands exactly where the relative start says");
    b.extend_from_slice(&pic);
    let p = write(&d, "a.orf", &b);
    let ctx = Ctx::open(&p).expect("opens");
    let (cands, _) = inspect_file(&mut { ctx }).expect("walks");
    assert_eq!(cands, vec![(72u64, pic.len() as u64)]);
}

#[test]
fn unknown_and_truncated_notes_are_skipped_not_entered() {
    let d = TestDir::new("rawnoteskip");
    let mut t = Tb::new();
    // No known signature: the note is skipped and the file still walks.
    let ifd0 = t.ifd(vec![(ex::MAKER_NOTE, Ev::B(7, b"PENTAXFAKE-not-a-tiff-header!!".to_vec()))], 0);
    t.set_ifd0(ifd0);
    let p = write(&d, "a.pef", &t.b);
    let ctx = Ctx::open(&p).expect("opens");
    let (cands, _) = inspect_file(&mut { ctx }).expect("a skipped note is not a failure");
    assert!(cands.is_empty());
    // A Nikon signature cut before its TIFF header: skipped, never read past the value.
    let mut t2 = Tb::new();
    let i2 = t2.ifd(vec![(ex::MAKER_NOTE, Ev::B(7, b"Nikon\x00\x02".to_vec()))], 0);
    t2.set_ifd0(i2);
    let p2 = write(&d, "b.nef", &t2.b);
    let ctx2 = Ctx::open(&p2).expect("opens");
    assert!(inspect_file(&mut { ctx2 }).is_some());
}
