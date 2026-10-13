// The thumbnail jobs the pool has no room for yet, held in request order, so a row the client still wants waits instead of being evicted.
use crate::backend::thumbs::{Job, Pool, MAX_QUEUE};
use std::collections::VecDeque;
use std::path::Path;

// Far above any viewport, so it bounds a request that names nonsense rather than a real screen; past it a row is answered empty.
pub(crate) const MAX_DEFERRED: usize = 4096;

#[derive(Default)]
pub struct Deferred {
    jobs: VecDeque<Job>,
}

impl Deferred {
    pub fn full(&self) -> bool {
        self.jobs.len() >= MAX_DEFERRED
    }

    // Queues behind the jobs already waiting, then hands the pool whatever it has room for.
    pub fn enqueue(&mut self, pool: &Pool, job: Job) {
        self.jobs.push_back(job);
        self.pump(pool);
    }

    // Only a worker ever takes a job off the pool, so the room counted here still holds at each submit and nothing is dropped.
    pub fn pump(&mut self, pool: &Pool) {
        let mut room = MAX_QUEUE.saturating_sub(pool.pending());
        while room > 0 {
            let Some(job) = self.jobs.pop_front() else { break };
            let dropped = pool.submit(job);
            debug_assert!(dropped.is_empty(), "a pump submits only into room the pool has");
            room -= 1;
        }
    }

    // A waiting job for this path, taken back by a cancel the way the pool gives up a queued one.
    pub fn take(&mut self, path: &Path) -> Vec<Job> {
        let at = self.jobs.iter().position(|j| j.path == path);
        at.and_then(|i| self.jobs.remove(i)).into_iter().collect()
    }

    // Every waiting job, for a cancel-all or a listing change.
    pub fn take_all(&mut self) -> Vec<Job> {
        self.jobs.drain(..).collect()
    }
}
