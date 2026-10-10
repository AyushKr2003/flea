use std::ffi::OsString;
use std::path::{Path, PathBuf};

// The child half: runs the opener only in the copy of this binary a test below starts, which alone carries the path.
#[test]
fn open_child() {
    if let Some(path) = std::env::var_os("FLEA_TEST_OPEN_ASK") {
        std::process::exit(super::open_ask(&path.to_string_lossy()));
    }
    if let Some(path) = std::env::var_os("FLEA_TEST_OPEN") {
        std::process::exit(super::open(&path.to_string_lossy()));
    }
}

// A stub gio that logs every call and names no default handler, on a PATH only the child sees.
fn stub_gio(dir: &crate::backend::testdir::TestDir) -> (OsString, PathBuf) {
    use std::os::unix::fs::PermissionsExt;
    let bin = dir.path().join("bin");
    std::fs::create_dir(&bin).expect("the stub dir is made");
    let log = dir.path().join("gio.log");
    let stub = format!(
        "#!/bin/sh\necho \"gio $*\" >> \"{}\"\nif [ \"$1\" = open ]; then exit 1; fi\nif [ \"$1\" = mime ]; then echo \"No default applications for '$2'\"; exit 0; fi\nexit 1\n",
        log.display()
    );
    std::fs::write(bin.join("gio"), stub.as_bytes()).expect("the stub is written");
    std::fs::set_permissions(bin.join("gio"), std::fs::Permissions::from_mode(0o755)).expect("the stub runs");
    let mut path = bin.into_os_string();
    path.push(":");
    path.push(std::env::var_os("PATH").unwrap_or_default());
    (path, log)
}

// The test binary again, running only the child half; libtest would refuse a bare --open.
fn run_child(var: &str, target: &Path, path: OsString) -> std::process::Output {
    std::process::Command::new("timeout")
        .arg("30")
        .arg(std::env::current_exe().expect("the test binary"))
        .args(["--exact", "open::tests::open_child", "--nocapture", "--test-threads=1"])
        .env(var, target)
        .env("PATH", path)
        .output()
        .expect("the opener runs")
}

// A FIFO takes the OpenNormally route with no snapshot: open_ask answers 5 through a stub gio, and would block forever with no writer if it opened one.
#[test]
fn a_fifo_opens_normally_without_a_snapshot() {
    let dir = crate::backend::testdir::TestDir::new("open-fifo");
    let fifo = dir.path().join("pipe");
    assert!(std::process::Command::new("mkfifo").arg(&fifo).status().expect("mkfifo starts").success());
    let (path, log) = stub_gio(&dir);
    let out = run_child("FLEA_TEST_OPEN_ASK", &fifo, path);
    assert_eq!(out.status.code(), Some(crate::runfile::ASK_OPEN_WITH), "a fifo takes the OpenNormally route");
    assert!(String::from_utf8_lossy(&out.stdout).contains(r#"{"ask":"openWith"}"#), "the ask names Open with");
    let calls = std::fs::read_to_string(&log).expect("the stub logged");
    assert!(calls.contains(&format!("open {}", fifo.display())), "gio was asked to open the fifo");
}

// An in-process caller never hands a binary missing its run bit to gio, where an AppImage launcher would run it.
#[test]
fn an_in_process_open_refuses_a_binary_missing_its_bit_without_asking_gio() {
    use std::os::unix::fs::PermissionsExt;
    let dir = crate::backend::testdir::TestDir::new("open-unbit-elf");
    let elf = dir.path().join("tool");
    let mut body = b"\x7fELF\x02\x01\x01".to_vec();
    body.resize(64, 0);
    std::fs::write(&elf, &body).expect("the binary is written");
    std::fs::set_permissions(&elf, std::fs::Permissions::from_mode(0o644)).expect("its run bit is off");
    let (path, log) = stub_gio(&dir);
    let out = run_child("FLEA_TEST_OPEN", &elf, path);
    assert_eq!(out.status.code(), Some(super::FAILED), "the binary is refused");
    assert!(String::from_utf8_lossy(&out.stderr).contains("that file is a program"), "with the program sentence: {}", String::from_utf8_lossy(&out.stderr));
    let calls = std::fs::read_to_string(&log).unwrap_or_default();
    assert!(!calls.contains("gio open"), "gio was never asked to open it: {calls}");
}
