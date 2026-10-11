// The TIFF/IFD walk shared by CR2 NEF NRW ARW SR2 DNG ORF RW2 PEF, because every one of
// them is a TIFF header followed by IFD chains: IFD0 and its chain, SubIFDs, the EXIF IFD,
// and a MakerNote only when it carries its own TIFF header. One bounded walker serves all.
use crate::backend::rawembed::{Ctx, RawFacts};
use crate::backend::rawexif as ex;

// An IFD past this is a cycle or a corrupt count, so the walk stops rather than following it.
const MAX_IFDS: u32 = 64;
const MAX_ENTRIES: u16 = 1024;
const MAX_DEPTH: u8 = 4;
const ENTRY_LEN: usize = 12;

// Any byte source the walk can bound: the file through the header budget, or a slice in hand.
pub(crate) trait Src {
    fn get(&mut self, off: u64, n: usize) -> Option<Vec<u8>>;
}

pub(crate) struct FileSrc<'a> {
    pub ctx: &'a mut Ctx,
}

impl Src for FileSrc<'_> {
    fn get(&mut self, off: u64, n: usize) -> Option<Vec<u8>> {
        self.ctx.read_at(off, n)
    }
}

pub(crate) struct SliceSrc<'a> {
    data: &'a [u8],
    left: usize,
}

impl<'a> SliceSrc<'a> {
    // A walk copies out at most the slice's own length, so a hostile directory cannot re-read one region without end.
    pub(crate) fn new(data: &'a [u8]) -> SliceSrc<'a> {
        SliceSrc { data, left: data.len() }
    }
}

impl Src for SliceSrc<'_> {
    fn get(&mut self, off: u64, n: usize) -> Option<Vec<u8>> {
        let end = off.checked_add(n as u64)?;
        if end > self.data.len() as u64 || n > self.left {
            return None;
        }
        self.left -= n;
        Some(self.data[off as usize..end as usize].to_vec())
    }
}

pub(crate) struct Walk {
    pub cands: Vec<(u64, u64)>,
    pub facts: RawFacts,
    seen: Vec<u64>,
    ifds: u32,
}

impl Walk {
    pub fn new() -> Walk {
        Walk {
            cands: Vec::new(),
            facts: RawFacts::default(),
            seen: Vec::new(),
            ifds: 0,
        }
    }
}

// Where one IFD sits: its TIFF header, byte order, nesting, chain position, and whether an
// Olympus note owns it, in one value rather than a parameter list.
pub(crate) struct IfdLoc {
    pub base: u64,
    pub little_endian: bool,
    pub depth: u8,
    pub in_sub_ifd: bool,
    pub index_in_chain: u32,
    pub is_exif: bool,
    pub olympus_base: Option<u64>,
}

pub(crate) fn rd16(b: &[u8], le: bool) -> Option<u16> {
    let s = b.get(0..2)?;
    Some(if le {
        u16::from_le_bytes([s[0], s[1]])
    } else {
        u16::from_be_bytes([s[0], s[1]])
    })
}

pub(crate) fn rd32(b: &[u8], le: bool) -> Option<u32> {
    let s = b.get(0..4)?;
    Some(if le {
        u32::from_le_bytes([s[0], s[1], s[2], s[3]])
    } else {
        u32::from_be_bytes([s[0], s[1], s[2], s[3]])
    })
}

// Sample input: 49 49 2A 00 | ifd0(4, le); ORF answers IIRO/IIRS and RW2 IIU0, same tail.
fn header<S: Src>(src: &mut S, base: u64) -> Option<(bool, u64)> {
    let b = src.get(base, 8)?;
    let le = if b.starts_with(b"II*\x00") {
        true
    } else if b.starts_with(b"MM\x00*") {
        false
    } else if b.starts_with(b"IIRO") || b.starts_with(b"IIRS") || b.starts_with(b"IIU\x00") {
        // Vendor TIFF variants: little-endian with the first IFD where the standard puts it.
        true
    } else {
        // BigTIFF (version 43, 8-byte offsets) lands here too and is refused, not misread.
        return None;
    };
    let ifd = rd32(b.get(4..8)?, le)? as u64;
    Some((le, base.checked_add(ifd)?))
}

pub(crate) fn walk_ifd<S: Src>(src: &mut S, w: &mut Walk, loc: &IfdLoc, ifd: u64) -> Option<()> {
    if loc.depth > MAX_DEPTH || w.ifds >= MAX_IFDS {
        return Some(());
    }
    let abs = loc.base.checked_add(ifd)?;
    if w.seen.contains(&abs) {
        return Some(());
    }
    let le = loc.little_endian;
    let count = rd16(&src.get(abs, 2)?, le)?;
    // A 0xFFFF count is the hostile case: this IFD is skipped, never allocated or looped.
    if count > MAX_ENTRIES {
        return Some(());
    }
    let eb = src.get(abs.checked_add(2)?, (count as usize).checked_mul(ENTRY_LEN)?)?;
    w.seen.push(abs);
    w.ifds += 1;
    let mut jpeg = (None, None);
    let mut strip = (None, None, None);
    let mut rw2: Option<(u64, u64)> = None;
    let mut oly_pair = (None, None);
    let mut after: Vec<(u8, u64)> = Vec::new();
    let mut notes: Vec<(u16, u32, [u8; 4])> = Vec::new();
    for i in 0..count as usize {
        let e = eb.get(i * ENTRY_LEN..i * ENTRY_LEN + ENTRY_LEN)?;
        let tag = rd16(&e[0..2], le)?;
        let typ = rd16(&e[2..4], le)?;
        let cnt = rd32(&e[4..8], le)?;
        let val = e.get(8..12)?;
        let base = loc.base;
        let exif = loc.is_exif;
        match tag {
            t if t == ex::MAKE && !exif && w.facts.make.is_none() => {
                w.facts.make = ex::ascii_of(src, base, le, typ, cnt, val);
            }
            t if t == ex::MODEL && !exif && w.facts.model.is_none() => {
                w.facts.model = ex::ascii_of(src, base, le, typ, cnt, val);
            }
            t if t == ex::ORIENTATION && !exif && w.facts.orientation.is_none() => {
                w.facts.orientation = ex::one_u32(src, base, le, typ, cnt, val).map(|v| v as u16);
            }
            t if t == ex::EXPOSURE && exif && w.facts.exposure.is_none() => {
                w.facts.exposure = ex::rational_of(src, base, le, typ, cnt, val);
            }
            t if t == ex::FNUMBER && exif && w.facts.f_number.is_none() => {
                w.facts.f_number = ex::rational_of(src, base, le, typ, cnt, val);
            }
            t if t == ex::ISO && exif && w.facts.iso.is_none() => {
                w.facts.iso = ex::one_u32(src, base, le, typ, cnt, val).map(|v| v as u32);
            }
            t if t == ex::ISO_ALT && exif && w.facts.iso.is_none() => {
                w.facts.iso = ex::one_u32(src, base, le, typ, cnt, val).map(|v| v as u32);
            }
            t if t == ex::TAKEN && exif && w.facts.taken.is_none() => {
                w.facts.taken = ex::ascii_of(src, base, le, typ, cnt, val);
            }
            t if t == ex::FOCAL && exif && w.facts.focal_mm.is_none() => {
                w.facts.focal_mm = ex::rational_of(src, base, le, typ, cnt, val);
            }
            t if t == ex::LENS && exif && w.facts.lens.is_none() => {
                w.facts.lens = ex::ascii_of(src, base, le, typ, cnt, val);
            }
            t if t == ex::JPEG_OFF => jpeg.0 = ex::one_u32(src, base, le, typ, cnt, val),
            t if t == ex::JPEG_LEN => jpeg.1 = ex::one_u32(src, base, le, typ, cnt, val),
            t if t == ex::STRIP_OFF => {
                strip.0 = ex::one_u32(src, base, le, typ, cnt, val);
                if cnt != 1 {
                    strip.0 = None;
                }
            }
            t if t == ex::STRIP_LEN => strip.1 = ex::one_u32(src, base, le, typ, cnt, val),
            t if t == ex::COMPRESSION => strip.2 = ex::one_u32(src, base, le, typ, cnt, val),
            t if t == ex::RW2_JPGFROMRAW && (typ == 1 || typ == 7) => {
                if let Some((ex::Val::At(off, n), total)) = ex::locate(base, le, typ, cnt, val) {
                    // The tag's value bytes are the JPEG; an inline one is too short to be one.
                    if total >= 20 {
                        rw2 = Some((off, n as u64));
                    }
                }
            }
            t if t == ex::OLY_PREVIEW_START && loc.olympus_base.is_some() => {
                oly_pair.0 = ex::one_u32(src, base, le, typ, cnt, val);
            }
            t if t == ex::OLY_PREVIEW_LEN && loc.olympus_base.is_some() => {
                oly_pair.1 = ex::one_u32(src, base, le, typ, cnt, val);
            }
            t if t == ex::EXIF_IFD_PTR => {
                if let Some(p) = ex::one_u32(src, base, le, typ, cnt, val) {
                    after.push((1, p));
                }
            }
            t if t == ex::SUB_IFD => {
                if let Some(ps) = ex::offsets(src, base, le, typ, cnt, val) {
                    for p in ps {
                        after.push((2, p));
                    }
                }
            }
            t if t == ex::MAKER_NOTE => {
                let mut raw = [0u8; 4];
                raw.copy_from_slice(val);
                notes.push((typ, cnt, raw));
            }
            _ => {}
        }
    }
    if let (Some(o), Some(n)) = jpeg {
        // Offsets ride relative to the TIFF header, so the base travels with them.
        if n > 0 {
            if let Some(a) = loc.base.checked_add(o) {
                w.cands.push((a, n));
            }
        }
    }
    if let (Some(o), Some(n), Some(c)) = strip {
        // Any lone JPEG-compressed strip is a preview, IFD0 included: Canon CR2 keeps its
        // full-size preview exactly there, and the SOF rule keeps raw sensor data out.
        if (c == 6 || c == 7) && n > 0 {
            if let Some(a) = loc.base.checked_add(o) {
                w.cands.push((a, n));
            }
        }
    }
    if let Some(c) = rw2 {
        w.cands.push(c);
    }
    if let (Some(s), Some(n)) = oly_pair {
        // Olympus counts from its own MakerNote TIFF header, not the file's.
        if n > 0 {
            if let Some(ob) = loc.olympus_base {
                if let Some(a) = ob.checked_add(s) {
                    w.cands.push((a, n));
                }
            }
        }
    }
    for (kind, p) in after {
        let child = IfdLoc {
            base: loc.base,
            little_endian: le,
            depth: loc.depth + 1,
            in_sub_ifd: true,
            index_in_chain: 0,
            is_exif: kind == 1,
            olympus_base: None,
        };
        let _ = walk_ifd(src, w, &child, p);
    }
    for (typ, cnt, raw) in notes {
        let _ = super::rawnote::makernote(src, w, loc, typ, cnt, &raw);
    }
    let tail = abs
        .checked_add(2)?
        .checked_add((count as u64).checked_mul(ENTRY_LEN as u64)?)?;
    let next = rd32(&src.get(tail, 4)?, le)? as u64;
    if next != 0 {
        // The chain carries the position on: same depth, same home, next index.
        let child = IfdLoc {
            base: loc.base,
            little_endian: le,
            depth: loc.depth,
            in_sub_ifd: loc.in_sub_ifd,
            index_in_chain: loc.index_in_chain + 1,
            is_exif: loc.is_exif,
            olympus_base: loc.olympus_base,
        };
        let _ = walk_ifd(src, w, &child, next);
    }
    Some(())
}

fn root(le: bool) -> IfdLoc {
    IfdLoc {
        base: 0,
        little_endian: le,
        depth: 0,
        in_sub_ifd: false,
        index_in_chain: 0,
        is_exif: false,
        olympus_base: None,
    }
}

pub(crate) fn inspect_file(ctx: &mut Ctx) -> Option<(Vec<(u64, u64)>, RawFacts)> {
    let mut src = FileSrc { ctx };
    let mut w = Walk::new();
    let (le, abs0) = header(&mut src, 0)?;
    walk_ifd(&mut src, &mut w, &root(le), abs0)?;
    if w.ifds == 0 {
        return None;
    }
    Some((w.cands, w.facts))
}

// A bare TIFF in hand (a CR3 CMT box, a RAF APP1): an Exif TIFF carries EXIF tags at its
// own top level, so the caller names what its first IFD is rather than the walk guessing.
pub(crate) fn facts_from_slice(data: &[u8], exif_top: bool) -> RawFacts {
    let mut src = SliceSrc::new(data);
    let mut w = Walk::new();
    let Some((le, abs0)) = header(&mut src, 0) else {
        return RawFacts::default();
    };
    let mut loc = root(le);
    loc.is_exif = exif_top;
    let _ = walk_ifd(&mut src, &mut w, &loc, abs0);
    w.facts
}

#[cfg(test)]
#[path = "rawtiff_tests.rs"]
pub(crate) mod tests;
