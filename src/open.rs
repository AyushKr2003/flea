use crate::gui;
use crate::runfile;
use crate::tearoff;
use crate::thp;
use crate::vulkan;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

// The exit statuses ui/Opener.qml reads. 0 is a successful handoff and needs no name.
pub const FAILED: i32 = 2;
pub const IS_DIRECTORY: i32 = 3;

// Canonical, so a file named --output=/etc/x cannot be read as a flag by the child.
fn resolved(path: &str) -> Option<PathBuf> {
    std::fs::canonicalize(path).ok()
}

// The environment every program Flea starts carries: huge pages back on, Qt's own pin, driver exclusion and theme dropped, the tear-off hand-off kept to its window. runfile.rs reuses this.
pub fn prepare(child: &mut Command) {
    // The setting is inherited across exec, so this is the last point that can hand it back.
    thp::enable();
    // The display-GPU pin and the driver exclusion are Qt's alone, and only this launcher's own are dropped.
    vulkan::drop_display_pin(child);
    crate::icdexclude::drop_exclusion(child);
    // The platform theme Flea traded for its own startup is Qt's alone too, and is handed back here.
    gui::restore_platform_theme(child);
    // The tear-off hand-off belongs to the one window a tear-off starts, never to a program it opens.
    tearoff::drop_env(child);
}

// In-process callers (the TUI, the shelf) stay on 0/2/3: an executable is refused with its sentence, and only the main.rs --open path asks the card, through open_ask.
pub fn open(path: &str) -> i32 {
    open_inner(path, false)
}

// The window's own entrance: a program asks once on the run card instead of reaching a handler.
pub fn open_ask(path: &str) -> i32 {
    open_inner(path, true)
}

// gio open is the OEM route: it asks the desktop database, so Terminal=true is honoured; see AGENTS.md "Opening a file".
fn open_inner(path: &str, ask: bool) -> i32 {
    let target = match resolved(path) {
        Some(p) => p,
        // The reason is elided, never shown raw, and the path is the user's own input.
        None => {
            eprintln!("flea: that file could not be opened, check that it still exists");
            return FAILED;
        }
    };
    if target.is_dir() {
        return IS_DIRECTORY;
    }
    // A FIFO, socket or device is never a program and never blocks here: it skips the snapshot and the run decision and opens the way it always did.
    if !target.is_file() {
        return open_normally(&target, ask);
    }
    // One open for the kind and the identity together, so a swap between them cannot pair two files.
    let opened = match crate::runid::snapshot(&target) {
        Some(o) => o,
        None => {
            eprintln!("flea: that file could not be opened, check that it still exists");
            return FAILED;
        }
    };
    // A program asks once on the run card instead of reaching a handler, and a file no application claims asks Open with.
    let body = std::fs::read("/proc/self/mountinfo").unwrap_or_default();
    let mounts = String::from_utf8_lossy(&body).into_owned();
    let decision = runfile::decide_opened(&opened, &target, &mounts);
    let make = matches!(decision, runfile::Decision::MakeExecutable(_));
    match decision {
        runfile::Decision::Ask(kind) | runfile::Decision::MakeExecutable(kind) => {
            // A caller with no card refuses every program a handler could launch: an executable one, and a binary missing its bit (an AppImage launcher runs it); a script missing its bit opens with its handler the way it always did.
            if !ask && (!make || !matches!(kind, runfile::Kind::Script)) {
                eprintln!("flea: that file is a program, so it was not opened");
                return FAILED;
            }
            if ask {
                let handler = matches!(kind, runfile::Kind::AppImage) && crate::desktopid::has_handler(&target);
                println!("{}", runfile::ask_line(kind, make, handler, &opened.id, &target));
                return runfile::ASK_RUN;
            }
        }
        runfile::Decision::RefuseNoExec => {
            eprintln!("flea: that program is on a volume that does not allow running files");
            return FAILED;
        }
        runfile::Decision::OpenNormally => {}
    }
    open_normally(&target, ask)
}

// Past every run decision: handed to gio open and waited on, the way the opener always did.
fn open_normally(target: &Path, ask: bool) -> i32 {
    // corner: waited for, not detached, and on an archive that wait is a cold handler start; see AGENTS.md "Opening a file".
    let mut launcher = Command::new("gio");
    prepare(&mut launcher);
    let finished = launcher
        .arg("open")
        .arg(target)
        // The handler outlives us, so an inherited pipe would kill it on its first write; see AGENTS.md "Opening a file".
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        // Its own process group, so nothing that later kills Flea's group reaches the opened program.
        .process_group(0)
        .status();
    match finished {
        Ok(status) if status.success() => 0,
        // A launcher that refused, which a spawn nobody waited on used to report as a clean handoff.
        Ok(_) => {
            // A file no application claims opens the approved Open with dialog instead, on the window's path alone.
            if ask && crate::desktopid::unclaimed(target) {
                println!(r#"{{"ask":"openWith"}}"#);
                return runfile::ASK_OPEN_WITH;
            }
            eprintln!("flea: gio open refused that file, so no application on this system took it");
            FAILED
        }
        Err(_) => {
            eprintln!("flea: nothing on this system could be asked to open that file");
            FAILED
        }
    }
}

#[cfg(test)]
mod tests {
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
}
