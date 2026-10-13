use super::{imagesize, md5, regfile, thumbcache};
use crate::oflags::O_NOFOLLOW;
use std::fs::{FileTimes, Metadata};
use std::io::Read;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, SystemTime};

// The companion preview cache uses the same limits as the cached camera previews.
const MAX_FILES: usize = 4096;
const MAX_BYTES: u64 = 512 * 1_048_576;
const SCAN_EVERY: u32 = 32;
const READER_GRACE: Duration = Duration::from_secs(60);
static PUBLISHED: AtomicU32 = AtomicU32::new(0);

pub fn root() -> PathBuf {
    thumbcache::default_root().join("flea-html")
}

// Sample key: path /a/index.html, 120 bytes, mtime 9 s and 20 ns, width 984; each dimension invalidates independently.
pub fn key(path: &Path, meta: &Metadata, width: usize) -> String {
    md5::hex(format!("html-v1\0{}\0{}\0{}\0{}\0{}", thumbcache::uri_for(path), meta.len(), meta.mtime(), meta.mtime_nsec(), width).as_bytes())
}

pub fn hit(file: &Path, width: usize) -> bool {
    let Ok(mut opened) = regfile::open_if_regular(file, O_NOFOLLOW) else { return false };
    let mut header = [0; 24];
    if opened.read_exact(&mut header).is_err() || !header.starts_with(b"\x89PNG\r\n\x1a\n") { return false }
    let Some((w, h)) = imagesize::from_header(&header) else { return false };
    if w as usize != width || h == 0 || h > 8000 {
        return false;
    }
    let _ = opened.set_times(FileTimes::new().set_accessed(SystemTime::now()));
    true
}

fn used(meta: &Metadata) -> SystemTime {
    SystemTime::UNIX_EPOCH + Duration::new(meta.ctime().max(0) as u64, meta.ctime_nsec().max(0) as u32)
}

pub fn evict(dir: &Path) {
    if PUBLISHED.fetch_add(1, Ordering::Relaxed) % SCAN_EVERY == 0 {
        trim(dir, MAX_FILES, MAX_BYTES, SystemTime::now());
    }
}

// Recently served images survive the scan so a reply can reach its asynchronous Image reader.
fn trim(dir: &Path, files: usize, bytes: u64, now: SystemTime) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut old = Vec::new();
    let (mut count, mut total) = (0, 0u64);
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(meta) = path.symlink_metadata() else { continue };
        if meta.is_dir() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let pid = name.strip_prefix(".flea-work-html-").and_then(|tail| tail.split('-').next()).and_then(|n| n.parse::<u32>().ok());
            if pid.is_some_and(|pid| !Path::new(&format!("/proc/{pid}")).exists())
                && now.duration_since(used(&meta)).is_ok_and(|age| age > READER_GRACE) {
                let _ = std::fs::remove_dir_all(&path);
            }
            continue;
        }
        if !meta.is_file() || path.extension().is_none_or(|ext| ext != "png") {
            continue;
        }
        count += 1;
        total = total.saturating_add(meta.len());
        if now.duration_since(used(&meta)).is_ok_and(|age| age > READER_GRACE) {
            old.push((used(&meta), path, meta.len()));
        }
    }
    old.sort();
    for (seen, path, size) in old {
        if count <= files && total <= bytes { break }
        let Ok(meta) = path.symlink_metadata() else { continue };
        if meta.is_file() && used(&meta) <= seen && std::fs::remove_file(&path).is_ok() {
            count -= 1;
            total = total.saturating_sub(size);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::testdir::TestDir;

    #[test]
    fn cache_key_includes_path_size_nanosecond_mtime_and_width() {
        let d = TestDir::new("html-cache-key");
        let a = d.file("a.html", "a\n");
        let b = d.file("b.html", "b\n");
        let stamp = SystemTime::UNIX_EPOCH + Duration::new(9, 20);
        for p in [&a, &b] { std::fs::File::open(p).unwrap().set_times(FileTimes::new().set_modified(stamp)).unwrap() }
        let meta = a.metadata().unwrap();
        let first = key(&a, &meta, 984);
        assert_eq!(first, key(&a, &meta, 984));
        assert_ne!(first, key(&b, &b.metadata().unwrap(), 984));
        assert_ne!(first, key(&a, &meta, 300));
        std::fs::File::open(&a).unwrap().set_times(FileTimes::new().set_modified(stamp + Duration::from_nanos(1))).unwrap();
        assert_ne!(first, key(&a, &a.metadata().unwrap(), 984));
        std::fs::write(&a, "longer\n").unwrap();
        std::fs::File::open(&a).unwrap().set_times(FileTimes::new().set_modified(stamp)).unwrap();
        assert_ne!(first, key(&a, &a.metadata().unwrap(), 984));
    }

    #[test]
    fn eviction_obeys_both_limits_and_leaves_recent_readers() {
        let d = TestDir::new("html-cache-limit");
        for n in 0..4 { d.file(&format!("{n}.png"), "ten bytes!"); }
        d.file("other.txt", "keep");
        let future = SystemTime::now() + Duration::from_secs(120);
        trim(d.path(), 2, 15, future);
        let pngs = std::fs::read_dir(d.path()).unwrap().flatten().filter(|e| e.path().extension().is_some_and(|x| x == "png")).count();
        assert_eq!(pngs, 1);
        assert!(d.join("other.txt").exists());
        d.file("recent.png", "ten bytes!");
        trim(d.path(), 0, 0, SystemTime::now());
        assert!(d.join("recent.png").exists());
    }
}
