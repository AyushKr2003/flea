// The session's snapshot: every relative path walked once, folded once, scored per query.
use crate::backend::fuzzy::{fold_packed, rank_order, Hay, Packed};
use std::cmp::{Ordering as CmpOrdering, Reverse};
use std::collections::HashSet;
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

// The arena: one path string, one byte string and one word string shared by every row.
pub(crate) struct Index {
    paths: String,
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
        Index {
            paths: String::new(),
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

    // Keeps exactly the named rows, repacking every arena, so a removal frees what it dropped.
    fn compact(&mut self, kept: &[usize]) {
        #[cfg(test)]
        {
            self.compactions += 1;
        }
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

    // Reconciles one scope-relative directory in one pass and one repack; false when its mount does not answer.
    pub(crate) fn patch_dir(&mut self, root: &Path, rel: &str, hidden: bool, body: &str) -> bool {
        let dir = if rel.is_empty() { root.to_path_buf() } else { root.join(rel) };
        let Ok(listing) = read_bounded(&dir, body) else { return false };
        let prefix = if rel.is_empty() { String::new() } else { format!("{}/", rel) };
        // A directory that is gone drops itself and its subtree; the scope itself drops every row.
        let Some(listing) = listing else {
            let kept: Vec<usize> = (0..self.rows.len())
                .filter(|&row| !rel.is_empty() && self.path(row) != rel && !self.path(row).starts_with(&prefix))
                .collect();
            self.compact(&kept);
            return true;
        };
        let seen: Vec<(String, bool)> = listing
            .into_iter()
            .filter(|(name, _)| hidden || !name.starts_with('.'))
            .map(|(name, is_dir)| (format!("{}{}", prefix, name), is_dir))
            .collect();
        let names: HashSet<&str> = seen.iter().map(|(child, _)| child.as_str()).collect();
        let mut kept = Vec::with_capacity(self.rows.len());
        let mut present: HashSet<String> = HashSet::new();
        for row in 0..self.rows.len() {
            #[cfg(test)]
            self.scanned.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let path = self.path(row);
            let Some(below) = path.strip_prefix(prefix.as_str()) else {
                kept.push(row);
                continue;
            };
            let child = &path[..prefix.len() + below.find('/').unwrap_or(below.len())];
            if names.contains(child) {
                kept.push(row);
                if child.len() == path.len() {
                    present.insert(path.to_string());
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
                self.push(child, is_dir);
            }
        }
        if !added_dirs.is_empty() {
            self.fill_subtrees(root, &added_dirs, hidden, body);
        }
        true
    }

    // Walks newly added directories in, so a moved tree lands whole; rows already under them are read once.
    fn fill_subtrees(&mut self, root: &Path, added: &[String], hidden: bool, body: &str) {
        let prefixes: Vec<String> = added.iter().map(|dir| format!("{}/", dir)).collect();
        let mut present: HashSet<String> = HashSet::new();
        for row in 0..self.rows.len() {
            #[cfg(test)]
            self.scanned.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let path = self.path(row);
            if prefixes.iter().any(|prefix| path.starts_with(prefix.as_str())) {
                present.insert(path.to_string());
            }
        }
        let mut pending = added.to_vec();
        while let Some(dir_rel) = pending.pop() {
            if self.capped {
                return;
            }
            let Ok(Some(entries)) = read_bounded(&root.join(&dir_rel), body) else { continue };
            for (name, is_dir) in entries {
                if !hidden && name.starts_with('.') {
                    continue;
                }
                let child = format!("{}/{}", dir_rel, name);
                if present.insert(child.clone()) {
                    self.push(child.clone(), is_dir);
                    if is_dir {
                        pending.push(child);
                    }
                }
            }
        }
    }
}

// One directory as (name, is_dir) pairs, or None when it cannot be read; d_type answers is_dir with no stat.
fn read_listing(dir: &Path) -> Option<Vec<(String, bool)>> {
    let rd = std::fs::read_dir(dir).ok()?;
    let mut out = Vec::new();
    for entry in rd.flatten() {
        let is_dir = entry.file_type().map(|kind| kind.is_dir()).unwrap_or(false);
        out.push((entry.file_name().to_string_lossy().into_owned(), is_dir));
    }
    Some(out)
}

// One directory read under the mount bound, so a patch on a dead server costs one deadline and changes nothing.
fn read_bounded(dir: &Path, body: &str) -> Result<Option<Vec<(String, bool)>>, crate::error::FleaError> {
    let owned = dir.to_path_buf();
    super::iomount::call(dir, body, "search", move || read_listing(&owned))
}

// One directory as (name, is_dir) pairs; an unreadable directory answers empty, as scan.rs's phase one skips it.
pub(crate) fn read_entries(dir: &Path) -> Vec<(String, bool)> {
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

// The one rank comparator for answers and rest chunks, so a scrolled window only extends the head's order.
pub(crate) fn rank_cmp(index: &Index, a: &(i32, usize), b: &(i32, usize)) -> CmpOrdering {
    rank_order(a.0, index.path(a.1), b.0, index.path(b.1))
}

// The best `window` hits in rank order, the rest unranked; the path comparator runs only on the window and its edge ties.
pub(crate) fn select_head<K, F, C>(hits: &mut Vec<(i32, usize)>, window: usize, key: F, cmp: C) -> Vec<(i32, usize)>
where
    K: Ord,
    F: Fn(&(i32, usize)) -> K,
    C: Fn(&(i32, usize), &(i32, usize)) -> CmpOrdering,
{
    if window > 0 && window < hits.len() {
        hits.select_nth_unstable_by_key(window - 1, &key);
        let edge = key(&hits[window - 1]);
        // Hits tied with the edge on the integer key can sit on either side of the cut, so the comparator picks among them.
        if hits[window..].iter().any(|hit| key(hit) == edge) {
            let (mut sure, mut tied, mut past) = (Vec::with_capacity(window), Vec::new(), Vec::new());
            for &hit in hits.iter() {
                match key(&hit).cmp(&edge) {
                    CmpOrdering::Less => sure.push(hit),
                    CmpOrdering::Equal => tied.push(hit),
                    CmpOrdering::Greater => past.push(hit),
                }
            }
            // The edge hit is tied and inside the window, so at least one tied hit joins the head.
            tied.select_nth_unstable_by(window - sure.len() - 1, &cmp);
            *hits = [sure, tied, past].concat();
        }
    }
    let rest = hits.split_off(window.min(hits.len()));
    hits.sort_by(&cmp);
    rest
}

#[cfg(test)]
#[path = "searchindex_tests.rs"]
mod tests;
