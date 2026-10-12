// The sample cache: three PNGs per look, named by file, mtime, colours, sizes and text, trimmed oldest first.
use crate::backend::fontinfo::render::{Ask, SAMPLES};
use crate::backend::md5;
use crate::backend::thumbcache::uri_for;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

const CACHE_LEAF: &str = "flea/fonts";
// 300 looks of three files; past it the oldest go until 200 looks remain.
const CACHE_MAX_FILES: usize = 900;
const CACHE_KEEP_FILES: usize = 600;
// A work folder older than this belongs to a backend that was killed mid-job.
const STALE_WORK: Duration = Duration::from_secs(600);
pub(super) const WORK_TAG: &str = "font";
const PNG_SIGNATURE: [u8; 8] = [0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a];

pub(super) fn root() -> PathBuf {
    crate::userfile::cache_home().join(CACHE_LEAF)
}

pub(super) fn key(font: &Path, meta: &std::fs::Metadata, ask: &Ask) -> String {
    let sizes: Vec<String> = ask.sizes.iter().map(|s| s.to_string()).collect();
    let stamp = format!("{}\n{}.{}\n{}\n{}\n{}\n{}", uri_for(font), meta.mtime(), meta.mtime_nsec(), ask.fg, ask.bg, sizes.join(","), ask.text);
    md5::hex(stamp.as_bytes())
}

pub(super) fn entry(root: &Path, key: &str, i: usize) -> PathBuf {
    root.join(format!("{}-{}.png", key, i))
}

pub(super) fn is_png(path: &Path) -> bool {
    use std::io::Read;
    let Ok(meta) = path.symlink_metadata() else { return false };
    let mut head = [0u8; 8];
    meta.is_file() && std::fs::File::open(path).and_then(|mut f| f.read_exact(&mut head)).is_ok() && head == PNG_SIGNATURE
}

// A hit needs all three, each a plain file: a planted symlink in the cache is a miss, never read.
pub(super) fn cached(root: &Path, key: &str) -> Option<Vec<PathBuf>> {
    let files: Vec<PathBuf> = (0..SAMPLES).map(|i| entry(root, key, i)).collect();
    files.iter().all(|f| is_png(f)).then_some(files)
}

// Oldest entries first, and only names this module writes; a killed run's work folder goes once it is stale.
pub(super) fn prune(root: &Path) {
    let Ok(dir) = std::fs::read_dir(root) else { return };
    let mut looks: Vec<(SystemTime, PathBuf)> = Vec::new();
    for item in dir.flatten() {
        let name = item.file_name().to_string_lossy().to_string();
        let Ok(meta) = item.metadata() else { continue };
        let Ok(when) = meta.modified() else { continue };
        let ours = name.len() == 38 && name.ends_with(".png") && name[32..34].starts_with('-') && matches!(name.as_bytes()[33], b'0'..=b'2')
            && name[..32].bytes().all(|b| b.is_ascii_hexdigit());
        if ours && meta.is_file() {
            looks.push((when, item.path()));
        } else if name.starts_with(&format!("{}{}-", crate::backend::archivework::WORK_PREFIX, WORK_TAG))
            && meta.is_dir() && when.elapsed().is_ok_and(|age| age > STALE_WORK) {
            let _ = std::fs::remove_dir_all(item.path());
        }
    }
    if looks.len() > CACHE_MAX_FILES {
        looks.sort();
        for (_, path) in &looks[..looks.len() - CACHE_KEEP_FILES] {
            let _ = std::fs::remove_file(path);
        }
    }
}

#[cfg(test)]
#[path = "cache_tests.rs"]
mod tests;
