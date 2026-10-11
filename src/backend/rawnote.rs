// The MakerNote walk: a note is entered only when it opens with a known signature and its
// own TIFF header, which bounds it; anything else is skipped rather than guessed at.
use crate::backend::rawexif as ex;
use crate::backend::rawtiff::{rd16, rd32, walk_ifd, IfdLoc, Src, Walk};

// A MakerNote signature plus its TIFF header fit here; the note's payload is never read whole.
const SIG_WINDOW: usize = 64;

fn is_order(b: &[u8]) -> bool {
    b == [0x49, 0x49] || b == [0x4D, 0x4D]
}

// An 8-byte TIFF header at this offset, answered with its byte order and first IFD.
fn sub_tiff<S: Src>(src: &mut S, at: u64) -> Option<(bool, u64)> {
    let b = src.get(at, 8)?;
    if !is_order(b.get(0..2)?) {
        return None;
    }
    let le = b[0] == 0x49;
    if rd16(b.get(2..4)?, le)? != 42 {
        return None;
    }
    Some((le, rd32(b.get(4..8)?, le)? as u64))
}

pub(crate) fn makernote<S: Src>(
    src: &mut S,
    w: &mut Walk,
    loc: &IfdLoc,
    typ: u16,
    cnt: u32,
    raw: &[u8],
) -> Option<()> {
    let base = loc.base;
    let le = loc.little_endian;
    let (v, total) = ex::locate(base, le, typ, cnt, raw)?;
    if total < 12 {
        return Some(());
    }
    let at = match v {
        ex::Val::At(off, _) => off,
        ex::Val::Inline(_) => return Some(()),
    };
    let head = src.get(at, total.min(SIG_WINDOW))?;
    // Nikon "Nikon\0" plus two version bytes, then the TIFF header the note owns.
    let sub = if head.starts_with(b"Nikon\x00") && head.len() >= 10 && is_order(head.get(8..10)?) {
        at.checked_add(8)?
    } else if head.starts_with(b"OLYMPUS\x00") && head.len() >= 10 && is_order(head.get(8..10)?) {
        at.checked_add(8)?
    } else if head.starts_with(b"OLYMP\x00") && head.len() >= 8 && is_order(head.get(6..8)?) {
        at.checked_add(6)?
    } else if head.starts_with(b"AOC\x00") && head.len() >= 6 && is_order(head.get(4..6)?) {
        // Pentax "AOC\0" plus its TIFF header; any other tail is skipped, not parsed.
        at.checked_add(4)?
    } else {
        return Some(());
    };
    let (sle, sifd) = sub_tiff(src, sub)?;
    let child = IfdLoc {
        base: sub,
        little_endian: sle,
        depth: loc.depth + 1,
        in_sub_ifd: true,
        index_in_chain: 0,
        is_exif: false,
        olympus_base: head.starts_with(b"OLYMP").then_some(sub),
    };
    let _ = walk_ifd(src, w, &child, sifd);
    Some(())
}

#[cfg(test)]
#[path = "rawnote_tests.rs"]
mod tests;
