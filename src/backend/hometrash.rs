// Issue 261: Replace on a location with no Trash keeps the old item in the home Trash.
use crate::backend::trash::Entry;
use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;

// No GVFS backend implements trash, so gio trash refuses every path under its FUSE folder (sample: /run/user/1000/gvfs/smb-share:server=192.168.21.25,share=data/photos).
pub fn trashable(path: &Path) -> bool {
    let mut after_gvfs = false;
    for part in path.components() {
        let name = part.as_os_str().to_string_lossy();
        if after_gvfs && names_a_mount(&name) {
            return false;
        }
        after_gvfs = name.eq_ignore_ascii_case("gvfs");
    }
    true
}

// Sample input: "mtp:host=SAMSUNG_Android", a type of letters, digits and hyphens before the first colon.
fn names_a_mount(name: &str) -> bool {
    match name.find(':') {
        Some(end) if end > 0 => name[..end].chars().all(|c| c.is_ascii_alphanumeric() || c == '-'),
        _ => false,
    }
}

// Encodes a Trash file name for its URI: every byte outside the unreserved set rides as one uppercase %XX triplet per UTF-8 byte, with / kept literal.
pub(crate) fn percent_encode(s: &str) -> String {
    const UNRESERVED: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~/";
    let mut out = String::with_capacity(s.len());
    for b in s.as_bytes() {
        if UNRESERVED.contains(b) {
            out.push(*b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

// The home Trash gio restores from: the test override under cfg(test), else the data home's Trash.
#[cfg(test)]
thread_local! {
    static TRASH_ROOT: std::cell::RefCell<Option<PathBuf>> = const { std::cell::RefCell::new(None) };
}

// Points one test thread's home Trash at its own sandbox; no test may move anything into a Trash named by the process env.
#[cfg(test)]
pub(crate) fn set_test_trash_root(root: Option<PathBuf>) {
    TRASH_ROOT.with(|slot| *slot.borrow_mut() = root);
}

// Reads the override first, so a test without one refuses before any mkdir rather than touching a real Trash.
pub(crate) fn home_trash_root() -> Option<PathBuf> {
    #[cfg(test)]
    if let Some(root) = TRASH_ROOT.with(|slot| slot.borrow().clone()) {
        return Some(root);
    }
    #[cfg(test)]
    return None;
    #[cfg(not(test))]
    return crate::userfile::data_home().ok().map(|home| home.join("Trash"));
}

// The whole sentence a home Trash move that failed for any reason refuses with.
pub(crate) const HOME_TRASH_FAILED: &str = "the item already there could not be moved to the home Trash, so nothing was replaced";
// The whole sentence a home Trash move refuses with when the home Trash's filesystem has no room left.
pub(crate) const HOME_TRASH_FULL: &str = "there is not enough room in the home Trash for the item already there, so nothing was replaced";

// Names the refusal for a failed copy once the free room on the home Trash's filesystem is known.
pub(crate) fn sentence_after_copy(free_bytes: u64) -> &'static str {
    if free_bytes == 0 { HOME_TRASH_FULL } else { HOME_TRASH_FAILED }
}

// Names the refusal for a filesystem call that failed directly, where the errno is in hand.
pub(crate) fn sentence_for_io(error: &std::io::Error) -> &'static str {
    const ENOSPC: i32 = 28;
    if error.raw_os_error() == Some(ENOSPC) { HOME_TRASH_FULL } else { HOME_TRASH_FAILED }
}

#[repr(C)]
struct WallClock {
    sec: i32,
    min: i32,
    hour: i32,
    mday: i32,
    mon: i32,
    year: i32,
    wday: i32,
    yday: i32,
    isdst: i32,
    gmtoff: i64,
    zone: *const u8,
}

extern "C" {
    fn time(t: *mut i64) -> i64;
    fn localtime_r(timep: *const i64, result: *mut WallClock) -> *mut WallClock;
}

// Stamps a .trashinfo DeletionDate in local time, the way the desktop's own trash names it.
fn deletion_date_local() -> String {
    let now = unsafe { time(std::ptr::null_mut()) };
    let mut out = WallClock { sec: 0, min: 0, hour: 0, mday: 0, mon: 0, year: 0, wday: 0, yday: 0, isdst: 0, gmtoff: 0, zone: std::ptr::null() };
    if unsafe { localtime_r(&now, &mut out) }.is_null() {
        return "1970-01-01T00:00:00".to_string();
    }
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}", out.year + 1900, out.mon + 1, out.mday, out.hour, out.min, out.sec)
}

#[repr(C)]
struct FsFigures {
    bsize: u64,
    frsize: u64,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    favail: u64,
    fsid: u64,
    flag: u64,
    namemax: u64,
    spare: [i32; 6],
}

extern "C" {
    fn statvfs(path: *const std::os::raw::c_char, buf: *mut FsFigures) -> i32;
}

// Reads the free room on the home Trash's filesystem, so a failed copy on a full one says so.
fn free_bytes(dir: &Path) -> u64 {
    let Ok(path) = CString::new(dir.as_os_str().as_bytes()) else { return u64::MAX };
    let mut figures = FsFigures { bsize: 0, frsize: 0, blocks: 0, bfree: 0, bavail: 0, files: 0, ffree: 0, favail: 0, fsid: 0, flag: 0, namemax: 0, spare: [0; 6] };
    if unsafe { statvfs(path.as_ptr(), &mut figures) } != 0 {
        return u64::MAX;
    }
    figures.bavail.saturating_mul(figures.frsize)
}

// Names the first free Trash file name: the item's own name, then stem.2.ext past a collision.
fn candidate_names(file_name: &std::ffi::OsStr) -> Vec<String> {
    let plain = file_name.to_string_lossy().into_owned();
    let mut out = vec![plain.clone()];
    let (stem, ext) = match plain.rfind('.').filter(|dot| *dot > 0) {
        Some(dot) => plain.split_at(dot),
        None => (plain.as_str(), ""),
    };
    for n in 2..1000 {
        out.push(format!("{stem}.{n}{ext}"));
    }
    out
}

// Confirms every byte the copy laid down, files and the folders holding them, before the original goes.
fn sync_tree(root: &Path) -> std::io::Result<()> {
    let meta = root.symlink_metadata()?;
    if meta.file_type().is_symlink() {
        return Ok(());
    }
    if meta.is_dir() {
        for entry in std::fs::read_dir(root)? {
            sync_tree(&entry?.path())?;
        }
    }
    std::fs::File::open(root)?.sync_all()
}

// Moves one replaced item into the home Trash the freedesktop way and answers its trash:/// entry.
pub(crate) fn trash_to_home(original: &Path) -> Result<Entry, String> {
    let Some(root) = home_trash_root() else { return Err(HOME_TRASH_FAILED.to_string()) };
    let (files, info) = (root.join("files"), root.join("info"));
    for dir in [&files, &info] {
        std::fs::DirBuilder::new().mode(0o700).recursive(true).create(dir).map_err(|e| sentence_for_io(&e).to_string())?;
    }
    let Some(name) = original.file_name() else { return Err(HOME_TRASH_FAILED.to_string()) };
    for candidate in candidate_names(name) {
        let info_path = info.join(format!("{candidate}.trashinfo"));
        let mut info_file = match std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&info_path) {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(sentence_for_io(&e).to_string()),
        };
        let body = format!("[Trash Info]\nPath={}\nDeletionDate={}\n", percent_encode(&original.to_string_lossy()), deletion_date_local());
        if let Err(e) = std::io::Write::write_all(&mut info_file, body.as_bytes()) {
            let _ = std::fs::remove_file(&info_path);
            return Err(sentence_for_io(&e).to_string());
        }
        if let Err(e) = info_file.sync_all() {
            let _ = std::fs::remove_file(&info_path);
            return Err(sentence_for_io(&e).to_string());
        }
        let files_path = files.join(&candidate);
        if let Err(reason) = place_copy(original, &files_path) {
            drop_orphan(&files_path, &info_path);
            return Err(reason);
        }
        if let Err(e) = sync_tree(&files_path).and(sync_dir(&files)).and(sync_dir(&info)) {
            drop_orphan(&files_path, &info_path);
            return Err(sentence_for_io(&e).to_string());
        }
        take_original(original, &files_path, &info_path)?;
        return Ok(Entry { original: original.to_path_buf(), uri: format!("trash:///{}", percent_encode(&candidate)) });
    }
    Err(HOME_TRASH_FAILED.to_string())
}

// Copies the original into the Trash files folder whole, a symlink as a link and never followed.
fn place_copy(original: &Path, files_path: &Path) -> Result<(), String> {
    let idle = AtomicBool::new(false);
    let mut sink = |_: u64, _: u64| {};
    let mut progress = crate::backend::copyfile::Progress { cancel: &idle, on_bytes: &mut sink, tree: None,
        partial: None, manifest: None, durability: None, for_move: false };
    match crate::backend::copyfile::copy_any(original, files_path, &mut progress) {
        Ok(()) => Ok(()),
        Err(_) => Err(sentence_after_copy(free_bytes(files_path)).to_string()),
    }
}

// Confirms a Trash folder itself, so the entry above names bytes the drive already holds.
fn sync_dir(dir: &Path) -> std::io::Result<()> {
    std::fs::File::open(dir)?.sync_all()
}

// Deletes a Trash copy and its info file, which is safe only because the original still stands.
fn drop_orphan(files_path: &Path, info_path: &Path) {
    let _ = std::fs::remove_file(info_path);
    match files_path.symlink_metadata() {
        Ok(meta) if meta.is_dir() && !meta.file_type().is_symlink() => {
            let _ = std::fs::remove_dir_all(files_path);
        }
        Ok(_) => {
            let _ = std::fs::remove_file(files_path);
        }
        Err(_) => {}
    }
}

// Removes the original only after its copy synced, keeping a half-removed folder's copy for its owner.
fn take_original(original: &Path, files_path: &Path, info_path: &Path) -> Result<(), String> {
    let is_dir = original.symlink_metadata().map(|m| m.is_dir() && !m.file_type().is_symlink()).unwrap_or(false);
    let removed = if is_dir { std::fs::remove_dir_all(original).map(|_| ()) } else { std::fs::remove_file(original) };
    match removed {
        Ok(()) => Ok(()),
        Err(e) if !is_dir && original.symlink_metadata().is_ok() => {
            drop_orphan(files_path, info_path);
            Err(sentence_for_io(&e).to_string())
        }
        Err(e) => Err(sentence_for_io(&e).to_string()),
    }
}

#[cfg(test)]
#[path = "hometrash_tests.rs"]
mod tests;
