// One live search session: the scope's snapshot index plus the standing query and its generation.
use crate::backend::fuzzy::{rank_order, Fuzzy};
use crate::backend::searchindex::{self, Index};
use crate::backend::searchwalk::{fill as walk_fill, WalkProbes};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

// The first window when a query names none, the list's own first-window default.
pub(crate) const FIRST_WINDOW_DEFAULT: usize = 350;
// Update batches while the walk grows go out at most this often, so a fast walk cannot flood the client.
pub(crate) const BATCH_MS: u64 = 100;

// Test-only counters, so release pays nothing for the gate.
#[cfg(test)]
#[derive(Default)]
pub(crate) struct Counters {
    pub walks_started: usize,
    pub rows_scored: usize,
}

// One answered query: the ranked row indices, the window head first, plus its populations.
pub(crate) struct Answer {
    pub gen: usize,
    pub ranked: Vec<usize>,
    pub rows: Vec<(String, bool)>,
    pub total: usize,
    pub indexed: usize,
    pub walking: bool,
    pub ms: f64,
    pub count: usize,
    pub scope: PathBuf,
    pub dev: u64,
    pub writable: bool,
}

pub(crate) struct Session {
    pub scope: PathBuf,
    pub folder: PathBuf,
    pub hidden: bool,
    pub dev: u64,
    pub writable: bool,
    index: Arc<Mutex<Index>>,
    walk_done: Arc<AtomicBool>,
    opened_at: Instant,
    walk_dirs: usize,
    walk_ms: f64,
    probes: Arc<WalkProbes>,
    handle: Option<std::thread::JoinHandle<usize>>,
    last_query: String,
    last_matches: Vec<usize>,
    pub last_answered_gen: usize,
    standing: Option<(usize, String, usize)>,
    standing_while_walking: bool,
    announced: bool,
    last_batch: Instant,
    #[cfg(test)]
    pub counters: Counters,
}

impl Session {
    // The one constructor: reads one mountinfo body, then walks on a background thread.
    pub(crate) fn open_async(
        scope: &str,
        folder: &str,
        hidden: bool,
        walked: std::sync::mpsc::Sender<crate::backend::events::Event>,
    ) -> Session {
        let body = crate::backend::mountinfo::read_body();
        let scope_buf = PathBuf::from(scope);
        let remote = crate::backend::iomount::is_remote(&scope_buf, &body);
        let dev = crate::backend::fsinfo::dev_of(&scope_buf);
        let writable = crate::backend::ops::dir_writable(&scope_buf);
        let probes = Arc::new(WalkProbes::new());
        let index = Arc::new(Mutex::new(Index::new()));
        let walk_done = Arc::new(AtomicBool::new(false));
        let thread_index = Arc::clone(&index);
        let thread_probes = Arc::clone(&probes);
        let thread_done = Arc::clone(&walk_done);
        let thread_scope = scope_buf.clone();
        let thread_body = body;
        let opened_at = Instant::now();
        let handle = std::thread::spawn(move || {
            let dirs = walk_fill(&thread_index, &thread_scope, hidden, remote, &thread_body, &thread_probes);
            thread_done.store(true, Ordering::Relaxed);
            let _ = walked.send(crate::backend::events::Event::SearchWalked);
            dirs
        });
        #[cfg(test)]
        let counters = Counters { walks_started: 1, rows_scored: 0 };
        Session {
            scope: scope_buf,
            folder: PathBuf::from(folder),
            hidden,
            dev,
            writable,
            index,
            walk_done,
            opened_at,
            walk_dirs: 0,
            walk_ms: 0.0,
            probes,
            handle: Some(handle),
            last_query: String::new(),
            last_matches: Vec::new(),
            last_answered_gen: 0,
            standing: None,
            standing_while_walking: false,
            announced: false,
            last_batch: Instant::now(),
            #[cfg(test)]
            counters,
        }
    }

    // Tests open the one constructor and join its walk, so no second setup drifts.
    #[cfg(test)]
    pub(crate) fn open_sync(scope: &str, folder: &str, hidden: bool) -> Session {
        let (walked_tx, _walked_rx) = std::sync::mpsc::channel();
        let mut session = Session::open_async(scope, folder, hidden, walked_tx);
        session.join_walk();
        session
    }

    // Joins a finished walk and stamps it landed; tests use this, the loop polls.
    #[cfg(test)]
    fn join_walk(&mut self) {
        if let Some(handle) = self.handle.take() {
            self.walk_dirs = handle.join().unwrap_or(0);
        }
        self.walk_done.store(true, Ordering::Relaxed);
        self.announced = true;
        self.walk_ms = self.opened_at.elapsed().as_secs_f64() * 1000.0;
    }

    // True once after the walk lands, so the loop re-runs the standing query exactly once.
    pub(crate) fn poll_walked(&mut self) -> bool {
        if self.announced || !self.walk_done.load(Ordering::Relaxed) {
            return false;
        }
        self.announced = true;
        if let Some(handle) = self.handle.take() {
            // The event arrived, so the walker already sent and joining ends at once.
            self.walk_dirs = handle.join().unwrap_or(0);
        }
        self.walk_ms = self.opened_at.elapsed().as_secs_f64() * 1000.0;
        true
    }

    // True while the walk is still running.
    pub(crate) fn walking(&self) -> bool {
        !self.walk_done.load(Ordering::Relaxed)
    }

    // The standing query for the landing re-run; None unless it was answered while walking.
    #[cfg(test)]
    pub(crate) fn landing(&self) -> Option<(usize, String, usize)> {
        if self.standing_while_walking { self.standing.clone() } else { None }
    }

    #[cfg(test)]
    pub(crate) fn walk_dirs(&self) -> usize {
        self.walk_dirs
    }

    #[cfg(test)]
    pub(crate) fn indexed(&self) -> usize {
        self.index.lock().unwrap().len()
    }

    #[cfg(test)]
    pub(crate) fn capped(&self) -> bool {
        self.index.lock().unwrap().capped
    }

    // Bytes the arena holds now; zero once close frees it, counted not sampled.
    #[cfg(test)]
    pub(crate) fn index_bytes(&self) -> usize {
        searchindex::index_bytes(&self.index.lock().unwrap())
    }

    // Answers one query from the index with no walk; None means the generation is stale.
    pub(crate) fn query(&mut self, gen: usize, query: &str, count: usize) -> Option<Answer> {
        if gen <= self.last_answered_gen {
            return None;
        }
        let mut answer = self.answer(query, count);
        answer.gen = gen;
        self.last_query = query.to_string();
        self.last_matches = answer.ranked.clone();
        self.last_answered_gen = gen;
        self.standing = Some((gen, query.to_string(), count));
        self.standing_while_walking = answer.walking;
        self.last_batch = Instant::now();
        Some(answer)
    }

    // Re-runs the standing query once when the walk lands, with its own gen and the walk's ms.
    pub(crate) fn re_answer_standing(&mut self) -> Option<Answer> {
        let (gen, query, count) = self.standing.clone()?;
        if query.is_empty() || !self.standing_while_walking {
            return None;
        }
        self.standing_while_walking = false;
        // The index grew under the partial answer, so narrowing to its matches would keep the blind spot.
        self.last_query.clear();
        self.last_matches.clear();
        let mut answer = self.answer(&query, count);
        answer.gen = gen;
        answer.ms = self.walk_ms;
        self.last_query = query;
        self.last_matches = answer.ranked.clone();
        self.last_batch = Instant::now();
        Some(answer)
    }

    // Re-runs the standing query for an own-write push; None when no query stands.
    pub(crate) fn re_answer_now(&mut self) -> Option<Answer> {
        let (gen, query, count) = self.standing.clone()?;
        if query.is_empty() {
            return None;
        }
        let mut answer = self.answer(&query, count);
        answer.gen = gen;
        self.last_query = query;
        self.last_matches = answer.ranked.clone();
        self.last_batch = Instant::now();
        Some(answer)
    }

    // Claims a generation for the folder answer; false means the generation is stale.
    pub(crate) fn claim_gen(&mut self, gen: usize, query: &str, count: usize) -> bool {
        if gen <= self.last_answered_gen {
            return false;
        }
        self.last_answered_gen = gen;
        self.standing = Some((gen, query.to_string(), count));
        self.standing_while_walking = self.walking();
        self.last_batch = Instant::now();
        self.last_query.clear();
        true
    }

    // Scores the index with no generation bookkeeping; the callers above own that.
    fn answer(&mut self, query: &str, count: usize) -> Answer {
        let started = Instant::now();
        let fuzzy = Fuzzy::new(query);
        let index = self.index.lock().unwrap();
        // Incremental narrowing: an extension scores only the previous matches, any other change scores the index.
        let candidates: Vec<usize> = if !self.last_query.is_empty() && query.starts_with(&self.last_query) {
            self.last_matches.clone()
        } else {
            (0..index.len()).collect()
        };
        #[cfg(test)]
        let scored = candidates.len();
        let mut hits = searchindex::score_all(&fuzzy, &candidates, &index);
        #[cfg(test)]
        {
            self.counters.rows_scored = scored;
        }
        // Top-K first: the first window is selected without a full sort, then the rest is ordered.
        let window = count.min(hits.len());
        if !hits.is_empty() {
            let rank = |a: &(i32, usize), b: &(i32, usize)| {
                rank_order(a.0, index.path(a.1), b.0, index.path(b.1))
            };
            let nth = window.saturating_sub(1).min(hits.len() - 1);
            hits.select_nth_unstable_by(nth, rank);
            let (head, rest) = hits.split_at_mut(window);
            head.sort_by(rank);
            rest.sort_by(rank);
        }
        let ranked: Vec<usize> = hits.iter().map(|(_, row)| *row).collect();
        let rows: Vec<(String, bool)> =
            ranked.iter().map(|&row| (index.path(row).to_string(), index.is_dir(row))).collect();
        let total = ranked.len();
        let indexed = index.len();
        drop(index);
        Answer {
            gen: 0,
            ranked,
            rows,
            total,
            indexed,
            walking: self.walking(),
            ms: started.elapsed().as_secs_f64() * 1000.0,
            count,
            scope: self.scope.clone(),
            dev: self.dev,
            writable: self.writable,
        }
    }

    // Patches the index for a backend write under the scope; answers whether it was under the scope.
    pub(crate) fn patch_after_write(&mut self, path: &Path) -> bool {
        let Ok(rel) = path.strip_prefix(&self.scope) else { return false };
        // A file two levels down patches its own directory, so the next query sees it with no walk.
        let parent = rel.parent().map(|parent| parent.to_string_lossy().into_owned()).unwrap_or_default();
        self.index.lock().unwrap().patch_dir(&self.scope, &parent, self.hidden);
        self.last_query.clear();
        true
    }

    // Patches one directory's entries when the open folder's watch reports it.
    pub(crate) fn patch_open_dir(&mut self, path: &Path) -> bool {
        let Ok(rel) = path.strip_prefix(&self.scope) else { return false };
        // A reported file patches its own directory; a reported directory patches itself.
        let dir = if path.is_dir() {
            rel.to_string_lossy().into_owned()
        } else {
            rel.parent().map(|parent| parent.to_string_lossy().into_owned()).unwrap_or_default()
        };
        self.index.lock().unwrap().patch_dir(&self.scope, &dir, self.hidden);
        self.last_query.clear();
        true
    }

    // True when the last batch is old enough for an update push while the walk grows.
    pub(crate) fn batch_due(&self) -> bool {
        self.last_batch.elapsed().as_millis() >= u128::from(BATCH_MS)
    }

    // Close cancels a running walk at once and frees the arena, answering the bytes freed.
    pub(crate) fn close(mut self) -> usize {
        self.probes.cancel.store(true, Ordering::Relaxed);
        // A landed walk's thread is already gone, so joining ends at once; a running one detaches behind cancel.
        if self.walk_done.load(Ordering::Relaxed) {
            if let Some(handle) = self.handle.take() {
                let _ = handle.join();
            }
        }
        searchindex::index_bytes(&self.index.lock().unwrap())
    }

    #[cfg(test)]
    pub(crate) fn test_set_last_batch(&mut self, at: Instant) {
        self.last_batch = at;
    }
}

#[cfg(test)]
#[path = "searchsession_tests.rs"]
mod tests;
