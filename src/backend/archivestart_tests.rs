use super::*;
use crate::backend::testdir::TestDir;

// AA4: a disk image extract is refused before the slot and before any start line, so no job starts.
#[test]
fn an_iso_extract_answers_archivedone_and_starts_nothing() {
    let d = TestDir::new("archisostart");
    let (tx, _rx) = std::sync::mpsc::channel();
    let mut ops = Ops::new(tx);
    let mut out = Vec::new();
    start_archive(&mut out, &mut ops, Arc::new(Formats::from_tools(true, true)), "extract", Vec::new(),
        "7z".into(), d.join("debian-13.iso"), d.join("debian-13"), 0, String::new(), false);
    let text = String::from_utf8(out).unwrap();
    assert_eq!(text.lines().count(), 1, "one terminal line and nothing before it: {}", text);
    assert!(text.contains(r#""t":"archivedone""#) && text.contains(r#""ok":false"#), "{}", text);
    assert!(text.contains("disk images list and are never extracted"), "{}", text);
    for started in ["archivestarted", "extractstarted", "transferprogress"] {
        assert!(!text.contains(started), "a refused extract announced {}: {}", started, text);
    }
    assert!(ops.live.running().is_none(), "a refused extract took the slot");
}
