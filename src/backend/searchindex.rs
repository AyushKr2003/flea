// The session's snapshot: every relative path walked once, folded once, scored per query.
use crate::backend::fuzzy::{fold_packed, Hay, Packed};
use std::borrow::Cow;
use std::collections::HashSet;
use std::ffi::{OsStr, OsString};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

// Past this many rows the walk stops adding; 200k at the measured 172 bytes each is about 34 MiB worst case, handed back on close.
pub(crate) const SESSION_MAX_ENTRIES: usize = 200_000;
// One worker per core up to four; a cold 100k tree is seeker-hostile past that on spinning disks.
pub(crate) const WALK_THREADS: usize = 4;
// Below this many candidates scoring stays serial; a thread per keystroke costs more than it saves.
pub(crate) const PARALLEL_SCORE_AT: usize = 2048;

// One indexed row as u32 offsets into the arenas, capped at 4 GiB as Listing is, with no heap allocation of its own.
pub(crate) struct Row {
    path_off: u32,
    path_len: u32,
    fold_off: u32,
    fold_len: u32,
    flags: u8,
}

// The raw bytes of a path that is not UTF-8, keyed by the path's offset in the arena, which holds its lossy text.
struct RawPath {
    path_off: u32,
    bytes: Box<[u8]>,
}

// The arena: one path string, one byte string and one word string shared by every row.
pub(crate) struct Index {
    paths: String,
    raw: Vec<RawPath>,
    ascii: Vec<u8>,
    wide: Vec<u32>,
    rows: Vec<Row>,
    pub capped: bool,
    // Test seams: arena repacks and rows a patch reads, so its cost is counted, never timed.
    #[cfg(test)]
    pub(crate) compactions: usize,
    #[cfg(test)]
    pub(crate) scanned: std::sync::atomic::AtomicUsize,
}

// Bytes the arena holds: path bytes, the raw bytes of names that are not UTF-8, one byte or word per folded char and one row each, counted not sampled.
pub(crate) fn index_bytes(index: &Index) -> usize {
    let raw: usize = index.raw.iter().map(|path| size_of::<RawPath>() + path.bytes.len()).sum();
    index.paths.len() + raw + index.ascii.len() + index.wide.len() * 4 + index.rows.len() * size_of::<Row>()
}

// A dot-prefixed name is hidden, matching scan.rs's own rule.
pub(crate) fn is_hidden(name: &OsStr) -> bool {
    name.as_bytes().first() == Some(&b'.')
}

impl Row {
    fn is_dir(&self) -> bool {
        self.flags & 1 != 0
    }

    fn is_wide(&self) -> bool {
        self.flags & 2 != 0
    }

    fn is_raw(&self) -> bool {
        self.flags & 4 != 0
    }
}

impl Index {
    pub(crate) fn new() -> Index {
        Index {
            paths: String::new(),
            raw: Vec::new(),
            ascii: Vec::new(),
            wide: Vec::new(),
            rows: Vec::new(),
            capped: false,
            #[cfg(test)]
            compactions: 0,
            #[cfg(test)]
            scanned: std::sync::atomic::AtomicUsize::new(0),
        }
    }

    pub(crate) fn len(&self) -> usize {
        self.rows.len()
    }

    fn path_range(&self, row: usize) -> std::ops::Range<usize> {
        let off = self.rows[row].path_off as usize;
        off..off + self.rows[row].path_len as usize
    }

    pub(crate) fn path(&self, row: usize) -> &str {
        &self.paths[self.path_range(row)]
    }

    // The path as the filesystem spells it: the arena text, unless the name was not UTF-8.
    pub(crate) fn raw(&self, row: usize) -> &[u8] {
        if !self.rows[row].is_raw() {
            return &self.paths.as_bytes()[self.path_range(row)];
        }
        let off = self.rows[row].path_off;
        let at = self.raw.binary_search_by_key(&off, |path| path.path_off).expect("a raw row keeps its bytes");
        &self.raw[at].bytes
    }

    // The path's byte length, the rank order's second key, read with no slice of the arena.
    pub(crate) fn path_len(&self, row: usize) -> usize {
        self.rows[row].path_len as usize
    }

    pub(crate) fn is_dir(&self, row: usize) -> bool {
        self.rows[row].is_dir()
    }

    pub(crate) fn hay(&self, row: usize) -> Hay<'_> {
        let off = self.rows[row].fold_off as usize;
        let len = self.rows[row].fold_len as usize;
        if self.rows[row].is_wide() {
            Hay::Wide(&self.wide[off..off + len])
        } else {
            Hay::Ascii(&self.ascii[off..off + len])
        }
    }

    // Adds one row unless the cap is reached; past it the walk stops adding and the count stands.
    pub(crate) fn push(&mut self, path: impl AsRef<OsStr>, is_dir: bool) {
        if self.rows.len() >= SESSION_MAX_ENTRIES {
            self.capped = true;
            return;
        }
        let path = path.as_ref();
        let text = path.to_string_lossy();
        let path_off = self.paths.len() as u32;
        let path_len = text.len() as u32;
        self.paths.push_str(&text);
        let (fold_off, fold_len, mut flags) = match fold_packed(&text) {
            Packed::Ascii(bytes) => {
                let off = self.ascii.len() as u32;
                let len = bytes.len() as u32;
                self.ascii.extend(bytes);
                (off, len, u8::from(is_dir))
            }
            Packed::Wide(words) => {
                let off = self.wide.len() as u32;
                let len = words.len() as u32;
                self.wide.extend(words);
                (off, len, u8::from(is_dir) | 2)
            }
        };
        if matches!(text, Cow::Owned(_)) {
            flags |= 4;
            self.raw.push(RawPath { path_off, bytes: path.as_bytes().into() });
        }
        self.rows.push(Row { path_off, path_len, fold_off, fold_len, flags });
    }

    // Keeps exactly the named rows, repacking every arena, so a removal frees what it dropped.
    fn compact(&mut self, kept: &[usize]) {
        #[cfg(test)]
        {
            self.compactions += 1;
        }
        let mut paths = String::new();
        let mut raw = Vec::new();
        let mut ascii = Vec::new();
        let mut wide = Vec::new();
        let mut rows = Vec::with_capacity(kept.len());
        for &i in kept {
            let row = &self.rows[i];
            let path_range = self.path_range(i);
            let path_off = paths.len() as u32;
            let path_len = row.path_len;
            paths.push_str(&self.paths[path_range]);
            if row.is_raw() {
                raw.push(RawPath { path_off, bytes: self.raw(i).into() });
            }
            let fold_range = row.fold_off as usize..(row.fold_off + row.fold_len) as usize;
            let (fold_off, flags) = if row.is_wide() {
                let off = wide.len() as u32;
                wide.extend(&self.wide[fold_range]);
                (off, row.flags)
            } else {
                let off = ascii.len() as u32;
                ascii.extend(&self.ascii[fold_range]);
                (off, row.flags)
            };
            rows.push(Row { path_off, path_len, fold_off, fold_len: row.fold_len, flags });
        }
        self.paths = paths;
        self.raw = raw;
        self.ascii = ascii;
        self.wide = wide;
        self.rows = rows;
    }

    // Reconciles one scope-relative directory in one pass and one repack; false when its mount does not answer.
    pub(crate) fn patch_dir(&mut self, root: &Path, rel: &Path, hidden: bool, body: &str) -> bool {
        let rel = rel.as_os_str();
        let dir = if rel.is_empty() { root.to_path_buf() } else { root.join(rel) };
        let Ok(listing) = read_bounded(&dir, body) else { return false };
        let prefix: Vec<u8> = if rel.is_empty() { Vec::new() } else { [rel.as_bytes(), b"/"].concat() };
        // A directory that is gone drops itself and its subtree; the scope itself drops every row.
        let Some(listing) = listing else {
            let kept: Vec<usize> = (0..self.rows.len())
                .filter(|&row| !rel.is_empty() && self.raw(row) != rel.as_bytes() && !self.raw(row).starts_with(&prefix))
                .collect();
            self.compact(&kept);
            return true;
        };
        let seen: Vec<(Vec<u8>, bool)> = listing
            .into_iter()
            .filter(|(name, _)| hidden || !is_hidden(name))
            .map(|(name, is_dir)| ([prefix.as_slice(), name.as_bytes()].concat(), is_dir))
            .collect();
        let names: HashSet<&[u8]> = seen.iter().map(|(child, _)| child.as_slice()).collect();
        let mut kept = Vec::with_capacity(self.rows.len());
        let mut present: HashSet<Vec<u8>> = HashSet::new();
        for row in 0..self.rows.len() {
            #[cfg(test)]
            self.scanned.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let path = self.raw(row);
            let Some(below) = path.strip_prefix(prefix.as_slice()) else {
                kept.push(row);
                continue;
            };
            let child = &path[..prefix.len() + below.iter().position(|&byte| byte == b'/').unwrap_or(below.len())];
            if names.contains(child) {
                kept.push(row);
                if child.len() == path.len() {
                    present.insert(path.to_vec());
                }
            }
        }
        if kept.len() < self.rows.len() {
            self.compact(&kept);
        }
        let mut added_dirs = Vec::new();
        for (child, is_dir) in seen {
            if !present.contains(&child) {
                if is_dir {
                    added_dirs.push(child.clone());
                }
                self.push(OsStr::from_bytes(&child), is_dir);
            }
        }
        if !added_dirs.is_empty() {
            self.fill_subtrees(root, &added_dirs, hidden, body);
        }
        true
    }

    // Walks newly added directories in, so a moved tree lands whole; rows already under them are read once.
    fn fill_subtrees(&mut self, root: &Path, added: &[Vec<u8>], hidden: bool, body: &str) {
        let prefixes: Vec<Vec<u8>> = added.iter().map(|dir| [dir.as_slice(), b"/"].concat()).collect();
        let mut present: HashSet<Vec<u8>> = HashSet::new();
        for row in 0..self.rows.len() {
            #[cfg(test)]
            self.scanned.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let path = self.raw(row);
            if prefixes.iter().any(|prefix| path.starts_with(prefix)) {
                present.insert(path.to_vec());
            }
        }
        let mut pending = added.to_vec();
        while let Some(dir_rel) = pending.pop() {
            if self.capped {
                return;
            }
            let Ok(Some(entries)) = read_bounded(&root.join(OsStr::from_bytes(&dir_rel)), body) else { continue };
            for (name, is_dir) in entries {
                if !hidden && is_hidden(&name) {
                    continue;
                }
                let child = [dir_rel.as_slice(), b"/", name.as_bytes()].concat();
                if present.insert(child.clone()) {
                    self.push(OsStr::from_bytes(&child), is_dir);
                    if is_dir {
                        pending.push(child);
                    }
                }
            }
        }
    }
}

// One directory as (name, is_dir) pairs, or None when it cannot be read; d_type answers is_dir with no stat.
fn read_listing(dir: &Path) -> Option<Vec<(OsString, bool)>> {
    let rd = std::fs::read_dir(dir).ok()?;
    let mut out = Vec::new();
    for entry in rd.flatten() {
        let is_dir = entry.file_type().map(|kind| kind.is_dir()).unwrap_or(false);
        out.push((entry.file_name(), is_dir));
    }
    Some(out)
}

// One directory read under the mount bound, so a patch on a dead server costs one deadline and changes nothing.
fn read_bounded(dir: &Path, body: &str) -> Result<Option<Vec<(OsString, bool)>>, crate::error::FleaError> {
    let owned = dir.to_path_buf();
    super::iomount::call(dir, body, "search", move || read_listing(&owned))
}

// One directory as (name, is_dir) pairs; an unreadable directory answers empty, as scan.rs's phase one skips it.
pub(crate) fn read_entries(dir: &Path) -> Vec<(OsString, bool)> {
    read_listing(dir).unwrap_or_default()
}

// Scores candidates with the session's scorer; wide indexes split over the same walker bound.
pub(crate) fn score_all(fuzzy: &crate::backend::fuzzy::Fuzzy, rows: &[usize], index: &Index) -> Vec<(i32, usize)> {
    if rows.len() < PARALLEL_SCORE_AT {
        return rows
            .iter()
            .filter_map(|&row| fuzzy.score_pre_folded(index.hay(row)).map(|score| (score, row)))
            .collect();
    }
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1).clamp(1, WALK_THREADS);
    let chunk = rows.len().div_ceil(threads);
    std::thread::scope(|scope| {
        let mut handles = Vec::with_capacity(threads);
        for part in rows.chunks(chunk) {
            handles.push(scope.spawn(move || {
                part.iter()
                    .filter_map(|&row| fuzzy.score_pre_folded(index.hay(row)).map(|score| (score, row)))
                    .collect::<Vec<_>>()
            }));
        }
        let mut out = Vec::with_capacity(rows.len());
        for handle in handles {
            out.extend(handle.join().unwrap_or_else(|panic| std::panic::resume_unwind(panic)));
        }
        out
    })
}

#[cfg(test)]
#[path = "searchindex_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "searchraw_tests.rs"]
mod raw_tests;
