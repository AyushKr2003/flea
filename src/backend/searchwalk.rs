// The session walk: bounded parallel threads over a shared queue for a local scope,
// one bounded worker per directory for a remote one.
use super::searchindex::{read_entries, Index, WALK_THREADS};
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Mutex;

// How many directories the walk has opened; tests read it beside the cancel flag.
pub(crate) struct WalkProbes {
    pub opened: AtomicUsize,
    pub cancel: AtomicBool,
    // Test seam: holds the walk once it has opened `at` directories until released, so close
    // lands mid-walk. Per walk, so parallel tests never park each other's walks.
    #[cfg(test)]
    hold: Mutex<Option<WalkHold>>,
}

impl WalkProbes {
    pub(crate) fn new() -> WalkProbes {
        WalkProbes {
            opened: AtomicUsize::new(0),
            cancel: AtomicBool::new(false),
            #[cfg(test)]
            hold: Mutex::new(None),
        }
    }

    // Arms the hold on this walk's own probes; the walk sends `parked` once blocked.
    #[cfg(test)]
    pub(crate) fn test_hold_walk_at(
        &self,
        at: usize,
    ) -> (std::sync::mpsc::Receiver<()>, std::sync::mpsc::Sender<()>) {
        let (parked_tx, parked_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        *self.hold.lock().unwrap() = Some(WalkHold { at, parked: parked_tx, release: release_rx });
        (parked_rx, release_tx)
    }
}

#[cfg(test)]
impl WalkProbes {
    // Parks this walk once it has opened `at` directories; other walks never see the hold.
    fn hold_if_due(&self, opened: usize) {
        let due = self.hold.lock().unwrap().as_ref().is_some_and(|hold| opened >= hold.at);
        if due {
            let hold = self.hold.lock().unwrap().take();
            if let Some(hold) = hold {
                let _ = hold.parked.send(());
                let _ = hold.release.recv();
            }
        }
    }
}

// Test seam: holds the walk once it has opened `at` directories until released, so close lands mid-walk.
#[cfg(test)]
struct WalkHold {
    at: usize,
    parked: std::sync::mpsc::Sender<()>,
    release: std::sync::mpsc::Receiver<()>,
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
                    probes.hold_if_due(probes.opened.load(Ordering::Relaxed));
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
    let mut order: Vec<usize> = (0..index.len()).collect();
    order.sort_by(|&a, &b| index.path(a).cmp(index.path(b)));
    let mut sorted = Index::new();
    sorted.capped = index.capped;
    for i in order {
        sorted.push(index.path(i).to_string(), index.is_dir(i));
    }
    *index = sorted;
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
        probes.hold_if_due(probes.opened.load(Ordering::Relaxed));
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
