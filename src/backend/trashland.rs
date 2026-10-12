// A trash batch's worker and its landing: the outcome line goes out as soon as the disk shows it, the journal entry after the settle list.
use crate::backend::opsdispatch::Ops;
use crate::backend::opsreq::{op_err, trashed_line, OpMsg};
use crate::backend::trash;
use crate::backend::undo::{Entry, Step};
use std::io::Write;
use std::path::PathBuf;
use std::sync::mpsc::Sender;

pub(crate) fn run_trash(paths: Vec<String>, tx: Sender<OpMsg>, selection: Option<Vec<super::menu_actions::Selected>>) {
    let owned: Vec<PathBuf> = paths.iter().map(PathBuf::from).collect();
    let mut announced = false;
    let early = tx.clone();
    let mut announce = |ok: usize, failed: usize, reason: &str| {
        announced = early.send(OpMsg::TrashAnnounced { ok, failed, reason: reason.to_string() }).is_ok();
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
    let _ = tx.send(OpMsg::Trashed { ok, failed, entry, reason, announced });
}

// The announce writes the line and leaves the slot claimed; the journal message frees it and writes the line only when none went before.
pub(crate) fn land(out: &mut impl Write, ops: &mut Ops, msg: OpMsg) {
    match msg {
        OpMsg::TrashAnnounced { ok, failed, reason } => { writeln!(out, "{}", trashed_line(ok, failed, &reason)).ok(); }
        OpMsg::Trashed { ok, failed, entry, reason, announced } => {
            ops.journal.push(entry);
            ops.live.finished();
            if !announced { writeln!(out, "{}", trashed_line(ok, failed, &reason)).ok(); }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_announced_trash_writes_its_line_once_and_frees_the_slot_only_at_the_journal() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut o = Ops::new(tx);
        o.claim_transfer();
        let mut buf: Vec<u8> = Vec::new();
        land(&mut buf, &mut o, OpMsg::TrashAnnounced { ok: 1, failed: 0, reason: String::new() });
        assert_eq!(String::from_utf8_lossy(&buf).trim(), r#"{"t":"trashed","ok":1,"failed":0}"#);
        assert!(o.live.running().is_some(), "the settle list is still out, so the slot stays claimed");
        assert_eq!(o.journal.len(), 0);
        let entry = Entry { op: "trash".to_string(), steps: vec![Step::Created { path: "/x".into() }] };
        land(&mut buf, &mut o, OpMsg::Trashed { ok: 1, failed: 0, entry, reason: String::new(), announced: true });
        assert_eq!(String::from_utf8_lossy(&buf).matches(r#""t":"trashed""#).count(), 1, "the wire carries one line per batch");
        assert!(o.live.running().is_none());
        assert_eq!(o.journal.len(), 1);
    }
}
