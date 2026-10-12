// Copies a camera RAW's largest embedded JPEG into the user cache once per file version, upright whatever the camera stored.
use crate::backend::imagesize;
use crate::backend::md5;
use crate::backend::rawembed::{inspect, JPEG_PREFIX};
use crate::backend::rawtiff::facts_from_slice;
use crate::backend::regfile::open_regular;
use crate::backend::thumbcache::uri_for;
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::SystemTime;

const FILE_MODE: u32 = 0o600;
const DIR_MODE: u32 = 0o700;
const EXIF_MAGIC: &[u8] = b"Exif\0\0";
// Marker, length 34, "Exif\0\0", "II" 42 and IFD0 at 8, one entry: Orientation (0x0112), SHORT, count 1, no next IFD.
const EXIF_ORIENT: [u8; 36] = [
    0xFF, 0xE1, 0x00, 0x22, b'E', b'x', b'i', b'f', 0, 0, b'I', b'I', 0x2A, 0, 8, 0, 0, 0, 1, 0, 0x12, 0x01, 3, 0, 1, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
];
// Where the orientation value sits in that segment.
const EXIF_ORIENT_AT: usize = 28;
// Two threads of this process can extract the same file at once, so each writes a temp of its own.
static NEXT_TEMP: AtomicU32 = AtomicU32::new(0);

// The copy and what a caller needs to draw it: stored pixels plus the turn a viewer applies, as imagesize reads them.
pub struct Extracted {
    pub file: PathBuf,
    pub width: u32,
    pub height: u32,
    pub orientation: u8,
}

fn cache_dir() -> PathBuf {
    crate::userfile::cache_home().join("flea").join("raw")
}

// None when the file is no RAW, holds no JPEG preview, or the cache cannot be written; a fresh copy costs no walk and no write.
pub fn ensure(src: &Path) -> Option<Extracted> {
    ensure_in(&cache_dir(), src)
}

// Named by the RAW's URI, the key the thumbnail cache uses for the same file.
fn copy_path(dir: &Path, src: &Path) -> PathBuf {
    dir.join(format!("{}.jpg", md5::hex(uri_for(src).as_bytes())))
}

fn ensure_in(dir: &Path, src: &Path) -> Option<Extracted> {
    // Read before the bytes, so a RAW rewritten mid-copy leaves a stamp that no longer matches and extracts again.
    let stamp = std::fs::metadata(src).ok()?.modified().ok()?;
    let file = copy_path(dir, src);
    if !fresh(&file, stamp) {
        publish(dir, &file, src, stamp)?;
    }
    let h = imagesize::header(&file)?;
    Some(Extracted { file, width: h.width, height: h.height, orientation: h.orientation })
}

// The copy carries its RAW's mtime, and a symlink at the path is never a copy.
fn fresh(file: &Path, stamp: SystemTime) -> bool {
    std::fs::symlink_metadata(file)
        .map(|m| m.file_type().is_file() && m.len() > 0 && m.modified().ok() == Some(stamp))
        .unwrap_or(false)
}

// The orientation of the first Exif segment among the JPEG's leading segments; None when it names none.
fn head_orientation(head: &[u8]) -> Option<u16> {
    let mut at = 2;
    while head.get(at)? == &0xFF {
        let marker = *head.get(at + 1)?;
        if marker == 0xDA || marker == 0xD9 || ((0xC0..=0xCF).contains(&marker) && ![0xC4, 0xC8, 0xCC].contains(&marker)) {
            return None;
        }
        let len = u16::from_be_bytes([*head.get(at + 2)?, *head.get(at + 3)?]) as usize;
        let body = head.get(at + 4..at + 2 + len)?;
        if marker == 0xE1 && body.starts_with(EXIF_MAGIC) {
            return facts_from_slice(&body[EXIF_MAGIC.len()..], false).orientation;
        }
        at += 2 + len;
    }
    None
}

// Temp, exclusive create, rename: a planted path is never followed and a reader sees a whole copy or none.
fn publish(dir: &Path, file: &Path, src: &Path, stamp: SystemTime) -> Option<()> {
    let (preview, facts) = inspect(src)?;
    let preview = preview?;
    let mut input = open_regular(src)?;
    input.seek(SeekFrom::Start(preview.offset)).ok()?;
    let mut head = vec![0u8; preview.length.min(JPEG_PREFIX) as usize];
    input.read_exact(&mut head).ok()?;
    if !head.starts_with(&[0xFF, 0xD8]) {
        return None;
    }
    let turn = facts.orientation.filter(|o| (2..=8).contains(o)).filter(|_| head_orientation(&head).is_none());
    std::fs::DirBuilder::new().recursive(true).mode(DIR_MODE).create(dir).ok()?;
    let temp = file.with_extension(format!("{}.{}.tmp", std::process::id(), NEXT_TEMP.fetch_add(1, Ordering::Relaxed)));
    let _ = std::fs::remove_file(&temp);
    let mut out = std::fs::OpenOptions::new().write(true).create_new(true).mode(FILE_MODE).open(&temp).ok()?;
    let rest = preview.length - head.len() as u64;
    let written = (|| -> std::io::Result<bool> {
        out.write_all(&head[..2])?;
        if let Some(o) = turn {
            let mut seg = EXIF_ORIENT;
            seg[EXIF_ORIENT_AT..EXIF_ORIENT_AT + 2].copy_from_slice(&o.to_le_bytes());
            out.write_all(&seg)?;
        }
        out.write_all(&head[2..])?;
        let copied = std::io::copy(&mut input.take(rest), &mut out)?;
        out.set_modified(stamp)?;
        Ok(copied == rest)
    })();
    if !matches!(written, Ok(true)) || std::fs::rename(&temp, file).is_err() {
        let _ = std::fs::remove_file(&temp);
        return None;
    }
    Some(())
}

#[cfg(test)]
#[path = "rawpreview_tests.rs"]
mod tests;
