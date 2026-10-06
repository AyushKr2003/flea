// The flash dispatcher: one flash at a time beside transfers, the worker behind flashdone.
use crate::backend::flash::{flashdone_line, flashtargets_line, flashimage_line, flashprogress_line, flashstarted_line, permille, Drive, PROGRESS_EVERY_MS};
use crate::backend::flashslot::{FlashMsg, Slot};
use std::os::fd::AsRawFd;
use std::os::unix::fs::MetadataExt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

// The block ioctls layer 6 reads, measured against linux/fs.h on this box, in the tree's own
// variadic spelling; see src/backend/localsend.rs for the idiom this matches.
const BLKGETSIZE64: usize = 0x80081272;
const BLKGETDISKSEQ: usize = 0x80081280;
extern "C" {
    fn ioctl(fd: i32, request: usize, ...) -> i32;
}

// A full flash test's stand-in target, set per thread like the decompressor override.
#[cfg(test)]
thread_local! {
    static TEST_DIRECT_TARGET: std::cell::RefCell<Option<std::path::PathBuf>> = const { std::cell::RefCell::new(None) };
}
#[cfg(test)]
pub(crate) fn test_set_direct_target(path: Option<std::path::PathBuf>) {
    TEST_DIRECT_TARGET.with(|v| *v.borrow_mut() = path);
}

// Classifies one image and answers its flashimage line; a mismatch refuses the row with no kind.
pub fn handle_flashimage(out: &mut dyn std::io::Write, path: &str) {
    let probe = crate::backend::flashimage::probe(std::path::Path::new(path));
    let line = flashimage_line(path, &probe.kind, probe.bytes, probe.unpacked, probe.known, &probe.member);
    writeln!(out, "{line}").ok();
}

// Lists every eligible drive with the refusals the image causes, then drops the daemon's system disks.
pub fn handle_flashtargets(out: &mut dyn std::io::Write, image: &str) {
    let (exe, ui) = crate::backend::flasheligible::roots_for_production();
    let roots = crate::backend::flasheligible::Roots { sys: std::path::Path::new("/sys"), dev: std::path::Path::new("/dev"), exe: &exe, ui: &ui };
    let mountinfo = std::fs::read_to_string("/proc/self/mountinfo").unwrap_or_default();
    let swaps = std::fs::read_to_string("/proc/swaps").unwrap_or_default();
    let (image_path, image_bytes) = flash_measure(image);
    let drives = crate::backend::flasheligible::list_drives(&roots, &mountinfo, &swaps, image_path.as_deref(), image_bytes);
    let kept = crate::backend::flashhelper::surviving(&drives.iter().map(|d| d.dev.clone()).collect::<Vec<_>>());
    let drives: Vec<Drive> = drives.into_iter().filter(|d| kept.contains(&d.dev)).collect();
    writeln!(out, "{}", flashtargets_line(&drives)).ok();
    out.flush().ok();
}

// The unpacked size when the probe knows it, else the file bytes as the lower bound for small.
fn flash_measure(image: &str) -> (Option<std::path::PathBuf>, Option<u64>) {
    if image.is_empty() {
        return (None, None);
    }
    let path = std::path::PathBuf::from(image);
    let probe = crate::backend::flashimage::probe(&path);
    if probe.kind.is_empty() {
        return (Some(path), None);
    }
    let want = if probe.known { probe.unpacked } else { probe.bytes };
    (Some(path), Some(want))
}

pub struct FlashReq {
    pub id: usize,
    pub image: String,
    pub dev: String,
    pub seq: u64,
    pub serial: String,
    pub bytes: u64,
}

// The five flash requests, dispatched beside transfers on the flash slot alone; cancel only
// sets its flag, and the flash answers its own flashdone, as transfercancel does for a transfer.
pub fn request(out: &mut dyn std::io::Write, flash: &mut super::flashslot::Ctx, req: super::flash::Req) {
    match req {
        super::flash::Req::Image { path } => handle_flashimage(out, &path),
        super::flash::Req::Targets { image } => handle_flashtargets(out, &image),
        super::flash::Req::Flash { id, image, dev, seq, serial, bytes } => start_flash(out, &flash.slot, &flash.tx,
            FlashReq { id, image, dev, seq: seq as u64, serial, bytes }),
        super::flash::Req::Cancel { id } => flash.slot.cancel(id),
        super::flash::Req::Eject { dev, seq } => handle_flasheject(out, &dev, seq as u64),
    }
}

// Starts the flash worker, or refuses when one already runs; every ending is that worker's flashdone.
pub fn start_flash(out: &mut dyn std::io::Write, slot: &Slot, tx: &std::sync::mpsc::Sender<FlashMsg>, req: FlashReq) {
    let Some(flag) = slot.claim(req.id) else {
        let line = crate::backend::proto::error_line(&crate::error::FleaError {
            where_: "flash".to_string(),
            path: req.dev.clone(),
            msg: "a flash is already running".to_string(),
        });
        writeln!(out, "{line}").ok();
        out.flush().ok();
        return;
    };
    let tx = tx.clone();
    std::thread::spawn(move || run_flash(req, flag, &tx));
}

fn send(tx: &std::sync::mpsc::Sender<FlashMsg>, id: usize, line: String, terminal: bool) {
    let _ = tx.send(FlashMsg { id, line, terminal });
}

fn run_flash(req: FlashReq, cancel: Arc<AtomicBool>, tx: &std::sync::mpsc::Sender<FlashMsg>) {
    let id = req.id;
    let done = |phase: &str, ok: bool, at: u64, err: &str, blank: bool| {
        send(tx, id, flashdone_line(id, ok, phase, at, err, blank), true);
    };
    // The probe first: a row the pane never sends is refused before anything is touched.
    let probe = crate::backend::flashimage::probe(std::path::Path::new(&req.image));
    if probe.kind.is_empty() {
        done("probe", false, 0, "io", false);
        return;
    }
    let total = if probe.known { probe.unpacked } else { probe.bytes };
    let file_bytes = probe.bytes;
    send(tx, id, flashstarted_line(id, total, probe.known), false);
    let mut last = Instant::now() - Duration::from_millis(PROGRESS_EVERY_MS);
    let mut progress = |phase: &str, written: u64, input: u64, force: bool| {
        let now = Instant::now();
        if force || now.duration_since(last).as_millis() >= PROGRESS_EVERY_MS as u128 {
            last = now;
            let perm = if probe.known { permille(written, total) } else { permille(input, file_bytes) };
            send(tx, id, flashprogress_line(id, phase, written, total, perm), false);
        }
    };
    progress("password", 0, 0, true);
    // Layer 4 against fresh sysfs before the helper runs.
    let (exe, ui) = crate::backend::flasheligible::roots_for_production();
    let roots = crate::backend::flasheligible::Roots { sys: std::path::Path::new("/sys"), dev: std::path::Path::new("/dev"), exe: &exe, ui: &ui };
    let mountinfo = std::fs::read_to_string("/proc/self/mountinfo").unwrap_or_default();
    let swaps = std::fs::read_to_string("/proc/swaps").unwrap_or_default();
    if crate::backend::flasheligible::identity_changed(&roots, &mountinfo, &swaps, &req.dev, req.seq, &req.serial, req.bytes) {
        done("prepare", false, 0, "changed", false);
        return;
    }
    // The one prompt, then the exclusive descriptor, or the reason it never came.
    let dest = match open_target(&req) {
        Ok(file) => file,
        Err(err) => {
            done("password", false, 0, err, false);
            return;
        }
    };
    // Layer 6 on the descriptor, skipped for a test's regular file.
    if let Err(err) = check_descriptor(&dest, &req, "/sys") {
        done("prepare", false, 0, err, false);
        return;
    }
    if cancel.load(Ordering::Relaxed) {
        done("password", false, 0, "cancelled", false);
        return;
    }
    let job = crate::backend::flashwrite::Job { image: std::path::Path::new(&req.image), kind: &probe.kind, member: &probe.member, dest: &dest, drive_bytes: req.bytes, cancel: &cancel, stall: crate::backend::flashwrite::stall_limit() };
    match crate::backend::flashwrite::write_stream(&job, &mut |w, i| progress("write", w, i, false)) {
        Err(crate::backend::flashwrite::Fail::Cancelled) => {
            done("write", false, 0, "cancelled", crate::backend::flashverify::wipe_ends(&dest, req.bytes));
        }
        Err(crate::backend::flashwrite::Fail::NoSpace) => {
            done("write", false, 0, "nospace", crate::backend::flashverify::wipe_ends(&dest, req.bytes));
        }
        Err(crate::backend::flashwrite::Fail::Decompress(e)) => {
            eprintln!("flea: the unpacker failed on {} ({e})", req.image);
            done("write", false, 0, "decompress", crate::backend::flashverify::wipe_ends(&dest, req.bytes));
        }
        Err(crate::backend::flashwrite::Fail::Sandbox) => {
            done("write", false, 0, "sandbox", false);
        }
        Err(crate::backend::flashwrite::Fail::Io(e)) => {
            let err = if gone(&req.dev) { "gone" } else { &e_to_err(&e) };
            let blank = if err == "gone" { false } else { crate::backend::flashverify::wipe_ends(&dest, req.bytes) };
            done("write", false, 0, err, blank);
        }
        Ok((table, written)) => {
            progress("flush", written, file_bytes, true);
            if cancel.load(Ordering::Relaxed) {
                done("verify", false, 0, "cancelled", false);
                return;
            }
            match crate::backend::flashverify::verify(&dest, &table, written, &cancel, &mut |w| progress("verify", w, w, false)) {
                Ok(()) => {
                    drop(dest);
                    done("verify", true, 0, "", false);
                }
                Err(crate::backend::flashwrite::Fail::Cancelled) => done("verify", false, 0, "cancelled", false),
                Err(crate::backend::flashwrite::Fail::Io(msg)) => {
                    if let Some(at) = msg.strip_prefix("mismatch:") {
                        done("verify", false, at.parse().unwrap_or(0), "verify", false);
                    } else if gone(&req.dev) {
                        done("verify", false, 0, "gone", false);
                    } else {
                        done("verify", false, 0, "io", false);
                    }
                }
                Err(_) => done("verify", false, 0, "io", false),
            }
        }
    }
}

fn e_to_err(_e: &str) -> String {
    "io".to_string()
}

// The helper's descriptor, or the test file the thread-local names; the err is the flashdone word.
fn open_target(req: &FlashReq) -> Result<std::fs::File, &'static str> {
    #[cfg(test)]
    {
        if let Some(path) = TEST_DIRECT_TARGET.with(|v| v.borrow().clone()) {
            return std::fs::OpenOptions::new().read(true).write(true).open(&path).map_err(|_| "gone");
        }
    }
    match crate::backend::flashhelper::open_device(&req.dev, &req.serial, req.bytes) {
        Ok(fd) => Ok(std::fs::File::from(fd)),
        Err(crate::backend::flashhelper::OpenFail::Denied) => Err("denied"),
        Err(crate::backend::flashhelper::OpenFail::Busy) => Err("busy"),
        Err(crate::backend::flashhelper::OpenFail::Changed) => Err("changed"),
        Err(crate::backend::flashhelper::OpenFail::Helper(e)) => {
            eprintln!("flea: the udisks helper failed ({e})");
            Err("helper")
        }
    }
}

// Gone when the kernel no longer lists the disk, so no wipe is attempted on a missing drive.
fn gone(dev: &str) -> bool {
    !std::path::Path::new("/sys/block").join(dev).is_dir()
}

// The kernel's diskseq for the disk, the plugging the step showed; a swapped medium differs.
fn disk_seq(dev: &str) -> Option<u64> {
    std::fs::read_to_string(format!("/sys/block/{dev}/diskseq")).ok()?.trim().parse().ok()
}

// Layer 6: the descriptor is the disk the step showed, with nothing mounted onto it mid-write.
fn check_descriptor(dest: &std::fs::File, req: &FlashReq, sys: &str) -> Result<(), &'static str> {
    use std::os::unix::fs::FileTypeExt;
    if !dest.metadata().map(|m| m.file_type().is_block_device()).unwrap_or(false) {
        return Ok(());
    }
    let rdev = dest.metadata().map(|m| m.dev()).unwrap_or(0);
    let major = ((rdev >> 8) & 0xfff) | ((rdev >> 32) & 0xfffff000);
    let minor = (rdev & 0xff) | ((rdev >> 12) & 0xffffff00);
    let want = format!("{major}:{minor}");
    let have = std::fs::read_to_string(format!("{sys}/block/{}/dev", req.dev)).unwrap_or_default();
    if have.trim() != want {
        return Err("changed");
    }
    let mut size: u64 = 0;
    if unsafe { ioctl(dest.as_raw_fd(), BLKGETSIZE64, &mut size) } != 0 || size != req.bytes {
        return Err("changed");
    }
    let mut seq: u64 = 0;
    if unsafe { ioctl(dest.as_raw_fd(), BLKGETDISKSEQ, &mut seq) } != 0 || seq != req.seq {
        return Err("changed");
    }
    let mountinfo = std::fs::read_to_string("/proc/self/mountinfo").unwrap_or_default();
    let swaps = std::fs::read_to_string("/proc/swaps").unwrap_or_default();
    if !mounts_clean(&req.dev, &mountinfo, &swaps) {
        return Err("changed");
    }
    Ok(())
}

// True when no partition of the disk is mounted or swapped on; the helper unmounted them all.
fn mounts_clean(dev: &str, mountinfo: &str, swaps: &str) -> bool {
    for line in mountinfo.lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        let Some(split) = fields.iter().position(|f| *f == "-") else { continue };
        if fields.len() <= split + 2 {
            continue;
        }
        let source = fields[split + 2];
        if let Some(rest) = source.strip_prefix("/dev/") {
            // The disk itself or one of its partitions, sda beside sda1 and nvme0n1 beside nvme0n1p1.
            let tail = rest.strip_prefix(dev).unwrap_or_default();
            if rest == dev || (!tail.is_empty() && tail.starts_with(|c: char| c.is_ascii_digit() || c == 'p')) {
                return false;
            }
        }
    }
    for (i, line) in swaps.lines().enumerate() {
        if i == 0 && line.starts_with("Filename") {
            continue;
        }
        let file = line.split_whitespace().next().unwrap_or_default();
        if let Some(rest) = file.strip_prefix("/dev/") {
            if rest == dev || rest.starts_with(dev) {
                return false;
            }
        }
    }
    true
}

// Eject through the helper; a missing disk is gone, and a swapped one is changed, before
// anything is spawned. The rail's own lsblk verdict still writes the sentence the user reads.
pub fn handle_flasheject(out: &mut dyn std::io::Write, dev: &str, seq: u64) {
    if gone(dev) {
        writeln!(out, "{}", crate::backend::flash::flasheject_line(false, "gone")).ok();
        return;
    }
    if disk_seq(dev) != Some(seq) {
        writeln!(out, "{}", crate::backend::flash::flasheject_line(false, "changed")).ok();
        return;
    }
    match crate::backend::flashhelper::eject(dev) {
        Ok(()) => writeln!(out, "{}", crate::backend::flash::flasheject_line(true, "")).ok(),
        Err(err) => writeln!(out, "{}", crate::backend::flash::flasheject_line(false, &err)).ok(),
    };
    out.flush().ok();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::testdir::TestDir;

    #[test]
    fn a_mounted_partition_dirties_the_disk() {
        let info = "28 1 8:1 / / rw - ext4 /dev/sda1 rw\n";
        assert!(!mounts_clean("sda", info, "Filename Type Size Used Priority\n"));
        assert!(mounts_clean("sda", "28 1 8:1 / / rw - ext4 /dev/nvme0n1p1 rw\n", "Filename Type Size Used Priority\n"));
        assert!(!mounts_clean("sda", "28 1 8:1 / / rw - ext4 /dev/nvme0n1p1 rw\n", "Filename Type Size Used Priority\n/dev/sda1 partition 1 0 -2\n"));
    }

    #[test]
    fn a_regular_file_skips_the_block_checks() {
        let d = TestDir::new("flashop-regular");
        let path = d.join("drive.img");
        std::fs::write(&path, vec![0u8; 4096]).unwrap();
        let file = std::fs::OpenOptions::new().read(true).write(true).open(&path).unwrap();
        let req = FlashReq { id: 1, image: String::new(), dev: "sda".to_string(), seq: 0, serial: String::new(), bytes: 0 };
        assert!(check_descriptor(&file, &req, "/sys").is_ok());
    }

    #[test]
    fn a_second_flash_while_one_runs_is_refused() {
        let slot = Slot::new();
        let (tx, _rx) = std::sync::mpsc::channel::<FlashMsg>();
        let mut out = Vec::new();
        let _held = slot.claim(1).unwrap();
        start_flash(&mut out, &slot, &tx, FlashReq { id: 2, image: String::new(), dev: "sda".to_string(), seq: 0, serial: String::new(), bytes: 0 });
        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("\"where\":\"flash\"") && text.contains("already running"), "{text}");
    }

    #[test]
    fn the_worker_refuses_a_changed_identity_before_any_write() {
        let d = TestDir::new("flashop-changed");
        let body: Vec<u8> = (0..70_000u32).map(|n| (n % 251) as u8).collect();
        let image = d.join("a.img");
        std::fs::write(&image, &body).unwrap();
        let target = d.join("drive.img");
        std::fs::write(&target, vec![0u8; 8_000_000]).unwrap();
        test_set_direct_target(Some(target.clone()));
        let (tx, rx) = std::sync::mpsc::channel::<FlashMsg>();
        let flag = Arc::new(AtomicBool::new(false));
        // Layer 4 runs against the live tree, where no sda answers this identity, so the worker
        // probes, starts and refuses before the helper or any write; the write arm runs in flashwrite.
        run_flash(FlashReq { id: 3, image: image.to_string_lossy().to_string(), dev: "sda".to_string(), seq: 0, serial: String::new(), bytes: 124_623_257_600 }, flag, &tx);
        test_set_direct_target(None);
        drop(tx);
        let lines: Vec<FlashMsg> = rx.into_iter().collect();
        assert_eq!(lines.len(), 3, "started, one password beat, then done: {:?}", lines.iter().map(|m| &m.line).collect::<Vec<_>>());
        assert!(lines[0].line.contains("\"t\":\"flashstarted\""), "{}", lines[0].line);
        assert!(lines[1].line.contains("\"phase\":\"password\""), "{}", lines[1].line);
        assert!(lines[2].line.contains("\"t\":\"flashdone\"") && lines[2].line.contains("\"err\":\"changed\""), "{}", lines[2].line);
        assert!(lines[2].terminal);
    }
}
