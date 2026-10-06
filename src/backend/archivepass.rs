// A 7z password travels on stdin, never in argv: the argv carries a bare `-p` prompt flag and
// the secret is written to the child's stdin pipe. Reading it back out of /proc/<pid>/cmdline must
// find nothing, because argv is world-readable and the password prompt is the tool's own channel.
use crate::backend::archive::Formats;
use crate::backend::archivelist::{parse_reader, Contents};
use crate::backend::sandbox;
use std::io::Write;
use std::path::Path;
use std::process::{Child, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

// The marker the backend answers when an archive needs a password the request did not carry.
pub const ENCRYPTED: &str = "encrypted";
// The marker the backend answers when the password did not open the archive. A code, never a
// sentence: the card words it, so no client parses a message.
pub const WRONG_PASSWORD: &str = "wrong-password";
// 7z exit codes: 0 is success, 1 a warning, 2 a fatal error, 7 a command line error, 8 too little
// memory, 255 user stopped. A wrong password is a fatal error, so the verdict reads the code and
// never the tool's text, which a localized build words its own way (S8).
const WRONG_PASSWORD_CODE: i32 = 2;
// 7z's own prompt flag: bare, so the tool reads the secret off stdin rather than off argv.
const PASSWORD_PROMPT: &str = "-p";
// 7z's header-encryption flag, which is what hides the entry names of a password archive.
const HEADER_ENCRYPTION: &str = "-mhe=on";

// The prompt flag beside a 7z argv, slotted after the subcommand where 7z reads its switches.
// No value ever rides beside it: `-ps3cret` on argv is the defect this exists to prevent, and the
// secret reaches the child only through answer_prompt below.
pub fn seven_with_password(mut argv: Vec<String>, encrypt_names: bool) -> Vec<String> {
    let at = if argv.len() >= 2 { 2 } else { argv.len() };
    argv.insert(at, PASSWORD_PROMPT.to_string());
    if encrypt_names {
        argv.insert(at + 1, HEADER_ENCRYPTION.to_string());
    }
    argv
}

// Sample stderr: "Enter password (will not be echoed): ", which 7z prints when a listing meets an
// encrypted archive without a password on stdin to answer it.
pub fn looks_encrypted(stderr: &str, exited_ok: bool) -> bool {
    if exited_ok {
        return false;
    }
    let text = stderr.to_lowercase();
    text.contains("password") || text.contains("encrypted file")
}

// The verdict on a password run: exit code 2 is a wrong password whatever words came with it,
// any other code is the tool failing some other way. The tool's text is never read (S8).
pub fn is_wrong_password(code: Option<i32>) -> bool {
    code == Some(WRONG_PASSWORD_CODE)
}

// Whether the archive asks for a password: a 7z listing with stdin closed, whose stderr is the
// whole verdict. None when no tool reads the archive or the jail cannot run, so the caller treats
// an unprovable archive as unencrypted rather than refusing it. The probe runs in the readonly
// jail beside every other archive index read, with nothing writable.
pub fn password_needed(archive: &Path, formats: &Formats) -> Option<bool> {
    let (inner, _) = formats.list_argv(archive)?;
    if !sandbox::available() {
        return None;
    }
    let mut full = sandbox::wrap_readonly(&inner, archive);
    sandbox::add_status(&mut full, inner.len());
    let mut jailed = crate::backend::jail::spawn_jailed(&full, |cmd| {
        cmd.stdin(Stdio::null());
        cmd.stdout(Stdio::null());
        cmd.stderr(Stdio::piped());
    })
    .ok()?;
    // Bounded like the unpacked probe below: stderr is read only after the exit, so a tool that
    // floods it past the pipe buffer blocks until this deadline kills it rather than forever.
    let deadline = Instant::now() + Duration::from_millis(crate::backend::archivelist::ARCHIVE_READ_MS);
    loop {
        match jailed.child.try_wait() {
            Ok(Some(status)) => {
                let mut text = String::new();
                if let Some(mut err) = jailed.child.stderr.take() {
                    use std::io::Read;
                    err.read_to_string(&mut text).ok();
                }
                return Some(looks_encrypted(&text, status.success()));
            }
            Ok(None) if Instant::now() >= deadline => {
                crate::backend::jail::kill_tree(&mut jailed);
                return None;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(50)),
            Err(_) => {
                crate::backend::jail::kill_tree(&mut jailed);
                return None;
            }
        }
    }
}

// How many bytes the archive would unpack to, read off its own index without extracting a byte of
// it. None when the index cannot be read, which is also when the free-space check must not refuse.
// The index streams through the readonly jail under the same read bound the extract's own
// verification keeps, so a hostile listing cannot hold the worker past it.
pub fn unpacked_bytes(archive: &Path, formats: &Formats, cancel: &AtomicBool) -> Option<u64> {
    let (inner, spec) = formats.list_argv(archive)?;
    if !sandbox::available() {
        return None;
    }
    let mut full = sandbox::wrap_readonly(&inner, archive);
    sandbox::add_status(&mut full, inner.len());
    let mut jailed = crate::backend::jail::spawn_jailed(&full, |cmd| {
        cmd.stdin(Stdio::null());
        cmd.stdout(Stdio::piped());
        cmd.stderr(Stdio::null());
    })
    .ok()?;
    let deadline = Instant::now() + Duration::from_millis(crate::backend::archivelist::ARCHIVE_READ_MS);
    let output = match jailed.child.stdout.take() {
        Some(output) => output,
        None => {
            crate::backend::jail::kill_tree(&mut jailed);
            return None;
        }
    };
    let parser = std::thread::spawn(move || {
        parse_reader(std::io::BufReader::new(output), &spec)
    });
    loop {
        if cancel.load(Ordering::Relaxed) {
            crate::backend::jail::kill_tree(&mut jailed);
            return None;
        }
        match jailed.child.try_wait() {
            Ok(Some(status)) => {
                let listed: Contents = match parser.join() {
                    Ok(listed) => listed,
                    Err(_) => return None,
                };
                if cancel.load(Ordering::Relaxed) || !status.success() || listed.failed {
                    return None;
                }
                return Some(listed.unpacked);
            }
            Ok(None) if Instant::now() >= deadline => {
                crate::backend::jail::kill_tree(&mut jailed);
                return None;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(50)),
            Err(_) => {
                crate::backend::jail::kill_tree(&mut jailed);
                return None;
            }
        }
    }
}

// The secret on its way to a child's stdin, terminated the way an answered prompt is.
fn password_line(secret: &str) -> Vec<u8> {
    let mut line = secret.as_bytes().to_vec();
    line.push(b'\n');
    line
}

// A spawn with stdin piped, the only shape a password job may take: with stdin nulled there is
// nowhere to write the secret but argv. The runners above own production's spawns; this one exists
// for the cmdline test that proves the channel.
#[cfg(test)]
pub fn piped_spawn(argv: &[String]) -> std::io::Result<Child> {
    std::process::Command::new(&argv[0]).args(&argv[1..]).stdin(Stdio::piped()).spawn()
}

// Answers the child's password prompt and closes stdin, keeping the child for the caller to wait
// on or cancel; dropping the pipe without answering would leave 7z waiting on it.
pub fn answer_prompt(child: &mut Child, secret: &str) -> std::io::Result<()> {
    if let Some(stdin) = child.stdin.take() {
        let mut stdin = stdin;
        stdin.write_all(&password_line(secret))?;
    }
    Ok(())
}

// What a failed password run carries: the exit code the verdict reads and the tool's own last
// stderr line, which only a non-password failure may quote.
pub struct PwFailure {
    pub code: Option<i32>,
    pub tail: String,
}
// run_boxed_cancellable with a secret: the prompt flags ride the jailed argv and the password
// rides stdin. Kill and reap on cancel, so nothing is renamed and the prompt pipe dies with the
// child. Ok(None) is a clean exit; Ok(Some) is the failure the caller verdicts by exit code;
// Err is a spawn or sandbox failure, never a verdict. Stdout is discarded and only the last
// stderr line can become an error, the same contract archivework's cancellable runner keeps for
// every other tool here. The job runs in the archive jail, uncapped like every other archive job,
// never in the decoder's capped jail.
pub fn run_boxed_cancellable_pw(
    what: &str,
    inner: Vec<String>,
    read_only: &Path,
    work: &mut crate::backend::archivework::Work,
    secret: &str,
    cancel: &AtomicBool,
) -> Result<Option<PwFailure>, crate::error::FleaError> {
    use crate::backend::opsreq::op_err;
    use crate::error::from_io;
    if !sandbox::available() {
        let tool = inner.first().map_or("", |s| s.as_str());
        return Err(op_err(what, tool, "the sandbox is unavailable: bwrap or prlimit is not on PATH"));
    }
    let mut full = sandbox::wrap_archive(&inner, read_only, &work.dir);
    sandbox::add_status(&mut full, inner.len());
    let mut jailed = crate::backend::jail::spawn_jailed(&full, |cmd| {
        cmd.stdin(Stdio::piped());
        cmd.stdout(Stdio::null());
        cmd.stderr(Stdio::piped());
    })
    .map_err(|e| from_io(what, &full[0], &e))?;
    if answer_prompt(&mut jailed.child, secret).is_err() {
        crate::backend::jail::kill_tree(&mut jailed);
        return Err(op_err(what, "", "cancelled"));
    }
    let stderr = jailed.child.stderr.take();
    let reader = std::thread::spawn(move || {
        let mut text = String::new();
        if let Some(mut pipe) = stderr {
            use std::io::Read;
            pipe.read_to_string(&mut text).ok();
        }
        text
    });
    loop {
        if cancel.load(Ordering::Relaxed) {
            crate::backend::jail::kill_tree(&mut jailed);
            reader.join().ok();
            return Err(op_err(what, "", "cancelled"));
        }
        match jailed.child.try_wait() {
            Ok(Some(status)) => {
                let text = reader.join().unwrap_or_default();
                if status.success() {
                    return Ok(None);
                }
                let tail = text.lines().last().unwrap_or("").to_string();
                return Ok(Some(PwFailure { code: status.code(), tail }));
            }
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(50)),
            Err(e) => {
                crate::backend::jail::kill_tree(&mut jailed);
                reader.join().ok();
                return Err(from_io(what, &full[0], &e));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // The password is a prompt flag on argv, never a value beside one: argv is world-readable
    // through /proc/<pid>/cmdline, so `-ps3cret` there is the defect and bare `-p` is the fix.
    #[test]
    fn a_password_reaches_7z_as_a_prompt_flag_and_never_as_a_value() {
        let base = vec!["7z".to_string(), "a".to_string(), "-bd".to_string()];
        let got = seven_with_password(base, false);
        assert!(got.iter().any(|a| a == "-p"), "the prompt flag is what asks 7z to read stdin: {:?}", got);
        assert!(!got.iter().any(|a| a.starts_with("-p") && a != "-p"),
                "no value may ride beside the flag: {:?}", got);
    }

    #[test]
    fn header_encryption_is_a_flag_beside_the_prompt() {
        let base = vec!["7z".to_string(), "a".to_string()];
        let on = seven_with_password(base.clone(), true);
        assert!(on.iter().any(|a| a == "-mhe=on"), "encrypting names is its own flag: {:?}", on);
        let off = seven_with_password(base, false);
        assert!(!off.iter().any(|a| a == "-mhe=on"), "and it is absent when names stay open: {:?}", off);
    }

    // S4: no message builder emits the secret. The argv carries a bare prompt flag, the wire
    // markers are fixed codes, and the refusal names sizes, never the secret that was typed.
    #[test]
    fn no_message_builder_emits_the_secret() {
        let secret = "S3cr3t-canary-1006";
        let argv = seven_with_password(vec!["7z".to_string(), "a".to_string()], true);
        assert!(!argv.iter().any(|a| a.contains(secret)),
            "the secret rode argv: {:?}", argv);
        assert_eq!(ENCRYPTED, "encrypted");
        assert_eq!(WRONG_PASSWORD, "wrong-password");
        let done = crate::backend::archivereq::archivedone_line(7, false, true, WRONG_PASSWORD);
        assert!(!done.contains(secret), "the terminal line carried the secret: {}", done);
        let note = crate::backend::archivefree::refusal("backup.tar.zst", 3_400_000_000, 1_200_000_000, "home", "btrfs");
        assert!(!note.contains(secret), "the refusal carried the secret: {}", note);
    }

    // S2: the secret never reaches the environment. Both live children are scanned: the piped
    // stand-in and a jailed spawn built the way production builds its password children.
    #[test]
    fn no_spawned_child_carries_the_secret_in_its_environment() {
        let secret = "S3cr3t-canary-1006";
        let mut child = piped_spawn(&["/usr/bin/sleep".to_string(), "30".to_string()])
            .expect("sleep must spawn");
        answer_prompt(&mut child, secret).expect("stdin must take the secret");
        assert_child_environ_clean(&child, secret);
        child.kill().ok();
        child.wait().ok();
        let full = vec!["/usr/bin/sleep".to_string(), "30".to_string()];
        let mut jailed = crate::backend::jail::spawn_jailed(&full, |cmd| {
            cmd.stdin(std::process::Stdio::piped());
        })
        .expect("jailed sleep must spawn");
        answer_prompt(&mut jailed.child, secret).expect("stdin must take the secret");
        assert_child_environ_clean(&jailed.child, secret);
        crate::backend::jail::kill_tree(&mut jailed);
    }

    fn assert_child_environ_clean(child: &Child, secret: &str) {
        let env = std::fs::read(format!("/proc/{}/environ", child.id())).unwrap_or_default();
        let text = String::from_utf8_lossy(&env);
        assert!(!text.contains(secret), "the secret rode the child's environment");
    }

    // S2, statically: no spawn in this module sets an environment variable, so a future
    // environment-setting spawn fails here rather than shipping a secret beside the process.
    // The needle is built at runtime because naming it literally would trip the check itself.
    #[test]
    fn no_archive_spawn_sets_an_environment_variable() {
        let needle = ".env".to_string() + "(";
        let source = include_str!("archivepass.rs");
        assert!(!source.contains(&needle), "an environment-setting spawn reached the password module");
    }

    // 7z names the password on stderr either way; a corrupt archive never does.
    #[test]
    fn an_encrypted_listing_is_told_from_a_corrupt_one() {
        assert!(looks_encrypted("Enter password (will not be echoed): ", false));
        assert!(looks_encrypted("ERROR: Data Error in encrypted file. Wrong password? : x.7z", false));
        assert!(!looks_encrypted("Can not open the file as archive", false));
        assert!(!looks_encrypted("", true), "a clean exit is never encrypted, whatever stderr held");
    }

    // S8: the verdict reads the exit code, never the tool's text. Each case names the stderr its
    // code arrived with; the verdict does not take it, so a localized build answers the same way.
    #[test]
    fn a_wrong_password_is_told_by_its_exit_code_in_any_language() {
        let cases = [
            (Some(2), "ERROR: Wrong password : backup.7z", true),
            (Some(2), "ERROR: Contraseña incorrecta : backup.7z", true),
            (Some(2), "", true),
            (Some(1), "ERROR: Wrong password : backup.7z", false),
            (Some(7), "wrong password", false),
            (None, "killed by signal", false),
        ];
        for (code, _stderr, want) in cases {
            assert_eq!(is_wrong_password(code), want, "code {:?} mistold", code);
        }
    }

    #[test]
    fn the_wrong_password_wire_marker_is_a_code() {
        assert_eq!(WRONG_PASSWORD, "wrong-password");
    }

    // The live half: a real child, its real cmdline, read while it runs. The secret goes to
    // stdin the way production sends a password, and /proc/<pid>/cmdline must not contain it.
    // /usr/bin/sleep stands in for 7z, which this host has no copy of; what is proved is the
    // channel, argv versus stdin, and not the tool. The stand-in takes no extra argv words: a
    // word sleep rejects exits at once and wins a scheduling race against the write below, which
    // failed this test with a broken pipe under load. The prompt-flag shape of a production argv
    // is pinned by the pure tests above, not by this spawn.
    #[test]
    fn the_child_cmdline_cannot_carry_the_secret() {
        let secret = "s3cret-live-proof";
        let argv = vec!["/usr/bin/sleep".to_string(), "30".to_string()];
        let mut child = piped_spawn(&argv).expect("sleep must spawn");
        answer_prompt(&mut child, secret).expect("stdin must take the secret");
        // Under a parallel suite the child may need a scheduler turn before exec; an empty
        // cmdline names a child that never arrived, not one that carried the secret, so the
        // read waits for arrival and the liveness check below tells a murdered child apart.
        let mut text = String::new();
        for _ in 0..200 {
            text = String::from_utf8_lossy(&std::fs::read(format!("/proc/{}/cmdline", child.id()))
                .unwrap_or_default()).to_string();
            if !text.is_empty() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let status = child.try_wait().expect("wait on probe child");
        child.kill().ok();
        child.wait().ok();
        assert!(status.is_none(), "the probe child died before its cmdline was read: {:?}", text);
        assert!(text.contains("sleep"), "the probe read no live child at all: {:?}", text);
        assert!(!text.contains(secret), "the secret sat in the child's cmdline: {:?}", text);
    }
}
