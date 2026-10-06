// One live search session: the scope's snapshot index plus the standing query and its generation.
use crate::backend::fuzzy::{rank_order, Fuzzy};
use crate::backend::searchindex::{self, Index};
use crate::backend::searchreq::Answer;
use crate::backend::searchwalk::WalkProbes;
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

// The wire lines an answer travels on live beside it in searchreq.rs; the walk thread that
// fills the index lives beside it in searchwalk.rs.

pub(crate) struct Session {
    pub scope: PathBuf,
    pub folder: PathBuf,
    pub hidden: bool,
    pub dev: u64,
    pub writable: bool,
    pub(crate) index: Arc<Mutex<Index>>,
    pub(crate) walk_done: Arc<AtomicBool>,
    pub(crate) opened_at: Instant,
    pub(crate) walk_dirs: usize,
    pub(crate) walk_ms: f64,
    pub(crate) probes: Arc<WalkProbes>,
    pub(crate) handle: Option<std::thread::JoinHandle<usize>>,
    pub(crate) last_query: String,
    pub(crate) last_matches: Vec<usize>,
    pub(crate) folder_n: usize,
    pub last_answered_gen: usize,
    pub(crate) standing: Option<(usize, String, usize)>,
    pub(crate) standing_while_walking: bool,
    pub(crate) announced: bool,
    pub(crate) last_batch: Instant,
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
        Self::open_async_inner(scope, folder, hidden, walked, Arc::new(WalkProbes::new()))
    }

    // Tests arm the walk hold on these probes before opening, so the park never races the walk.
    #[cfg(test)]
    pub(crate) fn open_async_with_probes(
        scope: &str,
        folder: &str,
        hidden: bool,
        walked: std::sync::mpsc::Sender<crate::backend::events::Event>,
        probes: Arc<WalkProbes>,
    ) -> Session {
        Self::open_async_inner(scope, folder, hidden, walked, probes)
    }

    // Tests open the one constructor and join its walk, so no second setup drifts.
    #[cfg(test)]
    pub(crate) fn open_sync(scope: &str, folder: &str, hidden: bool) -> Session {
        let (walked_tx, _walked_rx) = std::sync::mpsc::channel();
        let mut session = Session::open_async(scope, folder, hidden, walked_tx);
        session.join_walk();
        session
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

    // How many directories the walk has opened; the cancel and close tests read it frozen.
    #[cfg(test)]
    pub(crate) fn probes_opened(&self) -> usize {
        self.probes.opened.load(Ordering::Relaxed)
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

    // Remembers the folder count an empty query answered, so the landing line repeats it.
    pub(crate) fn note_folder_count(&mut self, n: usize) {
        self.folder_n = n;
    }

    // The landing line for an empty standing query: one searched line with the standing gen and
    // walking false, no rows to re-run because the folder rows already stand.
    pub(crate) fn landing_empty(&mut self) -> Option<(usize, usize, usize, f64)> {
        let (gen, query, _) = self.standing.clone()?;
        if !query.is_empty() || !self.standing_while_walking || self.walking() {
            return None;
        }
        self.standing_while_walking = false;
        Some((gen, self.folder_n, self.folder_n, self.walk_ms))
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
    pub(crate) fn answer(&mut self, query: &str, count: usize) -> Answer {
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

    #[cfg(test)]
    pub(crate) fn test_set_last_batch(&mut self, at: Instant) {
        self.last_batch = at;
    }
}

#[cfg(test)]
#[path = "searchsession_tests.rs"]
mod tests;
