use std::io::{self, Read, Write};
use std::os::unix::io::RawFd;
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

// The main loop's wait: stdin plus the wire reader's wake byte, so a queued reply ends the quantum early.
pub const QUANTUM_MS: i32 = 100; // the stty min 0 time 1 quantum, now owned here
#[repr(C)]
struct PollFd {
    fd: i32,
    events: i16,
    revents: i16,
}
const POLLIN: i16 = 1;
extern "C" {
    // poll(2) under its own name: src/backend/menu_registry.rs declares it too, and a second declaration would warn.
    #[link_name = "poll"]
    fn wait_poll(fds: *mut PollFd, nfds: usize, timeout_ms: i32) -> i32;
}
// Same wait with an explicit budget: a hold near its deadline waits only for it.
pub fn wait_input_timeout(wake: RawFd, timeout_ms: i32) -> io::Result<bool> {
    wait_on(0, wake, timeout_ms)
}
pub(super) fn wait_on(stdin: RawFd, wake: RawFd, timeout_ms: i32) -> io::Result<bool> {
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
// The escape timeout stty time 1 gave: a lone ESC is the Escape key only after this much input silence.
pub const ESCAPE_MS: u64 = 100;
// Input silence for the decoder, so an empty read after a wake byte or a short hold keeps a split escape whole.
pub struct Silence {
    last: Instant,
    // The last read ended on ESC, so the loop's wait ends with the escape timeout.
    escape: bool,
}
impl Silence {
    pub fn new(now: Instant) -> Self {
        Self { last: now, escape: false }
    }
    // True once ESCAPE_MS pass with no byte; a read with bytes restarts the count.
    pub fn idle(&mut self, bytes: &[u8], now: Instant) -> bool {
        if !bytes.is_empty() {
            self.last = now;
            self.escape = bytes.last() == Some(&0x1b);
            return false;
        }
        let idle = now.duration_since(self.last) >= Duration::from_millis(ESCAPE_MS);
        if idle {
            self.escape = false;
        }
        idle
    }
    // What a trailing ESC has left of the escape timeout, else the idle quantum.
    pub fn wait_ms(&self, now: Instant) -> i32 {
        if !self.escape {
            return QUANTUM_MS;
        }
        ESCAPE_MS.saturating_sub(now.duration_since(self.last).as_millis() as u64) as i32
    }
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
    // A queued wire event ends the wait promptly; stdin is a held pipe, so the wake byte alone decides the timing.
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
    // An empty read 2 ms after a lone ESC, as a wake byte or a short hold makes, keeps it pending for its tail.
    #[test]
    fn split_escape_survives_an_early_empty_read() {
        let start = Instant::now();
        let mut silence = Silence::new(start);
        let mut decoder = crate::tui::input::Decoder::default();
        let mut feed = |bytes: &[u8], ms: u64| {
            let idle = silence.idle(bytes, start + Duration::from_millis(ms));
            decoder.feed(bytes, idle)
        };
        assert!(feed(b"\x1b", 0).is_empty());
        assert!(feed(b"", 2).is_empty(), "an early empty read flushed the ESC as Escape");
        assert_eq!(feed(b"[A", 4), vec![crate::tui::input::Key::named("Up", "")]);
    }
    // After the escape timeout passes in silence, the lone ESC is the Escape key.
    #[test]
    fn lone_escape_flushes_after_the_timeout() {
        let start = Instant::now();
        let mut silence = Silence::new(start);
        let mut decoder = crate::tui::input::Decoder::default();
        assert!(decoder.feed(b"\x1b", silence.idle(b"\x1b", start)).is_empty());
        let idle = silence.idle(b"", start + Duration::from_millis(ESCAPE_MS));
        assert_eq!(decoder.feed(b"", idle), vec![crate::tui::input::Key::named("Escape", "")]);
    }
    // A trailing ESC cuts the loop's wait to what is left of its timeout, and the quantum returns once it reads as Escape.
    #[test]
    fn trailing_escape_cuts_the_wait_to_its_timeout() {
        let start = Instant::now();
        let at = |ms: u64| start + Duration::from_millis(ms);
        let mut silence = Silence::new(start);
        assert_eq!(silence.wait_ms(start), QUANTUM_MS);
        assert!(!silence.idle(b"\x1b", start));
        assert_eq!(silence.wait_ms(at(30)), 70, "a pending ESC waited past its timeout");
        assert!(!silence.idle(b"", at(40)), "an early empty read ended the timeout");
        assert_eq!(silence.wait_ms(at(40)), 60, "a wake byte restarted the timeout");
        assert!(silence.idle(b"", at(ESCAPE_MS)));
        assert_eq!(silence.wait_ms(at(ESCAPE_MS)), QUANTUM_MS, "a flushed ESC kept cutting the wait");
        assert!(!silence.idle(b"\x1b[A", at(120)));
        assert_eq!(silence.wait_ms(at(130)), QUANTUM_MS, "a whole sequence cut the wait");
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
