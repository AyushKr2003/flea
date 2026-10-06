use super::*;
use std::os::unix::fs::PermissionsExt;

// Every destructive probe writes inside hard rule 9's own sandbox and nowhere else.
fn write(dir: &crate::backend::testdir::TestDir, name: &str, bytes: &[u8], mode: u32) -> PathBuf {
    let path = dir.path().join(name);
    std::fs::write(&path, bytes).expect("the fixture is written");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).expect("its mode is set");
    path
}

#[test]
fn a_shebang_names_a_script_whatever_follows() {
    assert_eq!(classify_header(b"#!/bin/sh\ntrue\n", "run.sh"), Some(Kind::Script));
    assert_eq!(classify_header(b"#!", "run"), Some(Kind::Script));
    assert_eq!(kind_name(Kind::Script), "script");
}

#[test]
fn an_elf_names_elf_unless_it_is_an_appimage() {
    let mut elf = b"\x7fELF".to_vec();
    elf.extend_from_slice(&[0u8; 64]);
    assert_eq!(classify_header(&elf, "tool"), Some(Kind::Elf));
    assert_eq!(kind_name(Kind::Elf), "elf");
    let mut marked = elf.clone();
    marked.extend_from_slice(b"AppImage");
    assert_eq!(classify_header(&marked, "tool"), Some(Kind::AppImage));
    assert_eq!(classify_header(&elf, "Obsidian-1.9.AppImage"), Some(Kind::AppImage));
    assert_eq!(classify_header(&elf, "OBSIDIAN.APPIMAGE"), Some(Kind::AppImage));
    assert_eq!(classify_header(&elf, "appimage.txt"), Some(Kind::Elf));
    assert_eq!(kind_name(Kind::AppImage), "appimage");
}

#[test]
fn anything_else_is_not_a_program() {
    assert_eq!(classify_header(b"hello", "a.txt"), None);
    assert_eq!(classify_header(b"", "a"), None);
    assert_eq!(classify_header(b"\x7fEL", "short"), None);
    assert_eq!(classify_header(b"# !/bin/sh", "hash"), None);
}

#[test]
fn an_executable_script_asks_and_a_plain_one_offers_the_chmod_path() {
    let dir = crate::backend::testdir::TestDir::new("runfile-decide");
    let exec = write(&dir, "run.sh", b"#!/bin/sh\ntrue\n", 0o755);
    let plain = write(&dir, "plain.sh", b"#!/bin/sh\ntrue\n", 0o644);
    let text = write(&dir, "note.txt", b"hello", 0o644);
    let mounts = "1 0 8:1 / / rw - ext4 /dev/a rw\n";
    assert_eq!(decide_with(&exec, mounts), Decision::Ask(Kind::Script));
    assert_eq!(decide_with(&plain, mounts), Decision::MakeExecutable(Kind::Script));
    assert_eq!(decide_with(&text, mounts), Decision::OpenNormally);
    assert_eq!(decide_with(dir.path(), mounts), Decision::OpenNormally);
    assert_eq!(decide_with(&dir.path().join("nowhere"), mounts), Decision::OpenNormally);
}

#[test]
fn a_noexec_mount_refuses_instead_of_asking() {
    let dir = crate::backend::testdir::TestDir::new("runfile-noexec");
    let exec = write(&dir, "run.sh", b"#!/bin/sh\ntrue\n", 0o755);
    let root = dir.path().display().to_string();
    let mounts = format!("1 0 8:1 / / rw - ext4 /dev/a rw\n2 1 0:99 / {} rw,noexec - tmpfs tmpfs rw\n", root);
    assert_eq!(decide_with(&exec, &mounts), Decision::RefuseNoExec);
    let mounts = format!("1 0 8:1 / / rw - ext4 /dev/a rw\n2 1 0:99 / {} rw - tmpfs tmpfs rw\n", root);
    assert_eq!(decide_with(&exec, &mounts), Decision::Ask(Kind::Script));
}

#[test]
fn hostile_names_run_as_the_literal_file() {
    // R2: a hostile name runs as the literal file, one argv element and never a shell string.
    for nasty in ["-e", ";rm -rf x", "$(touch pwned)", "a'b\"c", "--flag=x"] {
        let target = PathBuf::from("/tmp/dir").join(nasty);
        assert_eq!(run_argv(&target), vec![target.as_os_str().to_owned()]);
        let argv = terminal_argv(Path::new("/tmp/dir"), &target);
        assert_eq!(argv.len(), 4);
        assert_eq!(argv[2].to_string_lossy(), "-e");
        assert_eq!(argv[3], target.as_os_str().to_owned());
    }
}

#[test]
fn the_argv_is_one_absolute_argument_whatever_the_name_holds() {
    for nasty in ["with space.sh", "qu'ote.sh", "--dash.sh", "two\nlines.sh"] {
        let target = PathBuf::from("/tmp/dir").join(nasty);
        assert_eq!(run_argv(&target), vec![target.as_os_str().to_owned()]);
        let argv = terminal_argv(Path::new("/tmp/dir"), &target);
        assert_eq!(argv.len(), 4);
        assert_eq!(argv[3], target.as_os_str().to_owned());
        assert!(argv[1].to_string_lossy().starts_with("--dir=/tmp/dir"));
    }
    let argv = terminal_argv(Path::new("/tmp/dir"), Path::new("/tmp/dir/a.sh"));
    let text: Vec<String> = argv.iter().map(|a| a.to_string_lossy().into_owned()).collect();
    assert_eq!(text[0], "xdg-terminal-exec");
    assert_eq!(text[2], "-e");
}

#[test]
fn the_handler_line_names_the_desktop_id_or_nothing() {
    assert_eq!(handler_of("Default application for 'text/plain': nvim.desktop"), "nvim.desktop");
    assert_eq!(handler_of("No default applications for 'text/plain'"), "");
    assert_eq!(handler_of("junk"), "");
    assert_eq!(handler_of(""), "");
}

// The card's Make executable reuses the menu's permissions batch, so no second chmod lives here to pin.

// R3 fixture: a script that plants a canary beside itself if it ever starts, so a swapped file that runs shows.
fn canary_script(dir: &crate::backend::testdir::TestDir, name: &str) -> PathBuf {
    write(dir, name, b"#!/bin/sh\ntouch canary\n", 0o755)
}

#[test]
fn a_file_swapped_after_the_ask_refuses_run() {
    let dir = crate::backend::testdir::TestDir::new("runfile-swap");
    let tool = canary_script(&dir, "tool.sh");
    let asked = crate::runid::capture(&tool).expect("a written file has an identity");
    std::fs::write(&tool, b"#!/bin/sh\ntouch canary\necho changed\n").expect("the swap lands");
    assert_eq!(run(tool.to_str().unwrap(), &asked), 2);
    assert_eq!(run_in_terminal(tool.to_str().unwrap(), &asked), 2);
    assert!(!dir.path().join("canary").exists(), "nothing started");
}

#[test]
fn a_symlink_retargeted_after_the_ask_refuses_run() {
    let dir = crate::backend::testdir::TestDir::new("runfile-retarget");
    let first = write(&dir, "v1.sh", b"#!/bin/sh\ntouch canary\n", 0o755);
    let second = write(&dir, "v2.sh", b"#!/bin/sh\ntouch canary\n", 0o755);
    let link = dir.path().join("tool.sh");
    std::os::unix::fs::symlink(&first, &link).expect("the link is made");
    let asked = crate::runid::capture(&link).expect("the link resolves to an identity");
    std::fs::remove_file(&link).expect("the link is lifted");
    std::os::unix::fs::symlink(&second, &link).expect("the link is retargeted");
    assert_eq!(run(link.to_str().unwrap(), &asked), 2);
    assert!(!dir.path().join("canary").exists(), "nothing started");
}

#[test]
fn a_shebang_names_a_script_even_under_a_text_name() {
    // R4: the kind comes from the bytes, never the extension.
    assert_eq!(classify_header(b"#!/bin/sh\ntrue\n", "note.txt"), Some(Kind::Script));
    assert_eq!(classify_header(b"\x7fELF", "clip.mp4"), Some(Kind::Elf));
}

#[test]
fn translated_handler_lines_name_nothing() {
    // R7: a translated handler line names nothing, so the card asks Open with instead of misreading another language's sentence.
    assert_eq!(handler_of("Aplicaci\u{f3}n predeterminada para 'text/plain': nvim.desktop"), "");
    assert_eq!(handler_of("Standardanwendung f\u{fc}r 'text/plain': nvim.desktop"), "");
}

#[test]
fn spawned_child_sees_no_fd_above_2_and_no_private_env() {
    // The R6 probe: the child half reports and the parent half judges, re-running this test behind FLEA_RUNFILE_PROBE.
    if std::env::var_os("FLEA_RUNFILE_PROBE").is_some() {
        probe_report();
        return;
    }
    assert!(std::env::var_os("FLEA_RUNFILE_DEPTH").is_none(), "the probe never re-spawns");
    let dir = crate::backend::testdir::TestDir::new("runfile-probe");
    // A raw open with no O_CLOEXEC, which Rust's own files never are: only the R6 close keeps it from the child.
    extern "C" { fn open(path: *const std::os::raw::c_char, flags: std::os::raw::c_int, ...) -> std::os::raw::c_int; }
    let raw = unsafe { open(c"/dev/null".as_ptr(), 0) };
    assert!(raw > 2, "the probe needs a descriptor above 2 to lose");
    let _keep = unsafe { <std::fs::File as std::os::unix::io::FromRawFd>::from_raw_fd(raw) };
    std::env::set_var("FLEA_RUNFILE_SECRET", "stale");
    let exe = std::env::current_exe().expect("the test binary");
    let mut child = std::process::Command::new(&exe);
    child.arg("--exact").arg("runfile::tests::spawned_child_sees_no_fd_above_2_and_no_private_env");
    child.arg("--nocapture");
    child.current_dir(dir.path());
    crate::terminal::detach(&mut child);
    super::runharden::harden(&mut child);
    child.env("FLEA_RUNFILE_PROBE", "1");
    child.env("FLEA_RUNFILE_DEPTH", "1");
    child.stdout(std::process::Stdio::piped());
    let spawned = child.spawn().expect("the probe starts");
    let out = spawned.wait_with_output().expect("the probe is reaped");
    std::env::remove_var("FLEA_RUNFILE_SECRET");
    assert!(out.status.success(), "the probe child ran");
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.lines().any(|line| line == "fds=0,1,2"), "child fds: {text}");
    assert!(text.lines().any(|line| line == "secret=absent"), "child env: {text}");
}

fn probe_report() {
    let mut fds: Vec<String> = Vec::new();
    let own = format!("/proc/{}/fd", std::process::id());
    if let Ok(entries) = std::fs::read_dir("/proc/self/fd") {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            // The listing holds its own directory handle open; that one is us.
            if entry.path().read_link().map(|target| target.to_string_lossy() == own).unwrap_or(false) {
                continue;
            }
            fds.push(name);
        }
    }
    fds.sort();
    println!("fds={}", fds.join(","));
    let secret = std::env::vars_os().any(|(key, _)| key.to_string_lossy() == "FLEA_RUNFILE_SECRET");
    println!("secret={}", if secret { "present" } else { "absent" });
}
