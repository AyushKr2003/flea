// The sandboxed producer behind a piped flash: one argv per kind, the image as its stdin.
use crate::backend::flashwrite::Fail;
use std::os::raw::c_int;

extern "C" {
    fn lseek(fd: c_int, offset: i64, whence: c_int) -> i64;
}
// lseek whence: SEEK_CUR reads the shared offset without moving it.
const SEEK_CUR: c_int = 1;

// A test build's stand-in decompressor argv, set per thread like opsreq's CANCEL_AT.
#[cfg(test)]
thread_local! {
    static TEST_DECOMPRESSOR: std::cell::RefCell<Option<Vec<String>>> = const { std::cell::RefCell::new(None) };
}
#[cfg(test)]
pub(crate) fn test_set_decompressor(argv: Option<Vec<String>>) {
    TEST_DECOMPRESSOR.with(|v| *v.borrow_mut() = argv);
}

// The decompressor argv for a kind; raw images are read by Flea directly and need none.
fn decompressor_argv(kind: &str, image: &std::path::Path, member: &str) -> Option<Vec<String>> {
    match kind {
        "xz" => Some(vec!["xz".to_string(), "-dc".to_string(), "-T4".to_string()]),
        "zst" => Some(vec!["zstd".to_string(), "-dc".to_string()]),
        "gz" => Some(vec!["gzip".to_string(), "-dc".to_string()]),
        "bz2" => Some(vec!["bzip2".to_string(), "-dc".to_string()]),
        "zip" => Some(vec!["bsdtar".to_string(), "-xOf".to_string(), image.to_string_lossy().to_string(), member.to_string()]),
        _ => None,
    }
}

// The streaming decompressor jail: the same boundary with no user path bound at all, for a
// flasher pipeline whose image arrives as stdin and whose bytes leave as stdout; see TECH.md 8.
pub fn wrap_stream(inner: &[String]) -> Vec<String> {
    use crate::backend::sandbox::{ADDRESS_SPACE_BYTES, BWRAP, BWRAP_FLAGS, PRLIMIT};
    let mut a: Vec<String> = Vec::with_capacity(inner.len() + BWRAP_FLAGS.len() + 3);
    // prlimit stays outermost so the address-space cap still arrives, without the decoder's CPU cap.
    a.push(PRLIMIT.to_string());
    a.push(format!("--as={}", ADDRESS_SPACE_BYTES));
    a.push(BWRAP.to_string());
    for flag in BWRAP_FLAGS {
        a.push(flag.to_string());
    }
    a.extend_from_slice(inner);
    a
}

// Starts the sandboxed producer with the image as stdin; a zip is bound read-only instead of piped.
pub(crate) fn spawn_producer(kind: &str, image: &std::path::Path, member: &str) -> Result<(std::process::Child, Option<std::fs::File>), Fail> {
    #[cfg(test)]
    {
        if let Some(argv) = TEST_DECOMPRESSOR.with(|v| v.borrow().clone()) {
            let child = std::process::Command::new(&argv[0]).args(&argv[1..])
                .stdin(std::process::Stdio::null()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::null())
                .spawn().map_err(|e| Fail::Decompress(e.to_string()))?;
            return Ok((child, None));
        }
    }
    if !crate::backend::sandbox::available() {
        return Err(Fail::Sandbox);
    }
    let Some(inner) = decompressor_argv(kind, image, member) else { return Err(Fail::Decompress("no producer for a raw image".to_string())) };
    let full = if kind == "zip" {
        crate::backend::sandbox::wrap_readonly(&inner, image)
    } else {
        crate::backend::sandbox::wrap_stream(&inner)
    };
    // The parent keeps its own handle on the same description the child reads, so lseek reads
    // the consumed input offset without moving it; that offset drives the unknown-size bar.
    let input = if kind == "zip" { None } else { std::fs::File::open(image).ok() };
    let stdin = match input.as_ref().and_then(|f| f.try_clone().ok()) {
        Some(dup) => std::process::Stdio::from(dup),
        None => std::process::Stdio::null(),
    };
    let mut jailed = crate::backend::jail::spawn_jailed(&full, |cmd| {
        cmd.stdin(stdin);
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::null());
    }).map_err(|e| Fail::Decompress(e.to_string()))?;
    jailed.child.stdout.take();
    Ok((jailed.child, input))
}

// The consumed input offset over the shared description the producer reads; written stands in
// for it on the raw path and where no handle was kept, which is what makes unknown totals safe.
pub(crate) fn input_offset(input: Option<&std::fs::File>, written: u64) -> u64 {
    use std::os::fd::AsRawFd;
    match input {
        Some(file) => {
            let at = unsafe { lseek(file.as_raw_fd(), 0, SEEK_CUR) };
            if at < 0 { written } else { at as u64 }
        }
        None => written,
    }
}

pub(crate) fn try_kill(child: &mut std::process::Child) {
    let _ = child.kill();
}

#[cfg(test)]
mod tests {
    // TECH.md section 8: the flasher's decompressor jail streams on stdio and binds no user path.
    #[test]
    fn the_stream_jail_binds_no_user_path_and_carries_no_cpu_cap() {
        let inner = vec!["xz".to_string(), "-dc".to_string()];
        let got = super::wrap_stream(&inner);
        assert_eq!(got[0], "prlimit");
        assert!(got.iter().any(|a| a == "--as=2147483648"), "the stream jail keeps the 2 GiB cap: {:?}", got);
        assert!(!got.iter().any(|a| a.starts_with("--cpu=")), "a stream lasts as long as the image: {:?}", got);
        let tail = &got[got.len() - inner.len()..];
        assert_eq!(tail, inner.as_slice(), "the inner argv is still last and unchanged");
        let joined = got.join(" ");
        assert!(joined.contains("--ro-bind /usr /usr"), "system paths stay read-only: {}", joined);
        assert!(!joined.contains("--ro-bind /in"), "no user path is bound: {}", joined);
        assert!(!joined.contains("--bind "), "nothing is writable: {}", joined);
        assert!(got.iter().any(|a| a == "--unshare-all"), "the namespace flags are unchanged: {:?}", got);
    }
}
