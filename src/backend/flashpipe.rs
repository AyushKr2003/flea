// The sandboxed producer behind a piped flash: one argv per kind, the image as its stdin.
use crate::backend::flashwrite::{Fail, Job};
use std::os::raw::c_int;

extern "C" {
    fn lseek(fd: c_int, offset: i64, whence: c_int) -> i64;
}
// lseek whence: SEEK_CUR reads the shared offset without moving it.
const SEEK_CUR: c_int = 1;

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

// The streaming decompressor jail: the same boundary with no user path bound, the image on stdin and the bytes on stdout.
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
pub(crate) fn spawn_producer(job: &Job) -> Result<(std::process::Child, Option<std::fs::File>), Fail> {
    let (kind, image, member) = (job.kind, job.image, job.member);
    #[cfg(test)]
    {
        if let Some(argv) = job.decompressor.as_ref() {
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
    // The parent keeps a handle on the child's description, so lseek reads the consumed input offset without moving it.
    let input = if kind == "zip" { None } else { std::fs::File::open(image).ok() };
    let stdin = match input.as_ref().and_then(|f| f.try_clone().ok()) {
        Some(dup) => std::process::Stdio::from(dup),
        None => std::process::Stdio::null(),
    };
    let jailed = crate::backend::jail::spawn_jailed(&full, |cmd| {
        cmd.stdin(stdin);
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::null());
    }).map_err(|e| Fail::Decompress(e.to_string()))?;
    Ok((jailed.child, input))
}

// The consumed input offset over the producer's shared description; written stands in where no handle was kept.
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
#[path = "flashpipe_tests.rs"]
mod tests;
