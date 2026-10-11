// merge_folder's tests, beside it so mergeapply.rs keeps under the file budget.
use super::*;
use crate::backend::collide::{Ask, Question};
use crate::backend::testdir::TestDir;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};

#[test]
fn a_cancel_inside_the_last_nested_folder_reports_cancelled() {
    let d = TestDir::new("merge-cancel-nested");
    let src_trip = d.dir("from/trip");
    d.dir("from/trip/sub");
    d.file("from/trip/sub/a.txt", "a-body-with-bytes-to-report");
    d.file("from/trip/sub/b.txt", "b-body-with-bytes-to-report");
    let dest = d.dir("to");
    d.dir("to/trip/sub");
    // A forced-durable destination confirms each copy after its report, so the trip lands before the cancel stops the fold.
    crate::backend::durable::test_mark_durable(&dest);
    let question = Question { id: 7, dest: dest.clone(), seen: HashMap::new(), menu: None, fat: None };
    let inner = Ask { word: Some("merge".to_string()), id: 7, inner: Some("keep".to_string()), fat: None }
        .policy(Some(question), &dest).inner();
    let cancel = AtomicBool::new(false);
    let mut carried = 0u64;
    let mut sink = |_done: u64, _total: u64| {
        cancel.store(true, Ordering::Relaxed);
    };
    let mut manifest = None;
    let mut ctx = crate::backend::durable::Durability::begin(&dest);
    let mut counts = Counts::default();
    let mut deferred = Deferred::begin();
    let mut steps = Vec::new();
    let r = merge_into(&src_trip, &dest.join("trip"), &dest, false, &inner, &mut steps, &cancel,
        &mut sink, &mut carried, &mut manifest, &mut ctx, &mut counts, &mut deferred);
    let err = r.expect_err("a cancel inside the last nested folder reports cancelled, not done");
    assert!(err.msg.contains("cancelled"), "the error names the cancel: {}", err.msg);
}
