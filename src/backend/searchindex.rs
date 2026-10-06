// The session's snapshot: every relative path walked once, folded once, scored per query.
use crate::backend::fuzzy::{fold_candidate, Folded};
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Mutex;

// Past this many rows the walk stops adding; 200k at the measured 705 bytes each is ~140 MiB worst case, handed back on close.
pub(crate) const SESSION_MAX_ENTRIES: usize = 200_000;
// One worker per core up to four; a cold 100k tree is seeker-hostile past that on spinning disks.
pub(crate) const WALK_THREADS: usize = 4;
// Below this many candidates scoring stays serial; a thread per keystroke costs more than it saves.
pub(crate) const PARALLEL_SCORE_AT: usize = 2048;

// One indexed row: the path relative to the scope, its once-folded haystack and its own type.
pub(crate) struct Row {
    pub path: String,
    pub folded: Vec<Folded>,
    pub is_dir: bool,
}

// The arena: one row per entry plus a path-to-row map, so a patch finds its rows without a scan.
pub(crate) struct Index {
    pub rows: Vec<Row>,
    by_path: HashMap<String, usize>,
    pub capped: bool,
}

// Bytes the arena holds: path bytes plus 8 per folded char plus one map entry each, counted not sampled.
pub(crate) fn index_bytes(index: &Index) -> usize {
    let mut bytes = 0;
    for row in &index.rows {
        bytes += row.path.len() + row.folded.len() * size_of::<Folded>() + 64;
    }
    bytes
}

impl Index {
    pub(crate) fn new() -> Index {
        Index { rows: Vec::new(), by_path: HashMap::new(), capped: false }
    }

    pub(crate) fn len(&self) -> usize {
        self.rows.len()
    }

    // Adds one row unless the cap is reached; past it the walk stops adding and the count stands.
    fn push(&mut self, path: String, is_dir: bool) {
        if self.rows.len() >= SESSION_MAX_ENTRIES {
            self.capped = true;
            return;
        }
        let folded = fold_candidate(&path);
        self.by_path.insert(path.clone(), self.rows.len());
        self.rows.push(Row { path, folded, is_dir });
    }

    // Removes every row at or under the relative path, answering how many went.
    fn remove_under(&mut self, rel: &str) -> usize {
        if rel.is_empty() {
            return 0;
        }
        let prefix = format!("{}/", rel);
        let before = self.rows.len();
        let mut kept = Vec::with_capacity(before);
        for row in self.rows.drain(..) {
            if row.path != rel && !row.path.starts_with(&prefix) {
                kept.push(row);
            }
        }
        self.rows = kept;
        self.by_path.clear();
        for i in 0..self.rows.len() {
            let path = self.rows[i].path.clone();
            self.by_path.insert(path, i);
        }
        before - self.rows.len()
    }

    // Re-reads one scope-relative directory and reconciles its rows, so a patch costs one readdir.
    // A newly added directory's subtree is walked in, so a moved tree lands whole, not just its top.
    pub(crate) fn patch_dir(&mut self, root: &Path, rel: &str, hidden: bool) {
        let dir = if rel.is_empty() { root.to_path_buf() } else { root.join(rel) };
        let Ok(rd) = std::fs::read_dir(&dir) else {
            self.remove_under(rel);
            return;
        };
        let mut seen: HashMap<String, bool> = HashMap::new();
        for entry in rd.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !hidden && name.starts_with('.') {
                continue;
            }
            let is_dir = entry.file_type().map(|kind| kind.is_dir()).unwrap_or(false);
            let child = if rel.is_empty() { name.clone() } else { format!("{}/{}", rel, name) };
            seen.insert(child.clone(), is_dir);
        }
        let prefix = if rel.is_empty() { String::new() } else { format!("{}/", rel) };
        let stale: Vec<String> = self
            .rows
            .iter()
            .filter(|row| {
                if rel.is_empty() {
                    !row.path.contains('/')
                } else {
                    row.path.starts_with(&prefix) && !row.path[prefix.len()..].contains('/')
                }
            })
            .map(|row| row.path.clone())
            .collect();
        for path in stale {
            if !seen.contains_key(&path) {
                self.remove_under(&path);
            }
        }
        let mut added_dirs = Vec::new();
        for (child, is_dir) in seen {
            if !self.by_path.contains_key(&child) {
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
                if !self.by_path.contains_key(&child) {
                    self.push(child.clone(), is_dir);
                    if is_dir {
                        pending.push(child);
                    }
                }
            }
        }
    }
}

// How many directories the walk has opened; tests read it beside the cancel flag.
pub(crate) struct WalkProbes {
    pub opened: AtomicUsize,
    pub cancel: AtomicBool,
}

impl WalkProbes {
    pub(crate) fn new() -> WalkProbes {
        WalkProbes { opened: AtomicUsize::new(0), cancel: AtomicBool::new(false) }
    }
}

// Test seam: holds the walk once it has opened `at` directories until released, so close lands mid-walk.
#[cfg(test)]
struct WalkHold {
    at: usize,
    parked: std::sync::mpsc::Sender<()>,
    release: std::sync::mpsc::Receiver<()>,
}

#[cfg(test)]
static WALK_HOLD: Mutex<Option<WalkHold>> = Mutex::new(None);

// Holds the next walk after `at` opens; the guard clears the hold on drop.
#[cfg(test)]
pub(crate) struct WalkHoldGuard;

#[cfg(test)]
impl Drop for WalkHoldGuard {
    fn drop(&mut self) {
        *WALK_HOLD.lock().unwrap() = None;
    }
}

// Arms the hold; the walk sends `parked` once blocked and waits for `release`.
#[cfg(test)]
pub(crate) fn test_hold_walk_at(at: usize) -> (WalkHoldGuard, std::sync::mpsc::Receiver<()>, std::sync::mpsc::Sender<()>) {
    let (parked_tx, parked_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    *WALK_HOLD.lock().unwrap() = Some(WalkHold { at, parked: parked_tx, release: release_rx });
    (WalkHoldGuard, parked_rx, release_tx)
}

#[cfg(test)]
fn walk_hold_if_due(opened: usize) {
    let due = WALK_HOLD.lock().unwrap().as_ref().is_some_and(|hold| opened >= hold.at);
    if due {
        let hold = WALK_HOLD.lock().unwrap().take();
        if let Some(hold) = hold {
            let _ = hold.parked.send(());
            let _ = hold.release.recv();
        }
    }
}

// One directory as (name, is_dir) pairs; d_type is free and answers is_dir with no stat.
fn read_entries(dir: &Path) -> Vec<(String, bool)> {
    // An unreadable directory answers empty in silence, as scan.rs's phase one skips an unreadable entry.
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(dir) else { return out };
    for entry in rd.flatten() {
        let is_dir = entry.file_type().map(|kind| kind.is_dir()).unwrap_or(false);
        out.push((entry.file_name().to_string_lossy().into_owned(), is_dir));
    }
    out
}

// The whole walk: one mountinfo read at open, a parallel walk for a local scope,
// today's single bounded worker per directory for a remote one.
#[cfg(test)]
pub(crate) fn walk(
    root: &Path,
    hidden: bool,
    remote: bool,
    body: &str,
    probes: &WalkProbes,
) -> (Index, usize) {
    let out = Mutex::new(Index::new());
    let dirs = fill(&out, root, hidden, remote, body, probes);
    (out.into_inner().unwrap_or_else(|poisoned| poisoned.into_inner()), dirs)
}

// Fills a shared index, so a background walk publishes while queries score the partial one.
pub(crate) fn fill(
    out: &Mutex<Index>,
    root: &Path,
    hidden: bool,
    remote: bool,
    body: &str,
    probes: &WalkProbes,
) -> usize {
    if remote {
        walk_remote(out, root, hidden, body, probes)
    } else {
        walk_local(out, root, hidden, probes)
    }
}

// Local scopes walk with bounded worker threads over a shared directory queue.
fn walk_local(out: &Mutex<Index>, root: &Path, hidden: bool, probes: &WalkProbes) -> usize {
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1).clamp(1, WALK_THREADS);
    let queue: Mutex<VecDeque<PathBuf>> = Mutex::new(VecDeque::from([root.to_path_buf()]));
    let root_buf = root.to_path_buf();
    let dirs = AtomicUsize::new(0);
    std::thread::scope(|scope| {
        for _ in 0..threads {
            scope.spawn(|| {
                loop {
                    if probes.cancel.load(Ordering::Relaxed) {
                        break;
                    }
                    let dir = queue.lock().unwrap().pop_front();
                    let Some(dir) = dir else { break };
                    let rel = rel_of(&root_buf, &dir);
                    // A close cancels the walk at once: no directory opens after close.
                    if probes.cancel.load(Ordering::Relaxed) {
                        break;
                    }
                    probes.opened.fetch_add(1, Ordering::Relaxed);
                    #[cfg(test)]
                    walk_hold_if_due(probes.opened.load(Ordering::Relaxed));
                    if probes.cancel.load(Ordering::Relaxed) {
                        break;
                    }
                    let mut local: Vec<(String, bool)> = Vec::new();
                    for (name, is_dir) in read_entries(&dir) {
                        // A dot-prefixed name is dropped before it is counted, matching scan.rs's own hidden rule.
                        if !hidden && name.starts_with('.') {
                            continue;
                        }
                        let child = if rel.is_empty() { name.clone() } else { format!("{}/{}", rel, name) };
                        local.push((child.clone(), is_dir));
                        // A symlink reports its own type, so a link to a directory is never descended.
                        if is_dir {
                            queue.lock().unwrap().push_back(dir.join(&name));
                        }
                    }
                    {
                        let mut index = out.lock().unwrap();
                        for (path, is_dir) in local {
                            index.push(path, is_dir);
                        }
                    }
                    dirs.fetch_add(1, Ordering::Relaxed);
                }
            });
        }
    });
    let dirs = dirs.load(Ordering::Relaxed);
    // One deterministic order whatever the thread interleaving was; ranking is total anyway.
    let mut index = out.lock().unwrap();
    index.rows.sort_by(|a, b| a.path.cmp(&b.path));
    index.by_path.clear();
    for i in 0..index.rows.len() {
        let path = index.rows[i].path.clone();
        index.by_path.insert(path, i);
    }
    dirs
}

// A remote scope keeps today's single bounded worker, so one dead server costs one deadline, never the walk.
fn walk_remote(out: &Mutex<Index>, root: &Path, hidden: bool, body: &str, probes: &WalkProbes) -> usize {
    let mut pending: Vec<PathBuf> = vec![root.to_path_buf()];
    let mut dirs = 0;
    while let Some(dir) = pending.pop() {
        // A close cancels the walk at once: no directory opens after close.
        if probes.cancel.load(Ordering::Relaxed) {
            break;
        }
        probes.opened.fetch_add(1, Ordering::Relaxed);
        #[cfg(test)]
        walk_hold_if_due(probes.opened.load(Ordering::Relaxed));
        if probes.cancel.load(Ordering::Relaxed) {
            break;
        }
        // One bound for opendir, getdents and d_type together, so a dead server costs one deadline.
        let owned = dir.clone();
        let entries = match super::iomount::call(&dir, body, "search", move || read_entries(&owned)) {
            Ok(entries) => entries,
            _ => continue,
        };
        let rel = rel_of(root, &dir);
        {
            let mut index = out.lock().unwrap();
            for (name, is_dir) in entries {
                if !hidden && name.starts_with('.') {
                    continue;
                }
                let child = if rel.is_empty() { name.clone() } else { format!("{}/{}", rel, name) };
                index.push(child.clone(), is_dir);
                if is_dir {
                    pending.push(dir.join(&name));
                }
            }
        }
        dirs += 1;
    }
    dirs
}

// The path relative to the scope; the empty string is the scope itself.
fn rel_of(root: &Path, dir: &Path) -> String {
    if dir == root {
        return String::new();
    }
    dir.strip_prefix(root).map(|rel| rel.to_string_lossy().into_owned()).unwrap_or_default()
}

// Scores candidates with the session's scorer; wide indexes split over the same walker bound.
pub(crate) fn score_all(fuzzy: &crate::backend::fuzzy::Fuzzy, rows: &[usize], index: &Index) -> Vec<(i32, usize)> {
    if rows.len() < PARALLEL_SCORE_AT {
        return rows
            .iter()
            .filter_map(|&row| fuzzy.score_pre_folded(&index.rows[row].folded).map(|score| (score, row)))
            .collect();
    }
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1).clamp(1, WALK_THREADS);
    let chunk = rows.len().div_ceil(threads);
    std::thread::scope(|scope| {
        let mut handles = Vec::with_capacity(threads);
        for part in rows.chunks(chunk) {
            handles.push(scope.spawn(move || {
                part.iter()
                    .filter_map(|&row| fuzzy.score_pre_folded(&index.rows[row].folded).map(|score| (score, row)))
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
