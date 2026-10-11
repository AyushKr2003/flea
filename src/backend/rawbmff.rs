// Canon CR3: an ISO BMFF file, so the previews and the EXIF ride in uuid boxes rather
// than in a TIFF: PRVW holds the large JPEG, and the moov uuid holds CMT1 (IFD0 TIFF),
// CMT2 (EXIF TIFF) and THMB (small JPEG). Facts come from the CMT boxes, pixels from PRVW.
use crate::backend::rawembed::{Ctx, RawFacts};
use crate::backend::rawtiff;

// Sample input: EA F4 2B 5E 1C 98 4B 88 B9 FB B7 DC 40 6E 4D 16, the PRVW box owner.
const PRVW_UUID: [u8; 16] = [
    0xEA, 0xF4, 0x2B, 0x5E, 0x1C, 0x98, 0x4B, 0x88, 0xB9, 0xFB, 0xB7, 0xDC, 0x40, 0x6E, 0x4D, 0x16,
];
// Sample input: 85 C0 B6 87 82 0F 11 E0 81 11 F4 CE 46 2B 6A 48, the moov box owner.
const MOOV_UUID: [u8; 16] = [
    0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0, 0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48,
];
const MAX_BOXES: u32 = 64;
const MAX_INNER: u32 = 32;
// The PRVW tag sits at its payload's head; the scan is only for a writer that padded it.
const PRVW_SCAN: u64 = 65_536;
// CMT TIFFs are metadata, so anything larger is a corrupt size, not a directory.
const MAX_CMT: u64 = 262_144;

fn be32(b: &[u8]) -> Option<u32> {
    let s = b.get(0..4)?;
    Some(u32::from_be_bytes([s[0], s[1], s[2], s[3]]))
}

// The PRVW box is size(4) "PRVW"(4) JPEG(size-8); its bytes stay on disk until validated.
fn prvw(ctx: &mut Ctx, off: u64, len: u64) -> Option<(u64, u64)> {
    let b = ctx.read_blob(off, len.min(PRVW_SCAN))?;
    let i = b.windows(4).position(|w| w == b"PRVW")?;
    if i < 4 || i + 4 > b.len() {
        return None;
    }
    let size = be32(b.get(i - 4..i)?)? as u64;
    if size < 8 {
        return None;
    }
    let jl = size.checked_sub(8)?;
    let jo = off.checked_add(i as u64)?.checked_add(4)?;
    if jo.checked_add(jl)? > off.checked_add(len)? {
        return None;
    }
    if jl == 0 {
        return None;
    }
    Some((jo, jl))
}

fn merge(dst: &mut RawFacts, src: RawFacts) {
    if dst.make.is_none() {
        dst.make = src.make;
    }
    if dst.model.is_none() {
        dst.model = src.model;
    }
    if dst.lens.is_none() {
        dst.lens = src.lens;
    }
    if dst.exposure.is_none() {
        dst.exposure = src.exposure;
    }
    if dst.f_number.is_none() {
        dst.f_number = src.f_number;
    }
    if dst.iso.is_none() {
        dst.iso = src.iso;
    }
    if dst.focal_mm.is_none() {
        dst.focal_mm = src.focal_mm;
    }
    if dst.taken.is_none() {
        dst.taken = src.taken;
    }
    if dst.orientation.is_none() {
        dst.orientation = src.orientation;
    }
}

// The moov uuid payload is plain size+type boxes: CMT1, CMT2, THMB and whatever else.
fn moov(ctx: &mut Ctx, off: u64, len: u64, cands: &mut Vec<(u64, u64)>, facts: &mut RawFacts) {
    let end = match off.checked_add(len) {
        Some(e) if e <= ctx.len => e,
        _ => return,
    };
    let mut p = off;
    let mut n = 0u32;
    while p < end && n < MAX_INNER {
        n += 1;
        let Some(h) = ctx.read_at(p, 8) else {
            break;
        };
        let size = match be32(&h[0..4]) {
            Some(s) if s >= 8 => s as u64,
            _ => break,
        };
        let bend = match p.checked_add(size) {
            Some(e) if e <= end => e,
            _ => break,
        };
        let kind = h.get(4..8);
        if kind == Some(b"CMT1".as_slice()) || kind == Some(b"CMT2".as_slice()) {
            let dl = size - 8;
            if dl > 0 && dl <= MAX_CMT {
                if let Some(b) = ctx.read_blob(p + 8, dl) {
                    // CMT1 is an IFD0 TIFF and CMT2 an EXIF TIFF, which is what their tops are read as.
                    merge(facts, rawtiff::facts_from_slice(&b, kind == Some(b"CMT2".as_slice())));
                }
            }
        } else if kind == Some(b"THMB".as_slice()) {
            if size > 8 {
                cands.push((p + 8, size - 8));
            }
        }
        p = bend;
    }
}

pub(crate) fn inspect_file(ctx: &mut Ctx) -> Option<(Vec<(u64, u64)>, RawFacts)> {
    let mut cands = Vec::new();
    let mut facts = RawFacts::default();
    let mut pos = 0u64;
    let mut n = 0u32;
    while pos < ctx.len && n < MAX_BOXES {
        n += 1;
        let Some(h) = ctx.read_at(pos, 8) else {
            break;
        };
        let mut size = be32(&h[0..4])? as u64;
        let mut hlen = 8u64;
        if size == 1 {
            let Some(e) = ctx.read_at(pos + 8, 8) else {
                break;
            };
            size = u64::from_be_bytes(e[0..8].try_into().ok()?);
            hlen = 16;
        } else if size == 0 {
            size = ctx.len - pos;
        }
        if size < hlen {
            break;
        }
        let end = match pos.checked_add(size) {
            Some(e) if e <= ctx.len => e,
            _ => break,
        };
        // A uuid box shorter than its header and usertype holds no payload.
        if h.get(4..8) == Some(b"uuid".as_slice()) && size >= hlen + 16 {
            let Some(ut) = ctx.read_at(pos + hlen, 16) else {
                break;
            };
            let poff = pos + hlen + 16;
            let plen = size - hlen - 16;
            if ut.as_slice() == PRVW_UUID {
                if let Some(c) = prvw(ctx, poff, plen) {
                    cands.push(c);
                }
            } else if ut.as_slice() == MOOV_UUID {
                moov(ctx, poff, plen, &mut cands, &mut facts);
            }
        }
        if end <= pos {
            break;
        }
        pos = end;
    }
    Some((cands, facts))
}

#[cfg(test)]
#[path = "rawbmff_tests.rs"]
pub(crate) mod tests;
