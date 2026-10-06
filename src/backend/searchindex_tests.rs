use super::*;
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
