use super::*;
use crate::backend::archivework::{set_drain_secs, set_reader_hold_ms, CANCEL_DRAIN_SECS};
use crate::backend::testdir::TestDir;
use std::io::Read;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc::{channel, Sender};
use std::sync::atomic::AtomicUsize;

const CANARY: &str = "S3cr3t-canary-1006";
// How long a test waits for its stub to report before it calls the stub lost.
const REPORT_BOUND: Duration = Duration::from_secs(30);

// N1: 7z reads a bare -p as an empty password and never reads stdin, so an extract carries none.
#[test]
fn a_password_extract_argv_carries_no_password_flag() {
    let f = Formats::from_tools(true, true);
    let got = extract_argv(&f, Path::new("/x/a.7z"), Path::new("/out")).expect("a 7z extract has an argv");
    assert_eq!(got[0], "7z");
    assert!(!got.iter().any(|a| a.starts_with("-p")), "an extract with -p reads an empty password: {:?}", got);
    assert!(extract_argv(&f, Path::new("/x/a.tar.gz"), Path::new("/out")).is_none(), "a tar never takes a password");
}

// A compress is the other way round: 7z reads one stdin line only when -p is bare on its argv.
#[test]
fn a_password_compress_argv_keeps_the_bare_prompt_flag() {
    let names = vec!["a.txt".to_string()];
    let got = compress_argv("7z", Path::new("/w/archive.7z"), Path::new("/src"), &names, false);
    assert!(got.iter().any(|a| a == "-p"), "a compress needs the bare prompt flag: {:?}", got);
    assert!(!got.iter().any(|a| a.starts_with("-p") && a != "-p"), "no value beside it: {:?}", got);
}

#[test]
fn header_encryption_is_a_flag_of_7z_alone() {
    let names = vec!["a.txt".to_string()];
    let on = compress_argv("7z", Path::new("/w/archive.7z"), Path::new("/src"), &names, true);
    assert!(on.iter().any(|a| a == "-mhe=on"), "{:?}", on);
    let off = compress_argv("7z", Path::new("/w/archive.7z"), Path::new("/src"), &names, false);
    assert!(!off.iter().any(|a| a == "-mhe=on"), "{:?}", off);
}

// AA3: zip's default ZipCrypto is broken, so a password zip is written with AES-256.
#[test]
fn a_password_zip_is_written_with_aes_256() {
    let names = vec!["a.txt".to_string()];
    let zip = compress_argv("zip", Path::new("/w/archive.zip"), Path::new("/src"), &names, true);
    assert!(zip.iter().any(|a| a == "-mem=AES256"), "a password zip needs AES-256: {:?}", zip);
    let seven = compress_argv("7z", Path::new("/w/archive.7z"), Path::new("/src"), &names, true);
    assert!(!seven.iter().any(|a| a == "-mem=AES256"), "7z is AES-256 already: {:?}", seven);
}

// S4: no message builder emits the secret; the markers are fixed codes and the refusal names sizes.
#[test]
fn no_message_builder_emits_the_secret() {
    let argv = compress_argv("7z", Path::new("/w/archive.7z"), Path::new("/src"), &["a.txt".to_string()], true);
    assert!(!argv.iter().any(|a| a.contains(CANARY)), "the secret rode argv: {:?}", argv);
    let done = crate::backend::archivereq::archivedone_line(7, false, true, WRONG_PASSWORD);
    assert!(!done.contains(CANARY), "the terminal line carried the secret: {}", done);
    let note = crate::backend::archivefree::refusal("backup.tar.zst", 3_400_000_000, 1_200_000_000, "home");
    assert!(!note.contains(CANARY), "the refusal carried the secret: {}", note);
}

// S2 over the six modules that build or spawn an archive argv (not the request layer or test files): none calls the env setter, and the jail sets two by flag.
#[test]
fn no_archive_argv_module_sets_a_child_environment_variable() {
    let needle = ".env".to_string() + "(";
    let modules = [
        ("archivepass.rs", include_str!("archivepass.rs")), ("archiveops.rs", include_str!("archiveops.rs")),
        ("archivework.rs", include_str!("archivework.rs")), ("archive.rs", include_str!("archive.rs")),
        ("jail.rs", include_str!("jail.rs")), ("sandbox.rs", include_str!("sandbox.rs")),
    ];
    for (name, source) in modules {
        assert!(!source.contains(&needle), "{} sets a child environment variable", name);
    }
    assert_eq!(include_str!("sandbox.rs").matches("\"--setenv\"").count(), 2, "the jail sets LC_ALL and MALLOC_ARENA_MAX only");
}

// AA1: exit 2 on a password run is a wrong password or damaged encrypted data, which 7z cannot tell apart.
#[test]
fn exit_two_on_a_password_run_is_a_wrong_password() {
    assert_eq!(extract_verdict(Some(2), true), Some(WRONG_PASSWORD));
    for code in [Some(1), Some(7), Some(255), None] {
        assert_eq!(extract_verdict(code, true), None, "code {:?} is the tool failing some other way", code);
    }
    assert_eq!(extract_verdict(Some(2), false), None, "exit 2 with no password is the tool's own error");
}

// AA2: a plain extract that still exits 255 met an encrypted archive; the words never matter.
#[test]
fn a_plain_extract_that_exits_255_is_encrypted() {
    assert_eq!(extract_verdict(Some(255), false), Some(ENCRYPTED));
    assert_eq!(extract_verdict(Some(255), true), None, "with a password given, 255 asks nothing new");
    assert_eq!(extract_verdict(Some(2), false), None);
}

#[test]
fn the_wire_markers_are_codes() {
    assert_eq!((ENCRYPTED, WRONG_PASSWORD), ("encrypted", "wrong-password"));
}

fn failed_write(_: &mut Child, _: &str) -> std::io::Result<()> {
    Err(std::io::ErrorKind::BrokenPipe.into())
}

// A shell stub through the production jail path, its stdin write failing as a child that left early makes it.
fn run_stub_unread(shell: &str) -> Result<Option<SevenFailure>, FleaError> {
    let d = TestDir::new("archpwunread");
    let mut work = Work::new(d.path(), "arc").expect("work dir");
    let inner = vec!["/usr/bin/sh".to_string(), "-c".to_string(), shell.to_string()];
    run_with("archive", inner, d.path(), &mut work, Some(CANARY), &AtomicBool::new(false), failed_write)
}

// AA7: a failed stdin write is no cancel; the child's own exit is the answer.
#[test]
fn a_failed_stdin_write_is_answered_by_the_childs_own_exit() {
    if crate::backend::sandboxprobe::skipped() { return; }
    let wrong = run_stub_unread("exit 2").expect("the run itself did not fail").expect("exit 2 is a failure");
    assert_eq!(extract_verdict(wrong.code, true), Some(WRONG_PASSWORD));
    let other = run_stub_unread("exit 3").expect("the run itself did not fail").expect("exit 3 is a failure");
    assert_eq!(other.code, Some(3));
    assert_eq!(other.message, "the archive tool exited with status 3", "the failure names the component");
    assert!(run_stub_unread("exit 0").expect("the run itself did not fail").is_none(), "a child that needed no password succeeded");
}

static STUBS: AtomicUsize = AtomicUsize::new(0);

// What a /proc scan saw of one process: its argv and whether its environment could be read.
struct Seen {
    cmdline: Vec<u8>,
    environ: std::io::Result<Vec<u8>>,
}

// Every process whose argv carries the marker, host side: the jail's pid namespace still shows in /proc.
fn procs_with(marker: &str) -> Vec<Seen> {
    let found = std::fs::read_dir("/proc").expect("/proc").flatten().filter_map(|entry| {
        let cmdline = std::fs::read(entry.path().join("cmdline")).ok()?;
        if !cmdline.windows(marker.len()).any(|w| w == marker.as_bytes()) {
            return None;
        }
        Some(Seen { cmdline, environ: std::fs::read(entry.path().join("environ")) })
    });
    found.collect()
}

fn holds(bytes: &[u8], needle: &str) -> bool {
    bytes.windows(needle.len()).any(|w| w == needle.as_bytes())
}

fn mkfifo(path: &Path) {
    assert!(std::process::Command::new("mkfifo").arg(path).status().expect("mkfifo").success());
}

// A stub that reads its secret, waits for stdin's EOF, reports what it read, then waits to be released.
struct Stub {
    dir: TestDir,
    work: Work,
    nonce: String,
    ready: PathBuf,
    release: PathBuf,
}

impl Stub {
    fn new(tag: &str) -> Stub {
        let dir = TestDir::new(tag);
        let work = Work::new(dir.path(), "arc").expect("work dir");
        let (ready, release) = (work.dir.join("ready"), work.dir.join("release"));
        mkfifo(&ready);
        mkfifo(&release);
        let nonce = format!("f039-stub-{}-{}", std::process::id(), STUBS.fetch_add(1, Ordering::SeqCst));
        Stub { dir, work, nonce, ready, release }
    }

    fn inner(&self) -> Vec<String> {
        let script = format!(": {}; read pw; cat > /dev/null; echo \"$pw\" > '{}'; cat < '{}' > /dev/null",
                             self.nonce, self.ready.display(), self.release.display());
        vec!["/usr/bin/sh".to_string(), "-c".to_string(), script]
    }

    // Blocks on the stub's own report, then runs `during` with the stub alive; `release` lets it finish at once.
    fn observer(&self, tx: Sender<(String, Vec<Seen>)>, release: bool, during: impl FnOnce() + Send + 'static) -> std::thread::JoinHandle<()> {
        let (ready, release, nonce, release_now) = (self.ready.clone(), self.release.clone(), self.nonce.clone(), release);
        std::thread::spawn(move || {
            let mut said = String::new();
            std::fs::File::open(&ready).and_then(|mut f| f.read_to_string(&mut said)).ok();
            tx.send((said.trim().to_string(), procs_with(&nonce))).ok();
            during();
            // Opening the release pipe for writing and dropping it is what lets the stub finish.
            if release_now { std::fs::OpenOptions::new().write(true).open(&release).ok(); }
        })
    }

    // Lets a stub nobody released finish, without blocking when it is already dead.
    fn release(&self) {
        use std::os::unix::fs::OpenOptionsExt;
        std::fs::OpenOptions::new().write(true).custom_flags(0o4000).open(&self.release).ok();
    }
}

// S1 and S2, live: the production runner's child gets the secret on stdin and nowhere in its argv or environment.
#[test]
fn the_child_cmdline_cannot_carry_the_secret() {
    if crate::backend::sandboxprobe::skipped() { return; }
    let mut stub = Stub::new("archpwlive");
    let (tx, rx) = channel();
    let observer = stub.observer(tx, true, || {});
    let inner = stub.inner();
    let result = run_boxed_cancellable_pw("archive", inner, stub.dir.path(), &mut stub.work, Some(CANARY), &AtomicBool::new(false));
    let (said, seen) = rx.recv_timeout(REPORT_BOUND).expect("the stub never reported, so nothing was proved");
    observer.join().expect("observer");
    assert!(matches!(result, Ok(None)), "the stub exits 0 once released");
    assert_eq!(said, CANARY, "the secret reached the child's stdin, so the scan below had something to find");
    assert!(!seen.is_empty(), "the scan found no live child at all");
    for one in &seen {
        assert!(!holds(&one.cmdline, CANARY), "the secret sat in a child's cmdline");
        let environ = one.environ.as_ref().expect("a child's environment must be readable, or this proves nothing");
        assert!(!holds(environ, CANARY), "the secret sat in a child's environment");
    }
}

// The control for the test above: the scan does see a marker, a secret and an environment when they are there.
#[test]
fn the_proc_scan_sees_a_secret_that_is_in_argv() {
    use std::io::BufRead;
    let marker = format!("f039-control-{}-{}", std::process::id(), STUBS.fetch_add(1, Ordering::SeqCst));
    let mut child = std::process::Command::new("/usr/bin/sh")
        .args(["-c", &format!(": {} control-secret-1006; echo up; cat", marker)])
        .stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().expect("sh");
    let mut up = String::new();
    std::io::BufReader::new(child.stdout.take().unwrap()).read_line(&mut up).expect("the control child reports");
    let seen = procs_with(&marker);
    drop(child.stdin.take());
    child.wait().ok();
    assert!(seen.iter().any(|one| holds(&one.cmdline, "control-secret-1006")), "the scan cannot see a cmdline");
    assert!(seen.iter().all(|one| one.environ.is_ok()), "the scan cannot read an environment");
}

// AT10: a cancel with a live secret closes stdin, kills the child and reaps it.
#[test]
fn a_cancel_with_a_password_closes_stdin_and_reaps_the_child() {
    if crate::backend::sandboxprobe::skipped() { return; }
    let mut stub = Stub::new("archpwcancel");
    let cancel = Arc::new(AtomicBool::new(false));
    let flag = Arc::clone(&cancel);
    let (tx, rx) = channel();
    let observer = stub.observer(tx, false, move || flag.store(true, Ordering::Relaxed));
    let inner = stub.inner();
    let err = run_boxed_cancellable_pw("archive", inner, stub.dir.path(), &mut stub.work, Some(CANARY), &cancel).unwrap_err();
    let alive = procs_with(&stub.nonce);
    stub.release();
    let (said, _) = rx.recv_timeout(REPORT_BOUND).expect("the stub never reported");
    observer.join().expect("observer");
    assert_eq!(said, CANARY, "stdin carried the secret and then closed before the cancel landed");
    assert_eq!(err.msg, "cancelled");
    assert!(alive.is_empty(), "a cancelled child was left running");
}

// AT10: past the drain bound the answer names the kept folder, and the child is reaped all the same.
#[test]
fn a_cancel_past_the_drain_bound_with_a_password_still_reaps_the_child() {
    if crate::backend::sandboxprobe::skipped() { return; }
    let mut stub = Stub::new("archpwdrain");
    let cancel = Arc::new(AtomicBool::new(false));
    let flag = Arc::clone(&cancel);
    let (tx, rx) = channel();
    let observer = stub.observer(tx, false, move || flag.store(true, Ordering::Relaxed));
    let inner = stub.inner();
    let name = stub.work.dir.file_name().unwrap().to_string_lossy().to_string();
    set_reader_hold_ms(2000);
    set_drain_secs(0);
    let err = run_boxed_cancellable_pw("archive", inner, stub.dir.path(), &mut stub.work, Some(CANARY), &cancel).unwrap_err();
    set_reader_hold_ms(0);
    set_drain_secs(CANCEL_DRAIN_SECS);
    let alive = procs_with(&stub.nonce);
    stub.release();
    let (said, _) = rx.recv_timeout(REPORT_BOUND).expect("the stub never reported");
    observer.join().expect("observer");
    assert_eq!(said, CANARY);
    assert_eq!(err.msg, format!("cancelled; the archive tool did not exit, so its work folder {name} was left in place"));
    assert!(alive.is_empty(), "the child outlived a cancel past the drain bound");
}

// AB4: the terminal line of a password code names its archive and destination, so a card opens for its own job.
#[test]
fn a_password_code_line_names_the_archive_and_destination_to_retry() {
    let line = asks_again_line(5, ENCRYPTED, Path::new("/d/backup.7z"), Path::new("/d/backup"));
    assert_eq!(crate::json::field_str(&line, "err").as_deref(), Some("encrypted"));
    assert_eq!(crate::json::field_str(&line, "path").as_deref(), Some("/d/backup.7z"));
    assert_eq!(crate::json::field_str(&line, "dest").as_deref(), Some("/d/backup"));
    assert_eq!(crate::json::field_usize(&line, "id"), Some(5));
    assert!(!line.contains(CANARY));
    assert!(asks_again(ENCRYPTED) && asks_again(WRONG_PASSWORD) && !asks_again("cancelled"));
}
