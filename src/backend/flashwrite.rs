// The write loop, the flush, the cancel and the stall; TECH.md sections 5 and 6 beside the verify.
use crate::backend::flash::{CHUNK_BYTES, DIRECT_ALIGN, STALL_SECS};
use std::os::fd::AsRawFd;
use std::os::raw::{c_int, c_void};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::channel;
use std::time::{Duration, Instant};

extern "C" {
    fn pread(fd: c_int, buf: *mut c_void, count: usize, offset: i64) -> isize;
    fn pwrite(fd: c_int, buf: *const c_void, count: usize, offset: i64) -> isize;
    fn fsync(fd: c_int) -> c_int;
}

// What one flash phase can end in; flashop maps each to its flashdone err.
#[derive(Debug)]
pub enum Fail {
    Cancelled,
    Io(String),
    NoSpace,
    Decompress(String),
    Sandbox,
}

// One 4 MiB window aligned to 4096 inside an ordinary allocation, so O_DIRECT accepts it
// with no manual layout to deallocate; a mismatched dealloc aborted the suite under test.
struct Aligned {
    backing: Vec<u8>,
    start: usize,
}

fn aligned() -> Aligned {
    let backing = vec![0u8; CHUNK_BYTES + DIRECT_ALIGN];
    let off = (DIRECT_ALIGN - backing.as_ptr() as usize % DIRECT_ALIGN) % DIRECT_ALIGN;
    Aligned { backing, start: off }
}

impl Aligned {
    fn window(&mut self) -> &mut [u8] {
        &mut self.backing[self.start..self.start + CHUNK_BYTES]
    }
}

// One verify-sized buffer; the aligned write buffer above stays the write loop's own.
pub(crate) fn chunk_buf() -> Vec<u8> {
    vec![0u8; CHUNK_BYTES]
}

pub(crate) fn full_pwrite(fd: c_int, buf: &[u8], offset: u64) -> std::io::Result<()> {
    let mut at = 0;
    while at < buf.len() {
        let n = unsafe { pwrite(fd, buf[at..].as_ptr() as *const c_void, buf.len() - at, (offset + at as u64) as i64) };
        if n < 0 {
            return Err(std::io::Error::last_os_error());
        }
        if n == 0 {
            return Err(std::io::Error::new(std::io::ErrorKind::WriteZero, "no progress writing the drive"));
        }
        at += n as usize;
    }
    Ok(())
}

pub(crate) fn full_pread(fd: c_int, buf: &mut [u8], offset: u64) -> std::io::Result<usize> {
    let mut at = 0;
    while at < buf.len() {
        let n = unsafe { pread(fd, buf[at..].as_mut_ptr() as *mut c_void, buf.len() - at, (offset + at as u64) as i64) };
        if n < 0 {
            return Err(std::io::Error::last_os_error());
        }
        if n == 0 {
            break;
        }
        at += n as usize;
    }
    Ok(at)
}

// One flash write's inputs, bundled so the functions below stay under the argument limit.
pub(crate) struct Job<'a> {
    pub image: &'a std::path::Path,
    pub kind: &'a str,
    pub member: &'a str,
    pub dest: &'a std::fs::File,
    pub drive_bytes: u64,
    pub cancel: &'a AtomicBool,
    pub stall: Duration,
}

// Writes the image to dest; the table holds one XXH64 per 4 MiB for the verify pass, and the
// count holds the written bytes, which is what sizes the verify's own last chunk.
pub fn write_stream(job: &Job, on_progress: &mut dyn FnMut(u64, u64)) -> Result<(Vec<u64>, u64), Fail> {
    let raw = job.kind == "iso" || job.kind == "img";
    let fd = job.dest.as_raw_fd();
    let mut table = Vec::new();
    let mut offset: u64 = 0;
    if raw {
        let src = std::fs::File::open(job.image).map_err(|e| Fail::Io(e.to_string()))?;
        let src_fd = src.as_raw_fd();
        let mut buf = aligned();
        loop {
            if job.cancel.load(Ordering::Relaxed) {
                return Err(Fail::Cancelled);
            }
            let n = full_pread(src_fd, buf.window(), offset).map_err(|e| Fail::Io(e.to_string()))?;
            if n == 0 {
                break;
            }
            // A stream longer than the drive ends here, before any byte past the end is written.
            if offset >= job.drive_bytes || offset + n as u64 > job.drive_bytes {
                return Err(Fail::NoSpace);
            }
            write_chunk(fd, &buf.window()[..n], offset, job.drive_bytes)?;
            table.push(crate::backend::xxh64::hash(&buf.window()[..n]));
            offset += n as u64;
            on_progress(offset, offset);
        }
    } else {
        let (mut child, input) = super::flashpipe::spawn_producer(job.kind, job.image, job.member)?;
        let out = run_piped(&mut child, input.as_ref(), job, on_progress, &mut table)?;
        let status = child.wait().map_err(|e| Fail::Decompress(e.to_string()))?;
        if !status.success() {
            return Err(Fail::Decompress(format!("the unpacker exited with status {}", status)));
        }
        offset = out;
        let _ = offset;
    }
    if unsafe { fsync(fd) } != 0 {
        return Err(Fail::Io(std::io::Error::last_os_error().to_string()));
    }
    Ok((table, offset))
}

// Reads the producer's pipe into aligned buffers and writes each in order with O_DIRECT.
fn run_piped(child: &mut std::process::Child, input: Option<&std::fs::File>, job: &Job, on_progress: &mut dyn FnMut(u64, u64), table: &mut Vec<u64>) -> Result<u64, Fail> {
    use crate::backend::flash::CHUNK_COUNT;
    use std::io::Read;
    let fd = job.dest.as_raw_fd();
    // A blocking reader owns the pipe; the loop waits 20 ms, so cancel and the stall bound answer on time.
    let (chunk_tx, chunk_rx) = channel::<Result<Vec<u8>, String>>();
    let pipe = child.stdout.take();
    let reader = std::thread::spawn(move || {
        let mut chunk = [0u8; 65536];
        let Some(mut pipe) = pipe else { return };
        loop {
            match pipe.read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => {
                    if chunk_tx.send(Ok(chunk[..n].to_vec())).is_err() {
                        break;
                    }
                }
                Err(e) => {
                    let _ = chunk_tx.send(Err(e.to_string()));
                    break;
                }
            }
        }
    });
    // Four buffers of 4 MiB, a reader filling them and a writer issuing one pwrite at a time in
    // order; the bound is what stops a fast producer from queueing the whole image behind a slow drive.
    let (buf_tx, buf_rx) = std::sync::mpsc::sync_channel::<(u64, Vec<u8>)>(CHUNK_COUNT);
    let (done_tx, done_rx) = channel::<Result<(u64, usize, u64), Fail>>();
    // A cancel stops the writer before its next buffer, so at most one 4 MiB pwrite is in flight.
    let stop = std::sync::Arc::new(AtomicBool::new(false));
    let writer_stop = std::sync::Arc::clone(&stop);
    // Copied out, because the writer thread outlives this frame's borrow of the job.
    let drive_bytes = job.drive_bytes;
    let writer = std::thread::spawn(move || {
        loop {
            let Ok((offset, bytes)) = buf_rx.recv() else { return };
            if writer_stop.load(Ordering::Relaxed) {
                return;
            }
            // A stream longer than the drive ends here, before any byte past the end is written.
            if offset >= drive_bytes || offset + bytes.len() as u64 > drive_bytes {
                let _ = done_tx.send(Err(Fail::NoSpace));
                return;
            }
            let digest = crate::backend::xxh64::hash(&bytes);
            if let Err(fail) = write_chunk(fd, &bytes, offset, drive_bytes) {
                let _ = done_tx.send(Err(fail));
                return;
            }
            if done_tx.send(Ok((offset, bytes.len(), digest))).is_err() {
                return;
            }
        }
    });
    let mut buf = aligned();
    let mut filled = 0;
    let mut offset: u64 = 0;
    let mut sent = 0;
    let mut received = 0;
    let mut last_progress = Instant::now();
    let mut last_input = super::flashpipe::input_offset(input, 0);
    let mut end = false;
    // One chunk into the aligned buffer, handing whole 4 MiB buffers to the writer in order.
    // False when the writer is gone, which only its own failure leaves behind.
    let mut ingest = |bytes: &[u8], filled: &mut usize, offset: &mut u64, sent: &mut u64| -> bool {
        let mut at = 0;
        while at < bytes.len() {
            let room = CHUNK_BYTES - *filled;
            let take = room.min(bytes.len() - at);
            buf.window()[*filled..*filled + take].copy_from_slice(&bytes[at..at + take]);
            *filled += take;
            at += take;
            if *filled == CHUNK_BYTES {
                // The bound waits here when four buffers are still being written.
                if buf_tx.send((*offset, buf.window()[..*filled].to_vec())).is_err() {
                    return false;
                }
                *offset += *filled as u64;
                *sent += 1;
                *filled = 0;
            }
        }
        true
    };
    // One finished buffer behind the writer is the throttle's own shape; a free function, so no borrow outlives its turn.
    fn landed(done: Result<(u64, usize, u64), Fail>, table: &mut Vec<u64>, received: &mut u64, on_progress: &mut dyn FnMut(u64, u64), input: Option<&std::fs::File>) -> Option<Fail> {
        match done {
            Ok((at, len, digest)) => {
                table.push(digest);
                *received += 1;
                on_progress(at + len as u64, super::flashpipe::input_offset(input, at + len as u64));
                None
            }
            Err(fail) => Some(fail),
        }
    }
    // Single exit: the loop breaks with its answer, and the teardown below runs exactly once.
    let exit: Result<(), Fail> = 'main: loop {
        if job.cancel.load(Ordering::Relaxed) {
            stop.store(true, Ordering::Relaxed);
            break 'main Err(Fail::Cancelled);
        }
        if !end {
            match chunk_rx.recv_timeout(Duration::from_millis(20)) {
                Ok(Ok(bytes)) => {
                    if !ingest(&bytes, &mut filled, &mut offset, &mut sent) {
                        break 'main drain_writer(&done_rx, table, &mut *on_progress, input, job.cancel);
                    }
                    last_progress = Instant::now();
                    last_input = super::flashpipe::input_offset(input, offset);
                }
                Ok(Err(e)) => break 'main Err(Fail::Decompress(e)),
                // A disconnect is the reader's end with nothing queued; a timeout is one more turn.
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => end = true,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                    if reader.is_finished() {
                        // The pipe is at EOF when the reader is gone; a queued chunk still counts.
                        match chunk_rx.try_recv() {
                            Ok(Ok(bytes)) => {
                                if !ingest(&bytes, &mut filled, &mut offset, &mut sent) {
                                    break 'main drain_writer(&done_rx, table, &mut *on_progress, input, job.cancel);
                                }
                                last_progress = Instant::now();
                                last_input = super::flashpipe::input_offset(input, offset);
                                continue 'main;
                            }
                            _ => end = true,
                        }
                    } else {
                        // A stall is silence on both ends: no output and the input not moving.
                        let now_input = super::flashpipe::input_offset(input, offset);
                        if now_input != last_input {
                            last_input = now_input;
                            last_progress = Instant::now();
                        }
                        if last_progress.elapsed() >= job.stall {
                            break 'main Err(Fail::Decompress("the unpacker stalled".to_string()));
                        }
                    }
                }
            }
        }
        for done in done_rx.try_iter() {
            if let Some(fail) = landed(done, table, &mut received, &mut *on_progress, input) {
                break 'main Err(fail);
            }
        }
        if end {
            if received == sent {
                break 'main Ok(());
            }
            // The writer is still draining its queue behind the reader's end.
            match done_rx.recv_timeout(Duration::from_millis(20)) {
                Ok(done) => {
                    if let Some(fail) = landed(done, table, &mut received, &mut *on_progress, input) {
                        break 'main Err(fail);
                    }
                }
                Err(_) => {
                    if job.cancel.load(Ordering::Relaxed) {
                        stop.store(true, Ordering::Relaxed);
                        break 'main Err(Fail::Cancelled);
                    }
                }
            }
        }
    };
    // The teardown runs once: the writer sees the disconnect, the child dies, both joins land.
    drop(buf_tx);
    super::flashpipe::try_kill(child);
    let _ = reader.join();
    writer.join().ok();
    exit?;
    if filled > 0 {
        // The tail is written after the writer drained, so its order is kept without a race.
        if offset >= job.drive_bytes || offset + filled as u64 > job.drive_bytes {
            return Err(Fail::NoSpace);
        }
        let tail = buf.window()[..filled].to_vec();
        super::flashverify::write_tail(job.dest, &tail, offset).map_err(|e| Fail::Io(e.to_string()))?;
        table.push(crate::backend::xxh64::hash(&tail));
        offset += filled as u64;
        on_progress(offset, super::flashpipe::input_offset(input, offset));
    }
    Ok(offset)
}

// The writer is gone; its own error is queued behind its last done, so this waits for exactly it.
fn drain_writer(done_rx: &std::sync::mpsc::Receiver<Result<(u64, usize, u64), Fail>>, table: &mut Vec<u64>, on_progress: &mut dyn FnMut(u64, u64), input: Option<&std::fs::File>, cancel: &AtomicBool) -> Result<(), Fail> {
    if cancel.load(Ordering::Relaxed) {
        return Err(Fail::Cancelled);
    }
    loop {
        match done_rx.recv() {
            Ok(Ok((at, len, digest))) => {
                table.push(digest);
                on_progress(at + len as u64, super::flashpipe::input_offset(input, at + len as u64));
            }
            Ok(Err(fail)) => return Err(fail),
            Err(_) => return Err(Fail::Io("the writer went away".to_string())),
        }
    }
}

fn write_chunk(fd: c_int, buf: &[u8], offset: u64, _drive: u64) -> Result<(), Fail> {
    full_pwrite(fd, buf, offset).map_err(|e| {
        if e.raw_os_error() == Some(28) {
            Fail::NoSpace
        } else {
            Fail::Io(e.to_string())
        }
    })
}


pub fn stall_limit() -> Duration {
    Duration::from_secs(STALL_SECS)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::testdir::TestDir;

    fn target(dir: &TestDir, name: &str, bytes: usize) -> std::fs::File {
        let path = dir.join(name);
        let file = std::fs::OpenOptions::new().read(true).write(true).create(true).truncate(true).open(&path).unwrap();
        file.set_len(bytes as u64).unwrap();
        file
    }

    fn image(dir: &TestDir, name: &str, bytes: usize, seed: u8) -> std::path::PathBuf {
        let path = dir.join(name);
        let body: Vec<u8> = (0..bytes).map(|n| (n % 251) as u8 ^ seed).collect();
        std::fs::write(&path, &body).unwrap();
        path
    }

    #[test]
    fn a_stalled_stub_decompressor_ends_decompress() {
        let d = TestDir::new("flashwrite-stall");
        let src = image(&d, "a.img.xz", 1000, 9);
        let dest = target(&d, "drive.img", 4_000_000);
        super::super::flashpipe::test_set_decompressor(Some(vec!["/usr/bin/sleep".to_string(), "60".to_string()]));
        let cancel = AtomicBool::new(false);
        let out = write_stream(&Job { image: &src, kind: "xz", member: "", dest: &dest, drive_bytes: 4_000_000, cancel: &cancel, stall: Duration::from_secs(1) }, &mut |_, _| {});
        super::super::flashpipe::test_set_decompressor(None);
        assert!(matches!(out, Err(Fail::Decompress(_))), "a silent producer is a stall");
    }

    #[test]
    fn an_image_outgrowing_its_drive_ends_nospace() {
        let d = TestDir::new("flashwrite-nospace");
        let src = image(&d, "a.img", 5_000_000, 11);
        let dest = target(&d, "drive.img", 1_000_000);
        let cancel = AtomicBool::new(false);
        let out = write_stream(&Job { image: &src, kind: "img", member: "", dest: &dest, drive_bytes: 1_000_000, cancel: &cancel, stall: stall_limit() }, &mut |_, _| {});
        assert!(matches!(out, Err(Fail::NoSpace)));
    }
}
