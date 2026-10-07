use super::*;
use crate::backend::searchwalk::{walk, WalkProbes};
use crate::backend::testdir::TestDir;

// Hard rule 9: every path below is inside a sandbox TestDir made and removes itself.
fn root(d: &TestDir) -> &std::path::Path {
    d.path()
}

#[test]
fn a_local_walk_indexes_every_row_with_one_mountinfo_read() {
    crate::backend::mountinfo::test_reset();
    let d = TestDir::new("sessionwalk");
    d.dir("tools/benches");
    d.file("tools/benches/bench-run.sh", "");
    d.file("unrelated.txt", "");
    let body = crate::backend::mountinfo::read_body();
    let probes = WalkProbes::new();
    let (index, dirs) = walk(root(&d), false, false, &body, &probes);
    assert_eq!(dirs, 3, "the scope, tools and tools/benches over 3 directories walked");
    assert_eq!(index.len(), 4, "4 rows indexed over 3 directories walked");
    assert_eq!(crate::backend::mountinfo::test_reads(), 1, "1 mountinfo read over 3 directories walked");
}

#[test]
fn a_local_walk_takes_no_bound_call() {
    crate::backend::iomount::test_reset();
    let d = TestDir::new("sessionbound");
    d.dir("sub");
    d.file("sub/bench.txt", "");
    let body = crate::backend::mountinfo::read_body();
    let probes = WalkProbes::new();
    let (index, _) = walk(root(&d), false, false, &body, &probes);
    assert_eq!(index.len(), 2, "2 rows indexed over 1 directory walked");
    assert_eq!(crate::backend::iomount::test_calls(), 0, "0 bound calls over 1 directory walked");
}

// A patch that drops two children ahead of a deeper row keeps every surviving row and drops only the gone ones.
#[test]
fn a_patch_dropping_two_children_keeps_the_rows_after_them() {
    let d = TestDir::new("sessionpatch");
    d.file("c.txt", "");
    d.dir("sub");
    d.file("sub/x.txt", "");
    let mut index = Index::new();
    for (path, is_dir) in [("a.txt", false), ("b.txt", false), ("c.txt", false), ("sub", true), ("sub/x.txt", false)] {
        index.push(path.to_string(), is_dir);
    }
    index.patch_dir(root(&d), "", false);
    let mut paths: Vec<&str> = (0..index.len()).map(|row| index.path(row)).collect();
    paths.sort();
    assert_eq!(paths, ["c.txt", "sub", "sub/x.txt"], "a.txt and b.txt gone, sub/x.txt kept");
}

#[cfg(test)]
mod cap_tests {
use super::*;

// Past the cap the walk stops adding and the count stands.
#[test]
fn an_index_past_the_cap_stops_adding() {
    let mut index = Index::new();
    for i in 0..SESSION_MAX_ENTRIES + 1 {
        index.push(format!("f{}", i), false);
    }
    assert_eq!(index.len(), SESSION_MAX_ENTRIES, "the index holds {} rows", index.len());
    assert!(index.capped, "the cap marks the index it stopped");
}
}

// Diagnostic only, never a gate: one full-index score over 100k synthetic realistic paths prints its ms.
#[test]
fn full_index_score_prints_its_ms() {
    let mut index = Index::new();
    for i in 0..100_000 {
        index.push(
            format!("some_directory_name_{:03}/nested_subdir/report_final_draft_v{:05}_reviewed.txt", i % 200, i),
            false,
        );
    }
    assert_eq!(index.len(), 100_000, "100000 synthetic rows indexed");
    let fuzzy = crate::backend::fuzzy::Fuzzy::new("report");
    let rows: Vec<usize> = (0..index.len()).collect();
    let started = std::time::Instant::now();
    let hits = super::score_all(&fuzzy, &rows, &index);
    let ms = started.elapsed().as_secs_f64() * 1000.0;
    let bytes = super::index_bytes(&index);
    eprintln!("TIMING full-index score: {} rows scored, {} hits, {:.1} ms", rows.len(), hits.len(), ms);
    eprintln!("TIMING index: {} bytes over {} rows, {} bytes per entry", bytes, index.len(), bytes / index.len());
}
