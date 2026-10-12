// Test-only work counters for a transfer, per thread so parallel tests never see each other's.
use std::cell::Cell;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub(crate) struct Counts {
    // Reads and parses of the mount table: one per ItemIdentity::inspect and one per Table::read.
    pub table_reads: u64,
    // Path resolutions: one per folder or source canonicalized, a readlink per component.
    pub resolves: u64,
}

thread_local! {
    static COUNTS: Cell<Counts> = const { Cell::new(Counts { table_reads: 0, resolves: 0 }) };
}

fn bump(change: impl FnOnce(&mut Counts)) {
    COUNTS.with(|cell| {
        let mut counts = cell.get();
        change(&mut counts);
        cell.set(counts);
    });
}

pub(crate) fn reset() {
    COUNTS.with(|cell| cell.set(Counts::default()));
}

pub(crate) fn snapshot() -> Counts {
    COUNTS.with(|cell| cell.get())
}

pub(crate) fn table_read() {
    bump(|c| c.table_reads += 1);
}

pub(crate) fn resolve() {
    bump(|c| c.resolves += 1);
}
