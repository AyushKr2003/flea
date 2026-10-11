// The closing progress line names the transfer's last item, driven against real files in a sandbox.
use crate::backend::collide::tests::owned;
use crate::backend::collide::Policy;
use crate::backend::opsreq::{run_transfer_checked, OpMsg};
use crate::backend::testdir::TestDir;
use std::sync::atomic::AtomicBool;
use std::sync::mpsc::channel;
use std::sync::Arc;

#[test]
fn the_closing_progress_line_names_the_last_item_not_the_last_one_that_paced_bytes() {
    // A frozen clock keeps b.txt inside a.txt's window whatever the host's speed.
    let _clock = crate::backend::opsreq::opspace::FrozenClock::hold();
    let d = TestDir::new("closing-names-last");
    let to = d.dir("to");
    let (a, b) = (d.file("a.txt", "first"), d.file("b.txt", "second one"));
    let gone = d.join("gone.txt");
    let (tx, rx) = channel();
    run_transfer_checked(1, false, owned(&[&a, &b, &gone]), to.clone(), Arc::new(AtomicBool::new(false)), tx, None, None, Policy::default());
    let lines: Vec<(usize, String, u64, u64)> = rx.iter().filter_map(|msg| match msg {
        OpMsg::Progress { index, name, bytes, total, .. } => Some((index, name, bytes, total)),
        _ => None,
    }).collect();
    assert_eq!(lines.last(), Some(&(2, "gone.txt".to_string(), 10, 0)), "the second item rode inside the first window, so its bytes close the run under the last name: {:?}", lines);
}
