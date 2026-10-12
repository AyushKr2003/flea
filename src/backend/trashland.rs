// A trash batch's worker and its landing: the line and the slot go at the announce, the journal entry after the settle list.
use crate::backend::opsdispatch::Ops;
use crate::backend::opsreq::{op_err, trashed_line, OpMsg};
use crate::backend::trash;
use crate::backend::undo::{Entry, Step};
use std::io::Write;
use std::path::PathBuf;
use std::sync::mpsc::Sender;

pub(crate) fn run_trash(id: usize, paths: Vec<String>, tx: Sender<OpMsg>, selection: Option<Vec<super::menu_actions::Selected>>) {
    let owned: Vec<PathBuf> = paths.iter().map(PathBuf::from).collect();
    // Undo and redo name this path while the batch's entry is pending; a leading empty path is a drag marker, not an item.
    let first = paths.iter().find(|p| !p.is_empty()).cloned().unwrap_or_default();
    let mut announced = false;
    let early = tx.clone();
    let mut announce = |ok: usize, failed: usize, reason: &str| {
        announced = early.send(OpMsg::TrashAnnounced { id, path: first.clone(), ok, failed, reason: reason.to_string() }).is_ok();
    };
    let (entries, failed, reason) = match trash::trash_announcing(&owned, selection.as_deref(), &mut announce) {
        Ok(result) => result,
        Err(error) => {
            let line = super::proto::error_line(&op_err("trash", "", &error));
            let _ = tx.send(OpMsg::Meta { line });
            (Vec::new(), owned.len(), error)
        }
    };
    let ok = entries.len();
    let steps = entries.into_iter().map(Step::Trashed).collect();
    let entry = Entry { op: "trash".to_string(), steps };
    let _ = tx.send(OpMsg::Trashed { id, ok, failed, entry, reason, announced });
}

// The first batch whose entry is still pending, which is the path undo and redo answer busy with.
pub(crate) fn settling_path(ops: &Ops) -> Option<String> {
    ops.settling.first().map(|(_, path)| path.clone())
}

// The announce writes the line and frees the slot, so any write runs and only undo and redo wait; the journal message pushes the entry and ends that wait.
pub(crate) fn land(out: &mut impl Write, ops: &mut Ops, msg: OpMsg) {
    match msg {
        OpMsg::TrashAnnounced { id, path, ok, failed, reason } => {
            ops.settling.push((id, path));
            ops.live.finished_if(id);
            writeln!(out, "{}", trashed_line(ok, failed, &reason)).ok();
        }
        OpMsg::Trashed { id, ok, failed, entry, reason, announced } => {
            ops.journal.push(entry);
            ops.settling.retain(|(held, _)| *held != id);
            ops.live.finished_if(id);
            if !announced { writeln!(out, "{}", trashed_line(ok, failed, &reason)).ok(); }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::opsdispatch::{do_undo, start_trash};
    use crate::backend::testdir::TestDir;

    fn created(path: &std::path::Path) -> Entry {
        Entry { op: "trash".to_string(), steps: vec![Step::Created { path: path.to_path_buf() }] }
    }

    fn announced(id: usize, path: &std::path::Path) -> OpMsg {
        OpMsg::TrashAnnounced { id, path: path.to_string_lossy().into(), ok: 1, failed: 0, reason: String::new() }
    }

    fn journaled(id: usize, path: &std::path::Path) -> OpMsg {
        OpMsg::Trashed { id, ok: 1, failed: 0, entry: created(path), reason: String::new(), announced: true }
    }

    #[test]
    fn an_announced_trash_writes_its_line_once_and_frees_the_slot_at_the_announce() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut o = Ops::new(tx);
        let (id, _) = o.claim_transfer();
        let mut buf: Vec<u8> = Vec::new();
        land(&mut buf, &mut o, announced(id, std::path::Path::new("/x")));
        assert_eq!(String::from_utf8_lossy(&buf).trim(), r#"{"t":"trashed","ok":1,"failed":0}"#);
        assert!(o.live.running().is_none(), "the announce frees the slot, so any write runs while the settle list is out");
        assert_eq!(o.journal.len(), 0, "the entry stays pending until the settle list lands");
        land(&mut buf, &mut o, journaled(id, std::path::Path::new("/x")));
        assert_eq!(String::from_utf8_lossy(&buf).matches(r#""t":"trashed""#).count(), 1, "the wire carries one line per batch");
        assert_eq!(o.journal.len(), 1);
        assert!(o.settling.is_empty(), "the journal ends the wait");
    }

    #[test]
    fn an_undo_between_the_announce_and_the_settle_list_waits_then_reverses_this_trash() {
        let d = TestDir::new("trashland-undo");
        let (older, trashed) = (d.file("older.txt", "o"), d.file("trashed.txt", "t"));
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut o = Ops::new(tx);
        o.journal.push(created(&older));
        let (id, _) = o.claim_transfer();
        let mut buf: Vec<u8> = Vec::new();
        land(&mut buf, &mut o, announced(id, &trashed));
        let mut blocked: Vec<u8> = Vec::new();
        do_undo(&mut blocked, &mut o);
        let line = String::from_utf8_lossy(&blocked).to_string();
        assert!(line.contains("already running") && line.contains(&*trashed.to_string_lossy()), "undo waits on this batch's entry and names it: {line}");
        assert!(older.exists() && o.journal.len() == 1, "the earlier entry is never reversed in the window");
        land(&mut buf, &mut o, journaled(id, &trashed));
        let mut undone: Vec<u8> = Vec::new();
        do_undo(&mut undone, &mut o);
        assert!(String::from_utf8_lossy(&undone).contains(r#""t":"undone""#), "{}", String::from_utf8_lossy(&undone));
        assert!(!trashed.exists() && older.exists(), "the first undo after the settle list reverses this trash, not the earlier entry");
    }

    #[test]
    fn a_trash_sent_in_the_window_is_not_refused_and_the_old_landing_keeps_its_slot() {
        let d = TestDir::new("trashland-next");
        let (first, missing) = (d.file("first.txt", "f"), d.join("missing.txt"));
        let (tx, rx) = std::sync::mpsc::channel();
        let mut o = Ops::new(tx);
        let (id, _) = o.claim_transfer();
        let mut buf: Vec<u8> = Vec::new();
        land(&mut buf, &mut o, announced(id, &first));
        let mut next: Vec<u8> = Vec::new();
        start_trash(&mut next, &mut o, vec![missing.to_string_lossy().into()], 0);
        assert!(String::from_utf8_lossy(&next).is_empty(), "a second trash in the window answers no refusal: {}", String::from_utf8_lossy(&next));
        let second = o.live.running().expect("the second trash claimed the slot");
        land(&mut buf, &mut o, journaled(id, &first));
        assert_eq!(o.live.running(), Some(second), "the first batch landing never frees the second batch's slot");
        let done = rx.recv_timeout(std::time::Duration::from_secs(10)).expect("the second trash reports");
        assert!(matches!(done, OpMsg::Trashed { announced: false, .. }));
    }
}
