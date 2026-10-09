use super::*;
use crate::backend::testdir::TestDir;
use std::os::unix::fs::{symlink, PermissionsExt};

#[test]
fn the_shared_memory_query_names_a_fresh_private_pixel() {
    let dir = TestDir::new("shm");
    let root = dir.path();
    let query = shm_query(root, "flea-tui-shm-1").expect("query");
    assert_eq!(query, format!("\x1b_Gi=32,s=1,v=1,a=q,t=s,f=24;{}\x1b\\", crate::tui::graphics::base64(b"/flea-tui-shm-1")));
    let made = root.join("flea-tui-shm-1");
    assert_eq!(std::fs::read(&made).unwrap(), [0, 0, 0]);
    assert_eq!(std::fs::metadata(&made).unwrap().permissions().mode() & 0o777, 0o600);
}

#[test]
fn a_planted_link_at_the_name_is_replaced_never_followed() {
    let dir = TestDir::new("shm");
    let root = dir.path();
    let target = root.join("bystander");
    std::fs::write(&target, b"keep").unwrap();
    symlink(&target, root.join("flea-tui-shm-2")).unwrap();
    assert!(shm_query(root, "flea-tui-shm-2").is_some());
    assert_eq!(std::fs::read(&target).unwrap(), b"keep");
    assert!(!std::fs::symlink_metadata(root.join("flea-tui-shm-2")).unwrap().file_type().is_symlink());
}

// kitty answers in order, so the first preview knows of shared memory only if that query goes out before the kitty probe.
#[test]
fn the_shared_memory_query_goes_out_before_the_kitty_probe() {
    let source: String = include_str!("terminal.rs").lines().filter(|line| !line.trim_start().starts_with("//")).collect::<Vec<_>>().join("\n");
    let enter = &source[source.find("pub fn enter()").expect("Terminal::enter")..];
    let query = enter.find("shm_query(").expect("enter asks about shared memory");
    let probe = enter.find("screen(true)").expect("enter probes for kitty");
    assert!(query < probe, "the shared memory query follows the kitty probe, so a launch can start mpv before its answer");
}
