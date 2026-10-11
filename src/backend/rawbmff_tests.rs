// Synthetic CR3: an ftyp box, a PRVW uuid box and a moov uuid box holding CMT TIFFs and
// a THMB, so the container walk is proved without a Canon file.
use crate::backend::rawembed;
use crate::backend::testdir::TestDir;

pub(crate) const PRVW: [u8; 16] = [
    0xEA, 0xF4, 0x2B, 0x5E, 0x1C, 0x98, 0x4B, 0x88, 0xB9, 0xFB, 0xB7, 0xDC, 0x40, 0x6E, 0x4D, 0x16,
];
pub(crate) const MOOV: [u8; 16] = [
    0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0, 0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48,
];

fn jpeg(w: u16, h: u16) -> Vec<u8> {
    let mut v = vec![0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x08, 1, 2, 3, 4, 5, 6];
    v.extend_from_slice(&[0xFF, 0xC0, 0x00, 0x0B, 0x08]);
    v.extend_from_slice(&h.to_be_bytes());
    v.extend_from_slice(&w.to_be_bytes());
    v.extend_from_slice(&[0x01, 0x01, 0x22, 0x00, 0xFF, 0xD9]);
    v
}

// One IFD of typed tags: tag(2) type(2) count value-or-offset, data appended after.
pub(crate) fn tiff(entries: &[(u16, u16, &[u8])]) -> Vec<u8> {
    let mut b = b"II*\x00".to_vec();
    b.extend_from_slice(&8u32.to_le_bytes());
    b.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    let mut patches: Vec<(usize, Vec<u8>)> = Vec::new();
    for (tag, typ, val) in entries {
        b.extend_from_slice(&tag.to_le_bytes());
        b.extend_from_slice(&typ.to_le_bytes());
        let ts = match typ {
            1 | 2 | 7 => 1,
            3 => 2,
            5 | 10 | 12 => 8,
            _ => 4,
        };
        b.extend_from_slice(&((val.len() / ts) as u32).to_le_bytes());
        if val.len() <= 4 {
            let mut pad = val.to_vec();
            pad.resize(4, 0);
            b.extend_from_slice(&pad);
        } else {
            patches.push((b.len(), val.to_vec()));
            b.extend_from_slice(&0u32.to_le_bytes());
        }
    }
    b.extend_from_slice(&0u32.to_le_bytes());
    for (pos, data) in patches {
        let off = b.len() as u32;
        b.extend_from_slice(&data);
        b[pos..pos + 4].copy_from_slice(&off.to_le_bytes());
    }
    b
}

pub(crate) fn bx(typ: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    let mut b = ((payload.len() + 8) as u32).to_be_bytes().to_vec();
    b.extend_from_slice(typ);
    b.extend_from_slice(payload);
    b
}

pub(crate) fn uuid(usertype: &[u8; 16], payload: &[u8]) -> Vec<u8> {
    let mut inner = usertype.to_vec();
    inner.extend_from_slice(payload);
    bx(b"uuid", &inner)
}

fn inner(typ: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    bx(typ, payload)
}

pub(crate) fn cr3(big: &[u8], small: &[u8], cmt1: &[u8], cmt2: &[u8]) -> Vec<u8> {
    let mut ftyp = b"crx ".to_vec();
    ftyp.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0, 0]);
    let mut f = bx(b"ftyp", &ftyp);
    let mut prvw = (big.len() as u32 + 8).to_be_bytes().to_vec();
    prvw.extend_from_slice(b"PRVW");
    prvw.extend_from_slice(big);
    f.extend_from_slice(&uuid(&PRVW, &prvw));
    let mut m = inner(b"CMT1", cmt1);
    m.extend_from_slice(&inner(b"CMT2", cmt2));
    m.extend_from_slice(&inner(b"THMB", small));
    f.extend_from_slice(&uuid(&MOOV, &m));
    f
}

fn write(d: &TestDir, name: &str, bytes: &[u8]) -> std::path::PathBuf {
    let p = d.join(name);
    std::fs::write(&p, bytes).unwrap();
    p
}

#[test]
fn a_cr3_yields_the_prvw_pixels_and_the_cmt_facts() {
    let d = TestDir::new("rawcr3");
    let big = jpeg(1620, 1080);
    let small = jpeg(160, 120);
    let cmt1 = tiff(&[(0x010F, 2, b"Canon\0"), (0x0110, 2, b"EOS R6\0")]);
    let mut expo = 1u32.to_le_bytes().to_vec();
    expo.extend_from_slice(&250u32.to_le_bytes());
    let cmt2 = tiff(&[(0x829A, 5, &expo), (0x8827, 3, &[200, 0])]);
    let p = write(&d, "a.cr3", &cr3(&big, &small, &cmt1, &cmt2));
    let Some((preview, facts)) = rawembed::inspect(&p) else {
        panic!("a valid CR3 inspects");
    };
    let pv = preview.expect("PRVW wins over THMB");
    assert_eq!((pv.width, pv.height), (1620, 1080));
    assert_eq!(facts.make.as_deref(), Some("Canon"));
    assert_eq!(facts.model.as_deref(), Some("EOS R6"));
    assert_eq!(facts.exposure, Some((1, 250)));
    assert_eq!(facts.iso, Some(200));
}

#[test]
fn without_prvw_the_thmb_is_the_preview() {
    let d = TestDir::new("rawthmb");
    let small = jpeg(160, 120);
    let mut ftyp = b"crx ".to_vec();
    ftyp.extend_from_slice(&[0; 8]);
    let mut f = bx(b"ftyp", &ftyp);
    let mut m = inner(b"CMT1", &tiff(&[(0x010F, 2, b"C\0")]));
    m.extend_from_slice(&inner(b"THMB", &small));
    f.extend_from_slice(&uuid(&MOOV, &m));
    let p = write(&d, "b.cr3", &f);
    let (preview, _) = rawembed::inspect(&p).expect("inspects");
    assert_eq!(preview.map(|v| (v.width, v.height)), Some((160, 120)));
}

#[test]
fn a_non_crx_brand_is_not_a_cr3() {
    let d = TestDir::new("rawisom");
    let mut f = bx(b"ftyp", b"isom\0\0\0\0\0\0\0\0");
    f.extend_from_slice(&uuid(&PRVW, b"PRVW"));
    let p = write(&d, "a.cr3", &f);
    assert!(rawembed::inspect(&p).is_none(), "an isom file is refused, not misread");
}

#[test]
fn truncated_boxes_never_panic_and_a_largesize_box_walks() {
    let d = TestDir::new("rawboxtrunc");
    let big = jpeg(640, 480);
    let full = cr3(&big, &jpeg(80, 60), &tiff(&[(0x010F, 2, b"C\0")]), &tiff(&[]));
    for cut in (0..full.len()).step_by(16) {
        let p = write(&d, &format!("cut{}.cr3", cut), &full[..cut]);
        let _ = rawembed::inspect(&p);
    }
    // size == 1 names a 64-bit largesize; the walk takes it rather than stopping.
    let mut f = bx(b"ftyp", b"crx \0\0\0\0\0\0\0\0");
    let mut inner_prvw = (big.len() as u32 + 8).to_be_bytes().to_vec();
    inner_prvw.extend_from_slice(b"PRVW");
    inner_prvw.extend_from_slice(&big);
    let mut u = PRVW.to_vec();
    u.extend_from_slice(&inner_prvw);
    f.extend_from_slice(&1u32.to_be_bytes());
    f.extend_from_slice(b"uuid");
    f.extend_from_slice(&(u.len() as u64 + 16).to_be_bytes());
    f.extend_from_slice(&u);
    let p = write(&d, "large.cr3", &f);
    let (preview, _) = rawembed::inspect(&p).expect("a largesize PRVW walks");
    assert_eq!(preview.map(|v| v.width), Some(640));
}
