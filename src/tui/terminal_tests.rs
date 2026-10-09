use super::*;
use std::os::unix::fs::{symlink, PermissionsExt};

fn root() -> std::path::PathBuf {
    let output = Command::new("mktemp").args(["-d", "/tmp/flea-shm-test-XXXXXX"]).output().expect("mktemp");
    let root = std::path::PathBuf::from(String::from_utf8_lossy(&output.stdout).trim());
    std::fs::write(root.join(".flea-test-sandbox"), b"").expect("marker");
    root
}

#[test]
fn the_shared_memory_query_names_a_fresh_private_pixel() {
    let root = root();
    let query = shm_query(&root, "flea-tui-shm-1").expect("query");
    assert_eq!(query, format!("\x1b_Gi=32,s=1,v=1,a=q,t=s,f=24;{}\x1b\\", crate::tui::graphics::base64(b"/flea-tui-shm-1")));
    let made = root.join("flea-tui-shm-1");
    assert_eq!(std::fs::read(&made).unwrap(), [0, 0, 0]);
    assert_eq!(std::fs::metadata(&made).unwrap().permissions().mode() & 0o777, 0o600);
    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn a_planted_link_at_the_name_is_replaced_never_followed() {
    let root = root();
    let target = root.join("bystander");
    std::fs::write(&target, b"keep").unwrap();
    symlink(&target, root.join("flea-tui-shm-2")).unwrap();
    assert!(shm_query(&root, "flea-tui-shm-2").is_some());
    assert_eq!(std::fs::read(&target).unwrap(), b"keep");
    assert!(!std::fs::symlink_metadata(root.join("flea-tui-shm-2")).unwrap().file_type().is_symlink());
    std::fs::remove_dir_all(&root).unwrap();
}
