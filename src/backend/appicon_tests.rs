use super::*;
use crate::backend::aliases::Aliases;
use crate::backend::testdir::TestDir;
use crate::backend::thumbcache::{png_text, Cache, Hit};
use crate::backend::thumbspec::Thumbnailers;
use crate::backend::thumbwrite::write_marker;
use std::sync::Arc;

const MTIME: i64 = 1787790423;
const APPIMAGE: &str = "application/vnd.appimage";
// Stands in for 7z: `l` prints the image file itself, which holds the canned listing; `e` writes the canned bytes under the member's base name.
const STUB: &str = r#"mode=$1; shift
for a in "$@"; do last=$a; case $a in -o*) out=${a#-o};; esac; done
case $mode in
  l) cat "$last";;
  e) mkdir -p "$out" && printf '__BYTES__' > "$out/${last##*/}";;
esac"#;

// The same argv as the jail runs, without the namespaces, so the argv, the redirect and the parse are proved on a box whose bwrap cannot start.
fn unjailed(inner: Vec<String>, _image: &Path, _work: &mut Work, _limit: Duration) -> Result<(), Stop> {
    let status = std::process::Command::new(&inner[0]).args(&inner[1..]).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status();
    if status.is_ok_and(|s| s.success()) { Ok(()) } else { Err(Stop::Refused) }
}

fn octal(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("\\{:03o}", b)).collect()
}

fn stub(member: &[u8]) -> Vec<String> {
    ["/usr/bin/sh", "-c", &STUB.replace("__BYTES__", &octal(member)), "stub"].map(String::from).to_vec()
}

// Sample records: ("A.png", "Symbolic Link = B.png") is a link, ("B.png", "") a file.
fn listing(records: &[(&str, &str)]) -> String {
    let mut text = String::from("Path = /x/app.AppImage\nType = SquashFS\n\n----------\n");
    for (path, extra) in records {
        text.push_str(&format!("Path = {}\nSize = 67\nFolder = -\n{}\n\n", path, extra));
    }
    text
}

fn png(dir: &TestDir) -> Vec<u8> {
    let path = dir.join("icon.png");
    write_marker(&path, "file:///icon", 0).unwrap();
    std::fs::read(path).unwrap()
}

struct Fixture {
    _dir: TestDir,
    tables: Tables,
    job: Job,
}

fn fixture(tag: &str, text: &str) -> Fixture {
    let dir = TestDir::new(tag);
    dir.file("app.AppImage", text);
    let aliases = Arc::new(Aliases::load());
    let specs = Arc::new(Thumbnailers::load(&aliases).with_appimage_route(&aliases, true));
    let cache = Cache::at(dir.join("cache"));
    let job = Job { path: dir.join("app.AppImage"), mtime: MTIME, mime: APPIMAGE.to_string(), trace: None };
    Fixture { _dir: dir, tables: Tables { aliases, specs, cache, worker: None }, job }
}

fn published(f: &Fixture) -> usize {
    std::fs::read_dir(f.tables.cache.large_dir()).map(|d| d.count()).unwrap_or(0)
}

fn failed_and_recorded(f: &Fixture, out: Outcome) {
    assert!(matches!(out, Outcome::Failed));
    assert!(matches!(f.tables.cache.lookup(&f.job.path, MTIME), Hit::Failed), "no fail marker was recorded");
    assert_eq!(published(f), 0, "a failed job left a file in large/");
}

#[test]
fn a_png_dir_icon_publishes_once_and_the_cache_answers_the_second_request() {
    let d = TestDir::new("appicon-bytes");
    let bytes = png(&d);
    let f = fixture("appicon-png", &listing(&[(".DirIcon", "")]));
    let out = run_with(&stub(&bytes), unjailed, &f.tables, &f.job);
    let Outcome::Ready(path) = out else { panic!("a PNG .DirIcon did not publish") };
    assert_eq!(png_text(&std::fs::read(&path).unwrap(), "Thumb::URI"), Some(uri_for(&f.job.path)));
    assert_eq!(published(&f), 1, "a temp or work folder survived the publish");
    // A request that finds this answer never queues a job, so a second one at the same mtime runs nothing.
    assert!(matches!(f.tables.cache.lookup(&f.job.path, MTIME), Hit::Ready(_)));
}

#[test]
fn the_jail_runs_the_same_chain() {
    if crate::backend::sandboxprobe::skipped() { return; }
    let bytes = png(&TestDir::new("appicon-bytes"));
    let f = fixture("appicon-jail", &listing(&[(".DirIcon", "Symbolic Link = app.png"), ("app.png", "")]));
    assert!(matches!(run_with(&stub(&bytes), within, &f.tables, &f.job), Outcome::Ready(_)));
    let f = fixture("appicon-jail-none", &listing(&[("AppRun", "")]));
    failed_and_recorded(&f, run_with(&stub(&bytes), within, &f.tables, &f.job));
}

#[test]
fn a_symlink_chain_inside_the_image_resolves() {
    let bytes = png(&TestDir::new("appicon-bytes"));
    let text = listing(&[(".DirIcon", "Symbolic Link = share/app.png"), ("share/app.png", "Symbolic Link = ../real/app.png"), ("real/app.png", "")]);
    let f = fixture("appicon-chain", &text);
    assert!(matches!(run_with(&stub(&bytes), unjailed, &f.tables, &f.job), Outcome::Ready(_)));
}

#[test]
fn a_chain_that_leaves_the_image_is_refused_and_recorded() {
    let bytes = png(&TestDir::new("appicon-bytes"));
    for (tag, target) in [("appicon-up", "../../etc/passwd"), ("appicon-abs", "/usr/share/icons/app.png")] {
        let f = fixture(tag, &listing(&[(".DirIcon", &format!("Symbolic Link = {}", target)), ("etc/passwd", ""), ("usr/share/icons/app.png", "")]));
        failed_and_recorded(&f, run_with(&stub(&bytes), unjailed, &f.tables, &f.job));
    }
}

#[test]
fn a_loop_is_refused_and_recorded() {
    let bytes = png(&TestDir::new("appicon-bytes"));
    let f = fixture("appicon-loop", &listing(&[(".DirIcon", "Symbolic Link = a.png"), ("a.png", "Symbolic Link = .DirIcon")]));
    failed_and_recorded(&f, run_with(&stub(&bytes), unjailed, &f.tables, &f.job));
}

#[test]
fn a_missing_dir_icon_records_a_failure_and_a_non_png_member_does_too() {
    let bytes = png(&TestDir::new("appicon-bytes"));
    let f = fixture("appicon-none", &listing(&[("AppRun", "")]));
    failed_and_recorded(&f, run_with(&stub(&bytes), unjailed, &f.tables, &f.job));
    let f = fixture("appicon-text", &listing(&[(".DirIcon", "")]));
    failed_and_recorded(&f, run_with(&stub(b"not an image"), unjailed, &f.tables, &f.job));
}

#[test]
fn a_missing_7z_records_nothing_and_leaves_the_row_without_a_route() {
    let missing = vec!["/definitely/not/7z".to_string()];
    let f = fixture("appicon-no-tool", &listing(&[(".DirIcon", "")]));
    assert!(matches!(run_with(&missing, unjailed, &f.tables, &f.job), Outcome::Failed));
    assert!(matches!(f.tables.cache.lookup(&f.job.path, MTIME), Hit::Miss), "a missing package was recorded as a broken file");
    let aliases = Aliases::load();
    let without = Thumbnailers::from_entries(&[], &aliases).with_appimage_route(&aliases, false);
    assert!(without.for_mime(APPIMAGE, &aliases).is_none(), "the row would be asked for an icon it cannot get");
    let with = Thumbnailers::from_entries(&[], &aliases).with_appimage_route(&aliases, true);
    for mime in MIMES {
        assert!(with.for_mime(mime, &aliases).is_some_and(is_route), "{} has no route", mime);
    }
}

#[test]
fn a_thumbnailer_file_that_declares_an_appimage_keeps_it() {
    let aliases = Aliases::load();
    let entries = [("x.thumbnailer".to_string(), "[Thumbnailer Entry]\nExec=/usr/bin/true %i\nMimeType=application/vnd.appimage;\n".to_string())];
    let specs = Thumbnailers::from_entries(&entries, &aliases).with_appimage_route(&aliases, true);
    assert!(!is_route(specs.for_mime(APPIMAGE, &aliases).unwrap()));
}

#[test]
fn the_chain_is_followed_at_most_four_links_and_only_inside_the_image() {
    let link = |to: &str| format!("Symbolic Link = {}", to);
    let four = listing(&[(".DirIcon", &link("a")), ("a", &link("b")), ("b", &link("c")), ("c", &link("d")), ("d", "")]);
    assert_eq!(resolve(&four), Ok("d".to_string()));
    let five = listing(&[(".DirIcon", &link("a")), ("a", &link("b")), ("b", &link("c")), ("c", &link("d")), ("d", &link("e")), ("e", "")]);
    assert!(resolve(&five).is_err(), "a fifth link was followed");
    let out = listing(&[(".DirIcon", &link("usr/../../x")), ("x", "")]);
    assert!(resolve(&out).is_err(), "a link climbed past the image root");
    let inside = listing(&[(".DirIcon", &link("usr/../icon.png")), ("icon.png", "")]);
    assert_eq!(resolve(&inside), Ok("icon.png".to_string()));
    let nested = listing(&[(".DirIcon", &link("usr/share/a.png")), ("usr/share/a.png", &link("../b.png")), ("usr/b.png", "")]);
    assert_eq!(resolve(&nested), Ok("usr/b.png".to_string()));
    assert!(resolve(&listing(&[("AppRun", "")])).is_err());
    assert!(resolve("garbage").is_err());
}
