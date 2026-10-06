// The wire side of file tags: one write naming rows of the listing in force.
use crate::backend::opsdispatch::resolve_rows;
use crate::backend::proto::error_line;
use crate::backend::state::State;
use crate::backend::undo::{Entry, Step};
use crate::error::FleaError;
use std::io::Write;
use std::path::{Path, PathBuf};

// Sample output: {"t":"settagged","ok":2}
pub fn settagged_line(ok: usize) -> String {
    format!(r#"{{"t":"settagged","ok":{}}}"#, ok)
}

// Every file or none: support is checked first and a failed write puts every earlier file back, so nothing is half-applied.
pub fn apply_tags(
    out: &mut impl Write,
    ops: &mut crate::backend::opsdispatch::Ops,
    st: &State,
    rows: Vec<usize>,
    op: &str,
    tag: &str,
) {
    if ops.live.running().is_some() {
        let busy = FleaError { where_: "settags".into(), path: String::new(), msg: "an operation is already running".into() };
        writeln!(out, "{}", error_line(&busy)).ok();
        out.flush().ok();
        return;
    }
    let targets = resolve_rows(Vec::new(), &rows, &st.base, &st.listing);
    if targets.is_empty() {
        writeln!(out, "{}", settagged_line(0)).ok();
        out.flush().ok();
        return;
    }
    // Validated before the filesystem is touched, so a bad op refuses with nothing read.
    if let Err(e) = super::tags::apply(&[], op, tag) {
        writeln!(out, "{}", error_line(&e)).ok();
        out.flush().ok();
        return;
    }
    if let Some(refused) = super::tags::support_error(Path::new(&targets[0])) {
        writeln!(out, "{}", error_line(&refused)).ok();
        out.flush().ok();
        return;
    }
    // Every previous attribute is read before the first write, so a vanished file refuses all.
    let mut befores = Vec::with_capacity(targets.len());
    for target in &targets {
        match super::tags::read_raw(Path::new(target)) {
            Ok(before) => befores.push(before),
            Err(e) => {
                let missing = FleaError { where_: "settags".into(), path: target.clone(), msg: e.msg };
                writeln!(out, "{}", error_line(&missing)).ok();
                out.flush().ok();
                return;
            }
        }
    }
    let mut steps = Vec::new();
    let mut written = 0;
    for (target, before) in targets.iter().zip(&befores) {
        let names = before.as_ref().map(|raw| super::tags::parse(raw)).unwrap_or_default();
        let after = match super::tags::apply(&names, op, tag) {
            Ok(after) => after,
            // Unreachable after the validation above; rolls back rather than half-applying anyway.
            Err(e) => {
                rollback(&targets, &befores, written);
                writeln!(out, "{}", error_line(&e)).ok();
                out.flush().ok();
                return;
            }
        };
        if names == after {
            continue;
        }
        if let Err(e) = super::tags::write_names(Path::new(target), &after) {
            rollback(&targets, &befores, written);
            let failed = FleaError { where_: "settags".into(), path: target.clone(), msg: e.msg };
            writeln!(out, "{}", error_line(&failed)).ok();
            out.flush().ok();
            return;
        }
        let after_raw = if after.is_empty() { None } else { Some(super::tags::join(&after)) };
        steps.push(Step::Tags { path: PathBuf::from(target), before: before.clone(), after: after_raw });
        written += 1;
    }
    ops.journal.push(Entry { op: "settags".into(), steps });
    writeln!(out, "{}", settagged_line(written)).ok();
    out.flush().ok();
}

// Puts back the files written before the failure, best effort; the error names the failure, not this.
fn rollback(targets: &[String], befores: &[Option<Vec<u8>>], written: usize) {
    for (target, before) in targets.iter().zip(befores.iter()).take(written) {
        let _ = super::tags::restore(Path::new(target), before);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::dirsizeworker::Worker;
    use crate::backend::testdir::TestDir;
    use std::sync::mpsc::channel;

    fn state_for(base: &Path) -> State {
        let (tx, _rx) = channel();
        let mut st = State::new(Worker::new(tx));
        st.base = base.to_path_buf();
        st
    }

    fn ops() -> crate::backend::opsdispatch::Ops {
        let (tx, _rx) = channel();
        crate::backend::opsdispatch::Ops::new(tx)
    }

    #[test]
    fn a_write_changes_every_file_and_journals_each_previous_attribute() {
        let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let d = TestDir::new("tagsreqwrite");
        let _first = d.file("a.txt", "body");
        let _second = d.file("b.txt", "body");
        let mut st = state_for(d.path());
        st.listing.push("a.txt", false);
        st.listing.push("b.txt", false);
        let mut o = ops();
        let mut out = Vec::new();
        apply_tags(&mut out, &mut o, &st, vec![0, 1], "add", "Red");
        assert_eq!(String::from_utf8(out).unwrap(), settagged_line(2) + "\n");
        assert_eq!(crate::backend::tags::read(&d.join("a.txt")).unwrap(), vec!["Red"]);
        assert_eq!(o.journal.len(), 1);
        let mut out = Vec::new();
        crate::backend::opsdispatch::do_undo(&mut out, &mut o);
        assert_eq!(crate::backend::tags::read(&d.join("a.txt")).unwrap(), Vec::<String>::new());
        assert_eq!(crate::backend::tags::read(&d.join("b.txt")).unwrap(), Vec::<String>::new());
    }

    #[test]
    fn a_redo_reapplies_what_undo_took_back() {
        let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let d = TestDir::new("tagsreqredo");
        let _file = d.file("a.txt", "body");
        let mut st = state_for(d.path());
        st.listing.push("a.txt", false);
        let mut o = ops();
        let mut out = Vec::new();
        apply_tags(&mut out, &mut o, &st, vec![0], "add", "Green");
        crate::backend::opsdispatch::do_undo(&mut out, &mut o);
        assert_eq!(crate::backend::tags::read(&d.join("a.txt")).unwrap(), Vec::<String>::new());
        let (tx, _rx) = channel();
        o.journal.redo(1, &std::sync::atomic::AtomicBool::new(false), &tx).expect("redo reapplies");
        assert_eq!(crate::backend::tags::read(&d.join("a.txt")).unwrap(), vec!["Green"]);
    }

    #[test]
    fn a_file_that_vanished_refuses_all_and_writes_nothing() {
        let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let d = TestDir::new("tagsreqgone");
        let _first = d.file("a.txt", "body");
        let gone = d.file("gone.txt", "body");
        std::fs::remove_file(&gone).unwrap();
        let mut st = state_for(d.path());
        st.listing.push("a.txt", false);
        st.listing.push("gone.txt", false);
        let mut o = ops();
        let mut out = Vec::new();
        apply_tags(&mut out, &mut o, &st, vec![0, 1], "add", "Red");
        let line = String::from_utf8(out).unwrap();
        assert!(line.contains(r#""where":"settags""#), "{}", line);
        assert_eq!(crate::backend::tags::read(&d.join("a.txt")).unwrap(), Vec::<String>::new());
        assert_eq!(o.journal.len(), 0);
    }

    #[test]
    fn an_unsupported_filesystem_refuses_before_anything_is_written() {
        let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let d = TestDir::new("tagsreqrefuse");
        let _first = d.file("a.txt", "body");
        let mut st = state_for(d.path());
        st.listing.push("a.txt", false);
        crate::backend::tags::FORCE_UNSUPPORTED.with(|f| f.set(true));
        let mut o = ops();
        let mut out = Vec::new();
        apply_tags(&mut out, &mut o, &st, vec![0], "add", "Red");
        crate::backend::tags::FORCE_UNSUPPORTED.with(|f| f.set(false));
        let line = String::from_utf8(out).unwrap();
        assert!(line.contains(r#""where":"settags""#), "{}", line);
        assert!(line.contains("nothing was changed"), "{}", line);
        assert_eq!(crate::backend::tags::read(&d.join("a.txt")).unwrap(), Vec::<String>::new());
        assert_eq!(o.journal.len(), 0);
    }

    #[test]
    fn a_noop_change_answers_success_and_records_nothing() {
        let _guard = crate::backend::tags::SEAM.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let d = TestDir::new("tagsreqnoop");
        let _file = d.file("a.txt", "body");
        let mut st = state_for(d.path());
        st.listing.push("a.txt", false);
        let mut o = ops();
        let mut out = Vec::new();
        apply_tags(&mut out, &mut o, &st, vec![0], "remove", "Red");
        assert_eq!(String::from_utf8(out).unwrap(), settagged_line(0) + "\n");
        assert_eq!(o.journal.len(), 0, "an operation that changed nothing records nothing");
    }

    #[test]
    fn a_stale_numbering_is_refused_before_anything_resolves() {
        let line = r#"{"c":"settags","rows":[0],"op":"add","tag":"Red","listing":1}"#;
        let refused = crate::backend::rowguard::refusal(line, 2).expect("a stale settags is refused");
        assert!(refused.contains(r#""where":"stale""#), "{}", refused);
    }
}
