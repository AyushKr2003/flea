// The progress cadence of one whole operation and the bytes its lines still owe the client, see docs/protocol.md "transferprogress".
use super::PROGRESS_EVERY;
use std::cell::Cell;
use std::time::Instant;

pub(super) struct Pace {
    last: Cell<Option<Instant>>,
    // The item in flight and the bytes the copy has reported for it, sent or not.
    live: Cell<(usize, u64)>,
    // What finished items copied, and what a client counts from the lines it saw.
    copied: Cell<u64>,
    counted: Cell<u64>,
    // The last line sent for the item in flight: its index, what a client counts from it, and the part of that which is the item's own.
    sent: Cell<Option<(usize, u64, u64)>>,
}

impl Pace {
    pub(super) fn new() -> Self {
        Pace { last: Cell::new(None), live: Cell::new((usize::MAX, 0)), copied: Cell::new(0), counted: Cell::new(0), sent: Cell::new(None) }
    }

    // One byte report of the item in flight: the (bytes, total) to put on the wire now, or None while the window is open.
    pub(super) fn sample(&self, now: Instant, index: usize, done: u64, total: u64) -> Option<(u64, u64)> {
        self.live.set((index, done));
        if self.last.get().is_some_and(|last| now.saturating_duration_since(last) < PROGRESS_EVERY) {
            return None;
        }
        self.last.set(Some(now));
        let owed = self.owed();
        let (bytes, total) = if owed > 0 { (owed + done, 0) } else { (done, total) };
        self.sent.set(Some((index, if total > 0 { total } else { bytes }, if total > 0 { total } else { done })));
        Some((bytes, total))
    }

    // The item is over, whatever it ended in: its bytes join the totals on both sides, and a short one counts whole where its line named a total.
    pub(super) fn ended(&self, index: usize) {
        let (live, done) = self.live.get();
        let done = if live == index { done } else { 0 };
        let (counted, own) = match self.sent.get() {
            Some((sent, counted, own)) if sent == index => (counted, own),
            _ => (0, 0),
        };
        self.copied.set(self.copied.get() + done.max(own));
        self.counted.set(self.counted.get() + counted);
        self.sent.set(None);
        self.live.set((usize::MAX, 0));
    }

    fn owed(&self) -> u64 {
        self.copied.get().saturating_sub(self.counted.get())
    }

    // The bytes still unreported after the last item.
    pub(super) fn closing(&self) -> Option<u64> {
        Some(self.owed()).filter(|owed| *owed > 0)
    }
}

// The clock Pace samples; test builds can freeze it, so a test decides which items share a window.
pub(super) fn now() -> Instant {
    #[cfg(test)]
    if let Some(frozen) = FROZEN.with(Cell::get) {
        return frozen;
    }
    Instant::now()
}

#[cfg(test)]
thread_local! {
    static FROZEN: Cell<Option<Instant>> = const { Cell::new(None) };
}
// Unfrozen on drop, so a failing test never freezes the next one on its thread.
#[cfg(test)]
pub(crate) struct FrozenClock;
#[cfg(test)]
impl FrozenClock {
    pub(crate) fn hold() -> Self {
        FROZEN.with(|v| v.set(Some(Instant::now())));
        FrozenClock
    }
}
#[cfg(test)]
impl Drop for FrozenClock {
    fn drop(&mut self) {
        FROZEN.with(|v| v.set(None));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    // ui/js/Transfer.js sampled and itemDone, which is how the card counts what the lines say.
    #[derive(Default)]
    struct Client {
        index: usize,
        bytes: u64,
        total: u64,
        moved: u64,
    }
    impl Client {
        fn sampled(&mut self, index: usize, bytes: u64, total: u64) {
            (self.index, self.bytes, self.total) = (index, bytes, total);
        }
        fn item_done(&mut self, index: usize) {
            let sampled = if self.index == index { if self.total > 0 { self.total } else { self.bytes } } else { 0 };
            (self.index, self.bytes, self.total, self.moved) = (index, 0, 0, self.moved + sampled);
        }
        fn shown(&self) -> u64 {
            self.moved + self.bytes
        }
    }

    #[test]
    fn a_thousand_items_inside_one_window_send_one_line_and_the_closing_one() {
        let pace = Pace::new();
        let base = Instant::now();
        let mut sent = Vec::new();
        for index in 0..1000usize {
            let now = base + Duration::from_micros(index as u64 * 100);
            if let Some(line) = pace.sample(now, index, 4096, 4096) {
                sent.push((index, line));
            }
            pace.ended(index);
        }
        assert_eq!(sent, vec![(0, (4096, 4096))]);
        assert_eq!(pace.closing(), Some(999 * 4096));
    }

    #[test]
    fn a_one_gib_item_sends_one_line_per_window() {
        let pace = Pace::new();
        let base = Instant::now();
        let mut sent = 0;
        for step in 1..=1024u64 {
            let now = base + Duration::from_millis(step - 1);
            if let Some((bytes, total)) = pace.sample(now, 0, step << 20, 1 << 30) {
                sent += 1;
                assert_eq!((bytes, total), (step << 20, 1 << 30), "a lone item reports its own bytes and total");
            }
        }
        assert_eq!(sent, 7, "samples at 0, 150, 300, 450, 600, 750 and 900 ms");
        pace.ended(0);
        assert_eq!(pace.closing(), None, "the item's total was named, so nothing is owed");
    }

    #[test]
    fn the_first_sample_of_a_later_item_waits_for_the_window_and_then_names_what_was_skipped() {
        let pace = Pace::new();
        let base = Instant::now();
        assert!(pace.sample(base, 0, 10, 10).is_some());
        pace.ended(0);
        assert!(pace.sample(base + Duration::from_millis(50), 1, 20, 20).is_none());
        pace.ended(1);
        assert_eq!(pace.sample(base + Duration::from_millis(150), 2, 5, 40), Some((20 + 5, 0)));
    }

    #[test]
    fn the_card_counts_every_byte_whatever_the_window_skipped() {
        let pace = Pace::new();
        let (mut client, mut copied) = (Client::default(), 0u64);
        let base = Instant::now();
        let mut clock = 0u64;
        // Mixed sizes, a few reports per item, and a clock that sometimes stands still for a run of items.
        for index in 0..400usize {
            let size = 1 + (index as u64 * 7919) % 5000;
            for part in 1..=3u64 {
                clock += if index % 40 < 30 { 1 } else { 90 };
                let done = size * part / 3;
                if let Some((bytes, total)) = pace.sample(base + Duration::from_millis(clock), index, done, size) {
                    client.sampled(index, bytes, total);
                    assert_eq!(client.shown(), copied + done, "item {index} part {part}");
                }
            }
            pace.ended(index);
            copied += size;
            client.item_done(index);
            assert!(client.shown() <= copied, "the card never counts more than was copied");
        }
        if let Some(owed) = pace.closing() {
            client.sampled(399, owed, 0);
        }
        assert_eq!(client.shown(), copied);
    }

    #[test]
    fn an_item_that_ends_short_counts_whole_on_both_sides_so_a_later_skipped_item_is_still_reported() {
        let pace = Pace::new();
        let (mut client, base) = (Client::default(), Instant::now());
        let (bytes, total) = pace.sample(base, 0, 10, 100).expect("the first sample goes out at once");
        client.sampled(0, bytes, total);
        assert!(pace.sample(base + Duration::from_millis(10), 0, 40, 100).is_none());
        pace.ended(0);
        client.item_done(0);
        assert!(pace.sample(base + Duration::from_millis(50), 1, 50, 50).is_none());
        pace.ended(1);
        client.item_done(1);
        let owed = pace.closing();
        assert_eq!(owed, Some(50), "the second item's bytes are still owed after the short one");
        client.sampled(1, owed.unwrap(), 0);
        assert_eq!(client.shown(), 100 + 50, "the card shows what an unthrottled one shows");
    }
}
