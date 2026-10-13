use super::*;
use crate::backend::{proto::{self, Request}, testdir::TestDir};
use std::sync::mpsc;

#[test]
fn the_html_request_preserves_identity_and_bounds_width() {
    let Request::Html(ask) = proto::parse_request(r#"{"c":"html","token":7,"slot":"column","path":"/a/index.html","width":300}"#) else { panic!("html request not parsed") };
    assert_eq!((ask.token, ask.slot.as_str(), ask.path.as_str(), ask.width, ask.cancel), (7, "column", "/a/index.html", 300, false));
    assert_eq!(Ask::parse(r#"{"width":0}"#).width, 1);
    assert_eq!(Ask::parse(r#"{"width":999999}"#).width, 4096);
    assert!(Ask::parse(r#"{"cancel":true}"#).cancel);
    assert_eq!(Ask::parse(r#"{"height":900}"#).height, 900);
    assert_eq!(Ask::parse(r#"{"height":0}"#).height, 1);
    assert_eq!(Ask::parse(r#"{"height":999999}"#).height, htmlcache::MAX_HEIGHT as usize);
    let large = Ask::parse(r#"{"width":8192,"height":1250}"#);
    assert_eq!((large.width, large.height), (htmlcache::MAX_WIDTH, 625));
    assert_eq!(Ask::parse(r#"{"width":8192}"#).height, htmlcache::DEFAULT_HEIGHT);
}

#[test]
fn the_html_jail_keeps_cpu_network_readonly_folder_and_only_one_writable_directory() {
    let inner = vec!["/usr/bin/qml6".into(), "/output/render.qml".into()];
    let argv = sandbox::wrap_html(&inner, Path::new("/files/index.html"), Path::new("/cache/work"));
    assert_eq!(&argv[..3], ["prlimit", "--cpu=30", "bwrap"]);
    assert!(!argv.iter().any(|a| a.starts_with("--as=")));
    for flag in ["--unshare-all", "--die-with-parent", "--clearenv"] { assert!(argv.iter().any(|a| a == flag)); }
    assert!(argv.windows(3).any(|w| w == ["--ro-bind", "/files", "/page"]));
    assert!(argv.windows(3).any(|w| w == ["--ro-bind", "/cache/work/input.html", "/page/index.html"]));
    assert!(argv.windows(3).any(|w| w == ["--bind", "/cache/work", "/output"]));
    assert_eq!(argv.iter().filter(|a| a.as_str() == "--bind").count(), 1);
    assert_eq!(&argv[argv.len() - inner.len()..], inner);
}

#[test]
fn a_newer_html_request_cancels_the_older_ticket_and_drops_its_reply() {
    let older = codereq::begin("html:test-cancel");
    let newer = codereq::begin("html:test-cancel");
    assert!(older.superseded());
    let (tx, rx) = mpsc::channel();
    older.finish("older".into(), &tx);
    assert!(rx.try_recv().is_err());
    newer.finish("newer".into(), &tx);
    assert!(matches!(rx.recv().unwrap(), OpMsg::Meta { line } if line == "newer"));
}

#[test]
fn html_and_code_slots_do_not_cancel_each_other() {
    for slot in ["test-isolated", "code:test-isolated"] {
        let code = codereq::begin("code:test-isolated");
        let (tx, rx) = mpsc::channel();
        spawn(Ask::parse(&format!(r#"{{"slot":"{slot}","cancel":true}}"#)), tx.clone());
        assert!(matches!(rx.recv_timeout(Duration::from_secs(5)).unwrap(), OpMsg::Meta { line } if line.contains("cancelled")));
        assert!(!code.superseded(), "HTML slot {slot} collided with a code ticket");
        code.finish("code".into(), &tx);
        assert!(matches!(rx.recv().unwrap(), OpMsg::Meta { line } if line == "code"));
    }
}

#[test]
fn policy_precedes_resources_and_keeps_the_doctype() {
    let text = String::from_utf8(confined_html(b"<!doctype html><html><head></head><body></body></html>")).unwrap();
    assert!(text.starts_with("<!doctype html><meta http-equiv=\"Content-Security-Policy\""));
    assert!(text.contains("default-src 'none'"));
    assert!(text.contains("img-src file://*/page/ data:"));
    assert!(!text.contains("<base"));
}

#[test]
fn a_bom_whitespace_and_complete_comments_keep_the_doctype_before_the_policy() {
    for prefix in ["<!-- leading -->", "\u{feff}\n <!-- one -->\t<!-- two -->\r\n", " \n\t"] {
        let source = format!("{prefix}<!DOCTYPE html><html>");
        let text = String::from_utf8(confined_html(source.as_bytes())).unwrap();
        assert!(text.starts_with(&format!("{prefix}<!DOCTYPE html><meta")), "{text}");
    }
    let text = String::from_utf8(confined_html(b"<!-- incomplete <!doctype html><html>")).unwrap();
    assert!(text.starts_with("<meta"));
}

#[test]
fn the_doctype_ends_at_the_first_greater_than_even_inside_a_quoted_identifier() {
    let text = String::from_utf8(confined_html(b"<!doctype html PUBLIC \"a>b\"><html>")).unwrap();
    assert!(text.starts_with("<!doctype html PUBLIC \"a><meta"));
    assert!(text.ends_with("b\"><html>"));
}

#[test]
fn private_helper_files_are_created_exclusively() {
    let d = TestDir::new("html-exclusivity");
    let outside = d.file("target", "untouched");
    let planted = d.join("render.qml");
    std::os::unix::fs::symlink(&outside, &planted).unwrap();
    assert!(exclusive(&planted, b"new").is_none());
    assert_eq!(std::fs::read(&outside).unwrap(), b"untouched");
    let file = d.join("page.png");
    assert!(exclusive(&file, b"png").is_some());
    assert!(exclusive(&file, b"second").is_none());
    assert_eq!(std::fs::read(&file).unwrap(), b"png");
}

#[test]
fn a_new_html_ticket_ends_a_live_helper_and_suppresses_its_reply() {
    let old = codereq::begin("html:live-cancel");
    let process = jail::spawn_jailed(&["/usr/bin/sleep".into(), "30".into()], |cmd| {
        cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    }).unwrap();
    let pid = process.child.id();
    assert!(old.attach(process));
    let newer = codereq::begin("html:live-cancel");
    assert!(old.reap_until(Some(Instant::now() + LIMIT)).is_none());
    let end = Instant::now() + Duration::from_secs(5);
    let path = format!("/proc/{pid}");
    while Path::new(&path).exists() && Instant::now() < end { std::thread::sleep(Duration::from_millis(10)); }
    assert!(!Path::new(&path).exists(), "the cancelled helper must be reaped");
    let (tx, rx) = mpsc::channel();
    old.finish("stale".into(), &tx);
    assert!(rx.try_recv().is_err());
    newer.finish("current".into(), &tx);
    assert!(matches!(rx.recv().unwrap(), OpMsg::Meta { line } if line == "current"));
}

#[test]
fn a_helper_past_the_deadline_is_killed_and_reports_timeout() {
    let ticket = codereq::begin("html:timeout");
    let process = jail::spawn_jailed(&["/usr/bin/sleep".into(), "30".into()], |cmd| {
        cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    }).unwrap();
    let pid = process.child.id();
    assert!(ticket.attach(process));
    let result = ticket.reap_until(Some(Instant::now() + Duration::from_millis(20))).unwrap();
    assert_eq!(result.unwrap_err().kind(), std::io::ErrorKind::TimedOut);
    assert!(!Path::new(&format!("/proc/{pid}")).exists());
    let (tx, _) = mpsc::channel();
    ticket.finish("failed".into(), &tx);
}
