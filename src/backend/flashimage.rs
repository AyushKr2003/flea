// The image probe behind flashimage: kind from the name confirmed by magic, sizes in the sandbox.
use std::path::Path;
use std::time::Duration;

// The probe's own deadline, short: xz --list on a local file answers in milliseconds.
const PROBE_TIMEOUT: Duration = Duration::from_secs(10);
// 1 MiB of listing output, far past any header this probe reads.
const CAPTURE_CAP: usize = 1024 * 1024;
// ISO 9660's signature and where it sits.
const ISO_OFFSET: usize = 32769;
const ISO_MAGIC: &[u8] = b"CD001";
// Enough head to hold every magic below plus the ISO offset.
const HEAD_BYTES: usize = 32774;

pub struct Probe {
    pub kind: String,
    pub bytes: u64,
    pub unpacked: u64,
    pub known: bool,
    pub member: String,
}

// Sample name: "raspios-arm64.img.xz" answers xz when its head holds the xz magic too.
pub fn probe(path: &Path) -> Probe {
    let bytes = path.metadata().map(|m| m.len()).unwrap_or(0);
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_lowercase();
    let named = kind_of_name(&name);
    if named.is_empty() {
        return Probe { kind: String::new(), bytes, unpacked: 0, known: false, member: String::new() };
    }
    let head = read_head(path);
    if !magic_holds(named, &head) {
        return Probe { kind: String::new(), bytes, unpacked: 0, known: false, member: String::new() };
    }
    match named {
        "iso" | "img" => Probe { kind: named.to_string(), bytes, unpacked: bytes, known: true, member: String::new() },
        "gz" | "bz2" => Probe { kind: named.to_string(), bytes, unpacked: 0, known: false, member: String::new() },
        "xz" => {
            let (unpacked, known) = xz_size(path);
            Probe { kind: named.to_string(), bytes, unpacked, known, member: String::new() }
        }
        "zst" => {
            let (unpacked, known) = zstd_frame_size(&head);
            Probe { kind: named.to_string(), bytes, unpacked, known, member: String::new() }
        }
        "zip" => zip_probe(path, bytes),
        _ => Probe { kind: String::new(), bytes, unpacked: 0, known: false, member: String::new() },
    }
}

// The suffix alone, before magic confirms it; a name and magic that disagree refuse the row.
fn kind_of_name(name: &str) -> &str {
    if name.ends_with(".img.xz") {
        return "xz";
    }
    if name.ends_with(".img.gz") {
        return "gz";
    }
    if name.ends_with(".img.zst") {
        return "zst";
    }
    if name.ends_with(".img.bz2") {
        return "bz2";
    }
    if name.ends_with(".iso") {
        return "iso";
    }
    if name.ends_with(".img") || name.ends_with(".raw") {
        return "img";
    }
    if name.ends_with(".zip") {
        return "zip";
    }
    ""
}

// Sample head: FD 37 7A 58 5A 00 answers xz; PK 03 04 answers zip.
fn magic_holds(kind: &str, head: &[u8]) -> bool {
    match kind {
        "iso" => head.len() > ISO_OFFSET + 5 && &head[ISO_OFFSET..ISO_OFFSET + 5] == ISO_MAGIC,
        "img" => true,
        "xz" => head.starts_with(&[0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]),
        "gz" => head.starts_with(&[0x1F, 0x8B]),
        "zst" => head.starts_with(&[0x28, 0xB5, 0x2F, 0xFD]),
        "bz2" => head.starts_with(b"BZh"),
        "zip" => head.starts_with(&[0x50, 0x4B, 0x03, 0x04]),
        _ => false,
    }
}

fn read_head(path: &Path) -> Vec<u8> {
    use std::io::Read;
    let mut buf = vec![0u8; HEAD_BYTES];
    let Ok(mut file) = std::fs::File::open(path) else { return Vec::new(); };
    let mut got = 0;
    while got < HEAD_BYTES {
        match file.read(&mut buf[got..]) {
            Ok(0) => break,
            Ok(n) => got += n,
            Err(_) => break,
        }
    }
    buf.truncate(got);
    buf
}

// Sample robot line: "file\t1\t1\t100072\t100000\t..." answers 100000.
fn parse_xz_robot(text: &str) -> Option<u64> {
    for line in text.lines() {
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.first() == Some(&"file") && fields.len() > 4 {
            if let Ok(n) = fields[4].trim().parse::<u64>() {
                return Some(n);
            }
        }
    }
    None
}

// The zstd frame header's own content size, read as machine fields and never off the CLI's
// prose, per the translation ruling: magic, descriptor, window, dictionary id, then the size.
// A frame that records no size, and a concatenated file past its first frame, answer unknown.
fn zstd_frame_size(head: &[u8]) -> (u64, bool) {
    // Magic, descriptor, and room for the longest window plus dictionary id plus size fields.
    if head.len() < 6 || head[..4] != [0x28, 0xB5, 0x2F, 0xFD] {
        return (0, false);
    }
    let descriptor = head[4];
    let size_flag = descriptor >> 6;
    let single_segment = descriptor & 0x20 != 0;
    let dict_flag = descriptor & 0x03;
    let mut at = 5;
    if !single_segment {
        at += 1;
    }
    at += match dict_flag {
        0 => 0,
        1 => 1,
        2 => 2,
        _ => 4,
    };
    let (len, plus) = match size_flag {
        0 if single_segment => (1, 0),
        0 => return (0, false),
        1 => (2, 256),
        2 => (4, 0),
        _ => (8, 0),
    };
    if head.len() < at + len {
        return (0, false);
    }
    let mut raw: u64 = 0;
    for (i, byte) in head[at..at + len].iter().enumerate() {
        raw |= u64::from(*byte) << (8 * i);
    }
    (raw + plus, true)
}

fn xz_size(path: &Path) -> (u64, bool) {
    let inner = vec!["xz".to_string(), "--robot".to_string(), "--list".to_string(), path.to_string_lossy().to_string()];
    match capture(&crate::backend::sandbox::wrap_readonly(&inner, path)) {
        Some(text) => match parse_xz_robot(&text) {
            Some(n) => (n, true),
            None => (0, false),
        },
        None => (0, false),
    }
}

// A zip qualifies only with exactly one member, and that member an image by the same rules.
fn zip_probe(path: &Path, bytes: u64) -> Probe {
    let refused = Probe { kind: String::new(), bytes, unpacked: 0, known: false, member: String::new() };
    let inner = vec!["bsdtar".to_string(), "-tvf".to_string(), path.to_string_lossy().to_string()];
    let Some(text) = capture(&crate::backend::sandbox::wrap_readonly(&inner, path)) else { return refused; };
    let contents = crate::backend::archivelist::parse_reader(std::io::BufReader::new(text.as_bytes()), &crate::backend::archivespec::tar_spec());
    if contents.failed || contents.produced_entries != 1 || contents.names.len() != 1 {
        return refused;
    }
    let member = contents.names[0].name.clone();
    let lower = member.to_lowercase();
    let inner_kind = if lower.ends_with(".iso") { "iso" } else if lower.ends_with(".img") || lower.ends_with(".raw") { "img" } else { "" };
    if inner_kind.is_empty() {
        return refused;
    }
    if inner_kind == "iso" && !zip_member_is_iso(path, &member) {
        return refused;
    }
    Probe { kind: "zip".to_string(), bytes, unpacked: contents.unpacked, known: true, member }
}

// An .iso member earns its kind only when its head holds CD001, read through the member pipe.
fn zip_member_is_iso(path: &Path, member: &str) -> bool {
    let inner = vec!["bsdtar".to_string(), "-xOf".to_string(), path.to_string_lossy().to_string(), member.to_string()];
    let Some(head) = capture_head(&crate::backend::sandbox::wrap_readonly(&inner, path), HEAD_BYTES) else { return false; };
    head.len() > ISO_OFFSET + 5 && head[ISO_OFFSET..ISO_OFFSET + 5] == *ISO_MAGIC
}

// One sandboxed tool run with its stdout captured up to the cap; None never parsed as a size.
fn capture(argv: &[String]) -> Option<String> {
    capture_head(argv, CAPTURE_CAP).and_then(|bytes| String::from_utf8(bytes).ok())
}

fn capture_head(argv: &[String], cap: usize) -> Option<Vec<u8>> {
    if !crate::backend::sandbox::available() {
        return None;
    }
    let mut jailed = crate::backend::jail::spawn_jailed(argv, |cmd| {
        cmd.stdin(std::process::Stdio::null());
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::null());
    }).ok()?;
    let mut reader = jailed.child.stdout.take();
    let worker = std::thread::spawn(move || {
        let mut out = Vec::new();
        if let Some(pipe) = reader.as_mut() {
            use std::io::Read;
            let mut chunk = [0u8; 8192];
            while out.len() < cap {
                match pipe.read(&mut chunk) {
                    Ok(0) => break,
                    Ok(n) => out.extend_from_slice(&chunk[..n]),
                    Err(_) => break,
                }
            }
        }
        out
    });
    let deadline = std::time::Instant::now() + PROBE_TIMEOUT;
    loop {
        match jailed.child.try_wait() {
            Ok(Some(status)) => {
                let out = worker.join().unwrap_or_default();
                return status.success().then_some(out);
            }
            Ok(None) => {
                if std::time::Instant::now() >= deadline {
                    crate::backend::jail::kill_tree(&mut jailed);
                    let _ = worker.join();
                    return None;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(_) => {
                crate::backend::jail::kill_tree(&mut jailed);
                let _ = worker.join();
                return None;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::testdir::TestDir;

    #[test]
    fn a_name_without_an_image_suffix_has_no_kind() {
        assert_eq!(kind_of_name("notes.txt"), "");
        assert_eq!(kind_of_name("disk.iso.torrent"), "");
        assert_eq!(kind_of_name(&"DISK.ISO".to_lowercase()), "iso", "the probe lowercases before it matches");
        assert_eq!(kind_of_name("a.img.xz"), "xz");
        assert_eq!(kind_of_name("a.raw"), "img");
        assert_eq!(kind_of_name("a.zip"), "zip");
    }

    #[test]
    fn magic_that_disagrees_with_the_name_refuses_the_row() {
        assert!(!magic_holds("xz", b"not compressed at all"));
        assert!(magic_holds("xz", &[0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00, 0x01]));
        assert!(magic_holds("gz", &[0x1F, 0x8B, 0x08]));
        assert!(magic_holds("zst", &[0x28, 0xB5, 0x2F, 0xFD, 0x00]));
        assert!(magic_holds("bz2", b"BZh91AY&SY"));
        assert!(magic_holds("zip", &[0x50, 0x4B, 0x03, 0x04, 0x14]));
        assert!(magic_holds("img", b""));
    }

    #[test]
    fn the_frame_header_names_its_content_size_or_nothing() {
        // Descriptor 0x60: two-byte size, single segment; 49744 + 256 answers 50000.
        assert_eq!(zstd_frame_size(&[0x28, 0xB5, 0x2F, 0xFD, 0x60, 0x50, 0xC2]), (50000, true));
        // Descriptor 0xA0: four-byte size, single segment, answers 100000.
        assert_eq!(zstd_frame_size(&[0x28, 0xB5, 0x2F, 0xFD, 0xA0, 0xA0, 0x86, 0x01, 0x00]), (100000, true));
        // Descriptor 0x20: one-byte size, single segment with no dictionary, answers 100.
        assert_eq!(zstd_frame_size(&[0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x64]), (100, true));
        // Descriptor 0x00: no size recorded without single segment, so unknown, never zero.
        assert_eq!(zstd_frame_size(&[0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x00]), (0, false));
        assert_eq!(zstd_frame_size(&[0x28, 0xB5]), (0, false), "a short head is unknown, not a size");
        assert_eq!(zstd_frame_size(b"not a frame at all"), (0, false));
    }

    #[test]
    fn a_raw_image_probes_off_name_and_bytes_alone() {
        let d = TestDir::new("flashimage-raw");
        let path = d.join("plain.img");
        std::fs::write(&path, vec![7u8; 8192]).unwrap();
        let got = probe(&path);
        assert_eq!((got.kind.as_str(), got.bytes, got.unpacked, got.known), ("img", 8192, 8192, true));
    }

    #[test]
    fn a_renamed_text_file_is_not_a_disk_image() {
        let d = TestDir::new("flashimage-fake");
        let path = d.join("notes.img");
        std::fs::write(&path, b"just text").unwrap();
        let got = probe(&path);
        assert_eq!((got.kind.as_str(), got.bytes), ("img", 9), "a .img takes anything, so a text body still probes");
        let xz = d.join("notes.img.xz");
        std::fs::write(&xz, b"just text").unwrap();
        assert_eq!(probe(&xz).kind, "", "magic refusing a mismatched suffix is the whole rule");
    }

    #[test]
    fn a_gzip_image_probes_with_an_unknown_size() {
        let d = TestDir::new("flashimage-gz");
        let body: Vec<u8> = (0..5000u32).map(|n| (n % 251) as u8).collect();
        std::fs::write(d.join("a.img"), &body).unwrap();
        let status = std::process::Command::new("gzip").arg("-k").arg("-f").arg(d.join("a.img")).status().unwrap();
        assert!(status.success());
        let got = probe(&d.join("a.img.gz"));
        assert_eq!((got.kind.as_str(), got.known), ("gz", false));
        assert_eq!(got.bytes, d.join("a.img.gz").metadata().unwrap().len());
    }
}
