// Undo puts a home Trash entry back in-process, the way gvfsd-trash restores it, when the entry's own record proves it.
use crate::backend::hometrash::{home_trash_root, info_name, sync_dir};
use crate::backend::trash::Entry;
use crate::paths::percent_decode_bytes;
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;

// The whole sentence undo refuses with when something already stands where the trashed item was.
pub(crate) const RESTORE_TAKEN: &str = "something already stands where that item was, so undo left it in the Trash";

// None means this entry is not one the home Trash proves, so gio restores it exactly as before.
pub(crate) fn restore_from_home(entry: &Entry) -> Option<Result<(), String>> {
    let root = home_trash_root()?;
    let raw = percent_decode_bytes(entry.uri.strip_prefix("trash:///")?);
    // Only a top-level entry; a name inside a trashed folder, or a dot name, stays gio's.
    if raw.is_empty() || raw == b"." || raw == b".." || raw.contains(&b'/') {
        return None;
    }
    let name = OsStr::from_bytes(&raw);
    let (files, info) = (root.join("files"), root.join("info"));
    let (kept, record) = (files.join(name), info.join(info_name(name)));
    kept.symlink_metadata().ok()?;
    if recorded_path(&std::fs::read(&record).ok()?)? != entry.original.as_os_str().as_bytes() {
        return None;
    }
    let parent = entry.original.parent()?;
    // gio recreates a missing original folder before it moves the item back.
    std::fs::create_dir_all(parent).ok()?;
    match crate::backend::renamecompat::rename_noreplace(&kept, &entry.original) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => return Some(Err(RESTORE_TAKEN.to_string())),
        // EXDEV or any other failure leaves the item in the Trash for gio.
        Err(_) => return None,
    }
    let _ = std::fs::remove_file(&record);
    // The item is back already, so a folder that will not sync is not a failure.
    for dir in [parent, files.as_path(), info.as_path()] {
        let _ = sync_dir(dir);
    }
    Some(Ok(()))
}

// The raw bytes a .trashinfo record's Path= names; its value is ASCII once encoded.
// Sample input: "[Trash Info]\nPath=/home/u/caf%E9.txt\nDeletionDate=2026-10-09T22:41:03\n"
fn recorded_path(body: &[u8]) -> Option<Vec<u8>> {
    let text = std::str::from_utf8(body).ok()?;
    text.lines().find_map(|line| line.strip_prefix("Path=")).map(percent_decode_bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::hometrash::{percent_encode, set_test_trash_root};
    use crate::backend::testdir::TestDir;

    // Sample input: uri "trash:///sub%2Ff.txt" names sub/f.txt under files/, which only gio's own restore handles.
    #[test]
    fn a_name_inside_a_trashed_folder_or_a_dot_name_is_left_to_gio() {
        let d = TestDir::new("homerestore-nested");
        let trash = d.dir("Trash");
        d.dir("Trash/files/sub");
        d.dir("Trash/info/sub");
        let kept = d.file("Trash/files/sub/f.txt", "inside");
        let original = d.join("to/f.txt");
        let record = d.file("Trash/info/sub/f.txt.trashinfo", &format!("[Trash Info]\nPath={}\nDeletionDate=2026-10-09T00:00:00\n", percent_encode(original.as_os_str().as_bytes())));
        set_test_trash_root(Some(trash));
        for uri in ["trash:///sub/f.txt", "trash:///sub%2Ff.txt", "trash:///.", "trash:///..", "trash:///"] {
            let entry = Entry { original: original.clone(), uri: uri.to_string(), before: Vec::new(), trashed_at: String::new() };
            assert!(restore_from_home(&entry).is_none(), "{uri} is gio's to restore");
        }
        assert!(kept.is_file() && record.is_file(), "nothing moved and no record went");
        assert!(!original.exists(), "nothing landed at the original");
    }
}
