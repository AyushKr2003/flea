// The session's snapshot: every relative path walked once, folded once, scored per query.
use crate::backend::fuzzy::{fold_packed, Hay, Packed};
use std::path::Path;

// Past this many rows the walk stops adding; 200k at the measured 172 bytes each is about 34 MiB worst case, handed back on close.
pub(crate) const SESSION_MAX_ENTRIES: usize = 200_000;
// One worker per core up to four; a cold 100k tree is seeker-hostile past that on spinning disks.
pub(crate) const WALK_THREADS: usize = 4;
// Below this many candidates scoring stays serial; a thread per keystroke costs more than it saves.
pub(crate) const PARALLEL_SCORE_AT: usize = 2048;

// One indexed row: offsets into the arenas, so no row holds a heap allocation of its own.
// corner: u32 offsets cap the arenas at 4 GiB, which no scope reaches; Listing carries the same bound.
pub(crate) struct Row {
    path_off: u32,
    path_len: u32,
    fold_off: u32,
    fold_len: u32,
    flags: u8,
}

// The arena: one path string, one byte string and one word string shared by every row.
pub(crate) struct Index {
    paths: String,
    ascii: Vec<u8>,
    wide: Vec<u32>,
    rows: Vec<Row>,
    pub capped: bool,
}

// Bytes the arena holds: path bytes plus one byte or word per folded char plus one row each, counted not sampled.
pub(crate) fn index_bytes(index: &Index) -> usize {
    index.paths.len() + index.ascii.len() + index.wide.len() * 4 + index.rows.len() * size_of::<Row>()
}

impl Row {
    fn is_dir(&self) -> bool {
        self.flags & 1 != 0
    }

    fn is_wide(&self) -> bool {
        self.flags & 2 != 0
    }
}

impl Index {
    pub(crate) fn new() -> Index {
        Index { paths: String::new(), ascii: Vec::new(), wide: Vec::new(), rows: Vec::new(), capped: false }
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
    pub(crate) fn push(&mut self, path: String, is_dir: bool) {
        if self.rows.len() >= SESSION_MAX_ENTRIES {
            self.capped = true;
            return;
        }
        let path_off = self.paths.len() as u32;
        let path_len = path.len() as u32;
        self.paths.push_str(&path);
        let (fold_off, fold_len, flags) = match fold_packed(&path) {
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
        self.rows.push(Row { path_off, path_len, fold_off, fold_len, flags });
    }

    // True when the arena already holds the path; patches are rare, so a scan costs nothing.
    fn contains(&self, path: &str) -> bool {
        (0..self.rows.len()).any(|row| self.path(row) == path)
    }

    // Direct children of one directory, read off the single pass a patch already pays.
    fn direct_children(&self, rel: &str) -> Vec<usize> {
        let mut out = Vec::new();
        for i in 0..self.rows.len() {
            let path = &self.paths[self.path_range(i)];
            let parent = match path.rfind('/') {
                Some(cut) => &path[..cut],
                None => "",
            };
            if parent == rel {
                out.push(i);
            }
        }
        out
    }

    // Removes every row at or under the relative path, compacting the arenas behind it.
    fn remove_under(&mut self, rel: &str) {
        if rel.is_empty() {
            self.paths.clear();
            self.ascii.clear();
            self.wide.clear();
            self.rows.clear();
            return;
        }
        let prefix = format!("{}/", rel);
        let mut kept = Vec::with_capacity(self.rows.len());
        for i in 0..self.rows.len() {
            let path = &self.paths[self.path_range(i)];
            if path != rel && !path.starts_with(&prefix) {
                kept.push(i);
            }
        }
        self.compact(&kept);
    }

    // Keeps exactly the named rows, repacking every arena, so a removal frees what it dropped.
    fn compact(&mut self, kept: &[usize]) {
        let mut paths = String::new();
        let mut ascii = Vec::new();
        let mut wide = Vec::new();
        let mut rows = Vec::with_capacity(kept.len());
        for &i in kept {
            let row = &self.rows[i];
            let path_range = self.path_range(i);
            let path_off = paths.len() as u32;
            let path_len = row.path_len;
            paths.push_str(&self.paths[path_range]);
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
        self.ascii = ascii;
        self.wide = wide;
        self.rows = rows;
    }

    // Re-reads one scope-relative directory and reconciles its rows, so a patch costs one readdir.
    // A newly added directory's subtree is walked in, so a moved tree lands whole, not just its top.
    pub(crate) fn patch_dir(&mut self, root: &Path, rel: &str, hidden: bool) {
        let dir = if rel.is_empty() { root.to_path_buf() } else { root.join(rel) };
        let Ok(rd) = std::fs::read_dir(&dir) else {
            self.remove_under(rel);
            return;
        };
        let mut seen: Vec<(String, bool)> = Vec::new();
        for entry in rd.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !hidden && name.starts_with('.') {
                continue;
            }
            let is_dir = entry.file_type().map(|kind| kind.is_dir()).unwrap_or(false);
            let child = if rel.is_empty() { name } else { format!("{}/{}", rel, name) };
            seen.push((child, is_dir));
        }
        let mut added_dirs = Vec::new();
        for i in self.direct_children(rel) {
            let path = self.path(i).to_string();
            if !seen.iter().any(|(child, _)| *child == path) {
                self.remove_under(&path);
            }
        }
        for (child, is_dir) in seen {
            if !self.contains(&child) {
                self.push(child.clone(), is_dir);
                if is_dir {
                    added_dirs.push(child);
                }
            }
        }
        for added in added_dirs {
            self.fill_subtree(root, &added, hidden);
        }
    }

    // Walks a newly added directory's subtree in, so a moved tree lands whole.
    fn fill_subtree(&mut self, root: &Path, rel: &str, hidden: bool) {
        let mut pending = vec![rel.to_string()];
        while let Some(dir_rel) = pending.pop() {
            if self.capped {
                return;
            }
            let dir = root.join(&dir_rel);
            for (name, is_dir) in read_entries(&dir) {
                if !hidden && name.starts_with('.') {
                    continue;
                }
                let child = format!("{}/{}", dir_rel, name);
                if !self.contains(&child) {
                    self.push(child.clone(), is_dir);
                    if is_dir {
                        pending.push(child);
                    }
                }
            }
        }
    }
}

// One directory as (name, is_dir) pairs; d_type is free and answers is_dir with no stat.
pub(crate) fn read_entries(dir: &Path) -> Vec<(String, bool)> {
    // An unreadable directory answers empty in silence, as scan.rs's phase one skips an unreadable entry.
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(dir) else { return out };
    for entry in rd.flatten() {
        let is_dir = entry.file_type().map(|kind| kind.is_dir()).unwrap_or(false);
        out.push((entry.file_name().to_string_lossy().into_owned(), is_dir));
    }
    out
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
            out.extend(handle.join().unwrap_or_default());
        }
        out
    })
}

#[cfg(test)]
#[path = "searchindex_tests.rs"]
mod tests;
