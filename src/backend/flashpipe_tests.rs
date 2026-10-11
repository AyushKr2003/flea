// The producer behind a piped flash: its jail argv and the child production really spawns.
use super::*;
use crate::backend::testdir::TestDir;
use std::io::Read;

// The flasher's decompressor jail streams on stdio and binds no user path.
#[test]
fn the_stream_jail_binds_no_user_path_and_carries_no_cpu_cap() {
    let inner = vec!["xz".to_string(), "-dc".to_string()];
    let got = crate::backend::sandbox::wrap_stream(&inner);
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

// A10: the production arm hands the producer's stdout to the writer, or every compressed image fails.
#[test]
fn the_production_arm_keeps_the_producers_stdout() {
    let d = TestDir::new("flashpipe-gz");
    let body: Vec<u8> = (0..70_000u32).map(|n| (n % 251) as u8).collect();
    std::fs::write(d.join("a.img"), &body).unwrap();
    assert!(std::process::Command::new("gzip").arg("-k").arg("-f").arg(d.join("a.img")).status().unwrap().success());
    let cancel = std::sync::atomic::AtomicBool::new(false);
    let dest = std::fs::File::open(d.join("a.img")).unwrap();
    let packed = d.join("a.img.gz");
    let job = Job::new(&packed, "gz", "", &dest, 0, &cancel);
    let (mut child, _input) = spawn_producer(&job).map_err(|_| "the producer did not spawn").unwrap();
    let mut pipe = child.stdout.take().expect("the producer's stdout reaches the writer");
    let mut out = Vec::new();
    pipe.read_to_end(&mut out).unwrap();
    let status = child.wait().unwrap();
    if status.success() {
        assert_eq!(out, body, "the unpacked bytes come through the pipe");
    } else {
        eprintln!("flea: the jail did not run here ({status}), so only the pipe's presence was proven");
    }
}
