use std::io::{self, Read, Write};
use std::os::unix::io::RawFd;
use std::os::unix::net::UnixStream;

// The main loop's wait: stdin plus the wire reader's wake byte, so a queued
// backend reply ends the quantum instead of waiting it out.
pub const QUANTUM_MS: i32 = 100; // the stty min 0 time 1 quantum, now owned here
#[repr(C)]
struct PollFd {
    fd: i32,
    events: i16,
    revents: i16,
}
const POLLIN: i16 = 1;
extern "C" {
    // poll(2) under its own name: src/backend/menu_registry.rs already declares
    // it, and a second declaration would warn on the signature.
    #[link_name = "poll"]
    fn wait_poll(fds: *mut PollFd, nfds: usize, timeout_ms: i32) -> i32;
}
// Same wait with an explicit budget: a hold near its deadline waits only for it.
pub fn wait_input_timeout(wake: RawFd, timeout_ms: i32) -> io::Result<bool> {
    wait_on(0, wake, timeout_ms)
}
fn wait_on(stdin: RawFd, wake: RawFd, timeout_ms: i32) -> io::Result<bool> {
    let mut fds = [
        PollFd { fd: stdin, events: POLLIN, revents: 0 },
        PollFd { fd: wake, events: POLLIN, revents: 0 },
    ];
    let ready = unsafe { wait_poll(fds.as_mut_ptr(), fds.len(), timeout_ms) };
    if ready < 0 {
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::Interrupted {
            return Ok(false);
        }
        return Err(error);
    }
    Ok(fds[0].revents & POLLIN != 0)
}
// A connected pair: the reader thread signals on one end, the loop waits on the other.
pub fn pair() -> io::Result<(UnixStream, UnixStream)> {
    let (read, write) = UnixStream::pair()?;
    // Both ends: a signal never blocks the reader, and a drain never blocks the loop.
    read.set_nonblocking(true)?;
    write.set_nonblocking(true)?;
    Ok((read, write))
}
// One wake byte per queued event; the byte is only a hint, so a full pipe drops it.
pub fn signal(write: &mut UnixStream) {
    let _ = write.write(&[1u8]);
}
// Clear the hint bytes; the queued events themselves are drained from the channel.
pub fn drain(read: &mut UnixStream) {
    let mut trash = [0u8; 64];
    loop {
        match read.read(&mut trash) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::io::AsRawFd;
    use std::time::{Duration, Instant};
    // A queued wire event ends the wait promptly, not at the 100 ms quantum.
    // Stdin here is a held pipe, so the wake byte alone decides the timing.
    #[test]
    fn signaled_wake_returns_before_the_quantum() {
        let (stdin, _held) = pair().unwrap();
        let (wake, mut signaler) = pair().unwrap();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(20));
            signal(&mut signaler);
        });
        let before = Instant::now();
        assert!(!wait_on(stdin.as_raw_fd(), wake.as_raw_fd(), QUANTUM_MS).unwrap());
        assert!(before.elapsed() < Duration::from_millis(90), "a signaled wait took {:?}", before.elapsed());
    }
    // With no signal the wait still lasts the full quantum, as today.
    #[test]
    fn silent_wait_lasts_the_quantum() {
        let (stdin, _held) = pair().unwrap();
        let (wake, _signaler) = pair().unwrap();
        let before = Instant::now();
        assert!(!wait_on(stdin.as_raw_fd(), wake.as_raw_fd(), QUANTUM_MS).unwrap());
        assert!(before.elapsed() >= Duration::from_millis(90), "an idle wait returned after {:?}", before.elapsed());
    }
    // A readable stdin answers true at once, wake or none.
    #[test]
    fn readable_stdin_answers_true() {
        let (stdin, mut held) = pair().unwrap();
        let (wake, _signaler) = pair().unwrap();
        signal(&mut held);
        assert!(wait_on(stdin.as_raw_fd(), wake.as_raw_fd(), QUANTUM_MS).unwrap());
    }
    // An empty wake pair drains at once instead of blocking the loop.
    #[test]
    fn empty_drain_returns_at_once() {
        let (mut read, _write) = pair().unwrap();
        let (done, wait) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            drain(&mut read);
            let _ = done.send(());
        });
        wait.recv_timeout(Duration::from_secs(5)).expect("drain blocked on an empty pair");
    }
}
