// The source and its existing chunk buffer, kept apart from the destination writer.
use std::fs::File;
use std::io::{self, Read};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::time::Duration;

// Linux FUSE_SUPER_MAGIC includes GVFS and MTP mounts, even when reached through a symlinked parent.
const FUSE_MAGIC: i64 = 0x65735546;
// The transfer checks Cancel at least every 25 ms while the source worker is inside a read.
const CANCEL_POLL: Duration = Duration::from_millis(25);
// Local sources keep the original chunk sizes and direct read, with no channel or extra data copy.
pub(super) const CHUNK: usize = 256 * 1024;
const SMALL_CHUNK: usize = 8 * 1024;

struct PendingRead {
    request: Sender<Vec<u8>>,
    result: Receiver<(Vec<u8>, io::Result<usize>)>,
}

impl PendingRead {
    fn start(mut reader: impl Read + Send + 'static) -> io::Result<PendingRead> {
        let (request, buffers) = mpsc::channel::<Vec<u8>>();
        let (answers, result) = mpsc::channel();
        // The worker owns only the source and one moved buffer, never a destination descriptor or path.
        std::thread::Builder::new().name("flea-copy-read".into()).spawn(move || {
            while let Ok(mut buffer) = buffers.recv() {
                let answer = reader.read(&mut buffer);
                if answers.send((buffer, answer)).is_err() {
                    break;
                }
            }
        })?;
        Ok(PendingRead { request, result })
    }
}

enum Source {
    File(File),
    Pending(PendingRead),
}

pub(super) struct Reader {
    source: Source,
    pub(super) buffer: Vec<u8>,
}

impl Reader {
    pub(super) fn new(file: File, size: u64, magic: Option<i64>) -> io::Result<Reader> {
        #[cfg(test)]
        let stand_in = TEST_READER.with(|slot| slot.borrow_mut().take());
        #[cfg(test)]
        if let Some(reader) = stand_in {
            return Ok(Reader::with_source(Source::Pending(PendingRead::start(reader)?), size));
        }
        let source = if magic == Some(FUSE_MAGIC) {
            Source::Pending(PendingRead::start(file)?)
        } else {
            Source::File(file)
        };
        Ok(Reader::with_source(source, size))
    }

    fn with_source(source: Source, size: u64) -> Reader {
        let buffer = vec![0; usize::try_from(size).map_or(CHUNK, |len| len.clamp(SMALL_CHUNK, CHUNK))];
        #[cfg(test)]
        BUFFERS.with(|v| v.borrow_mut().push(buffer.len()));
        Reader {
            source,
            buffer,
        }
    }

    pub(super) fn read(&mut self, cancel: &AtomicBool) -> io::Result<usize> {
        match &mut self.source {
            Source::File(file) => file.read(&mut self.buffer),
            Source::Pending(pending) => {
                pending.request.send(std::mem::take(&mut self.buffer)).map_err(|_| io::ErrorKind::BrokenPipe)?;
                loop {
                    if cancel.load(Ordering::Relaxed) {
                        return Err(io::ErrorKind::Interrupted.into());
                    }
                    match pending.result.recv_timeout(CANCEL_POLL) {
                        Ok((buffer, answer)) => {
                            self.buffer = buffer;
                            return answer;
                        }
                        Err(RecvTimeoutError::Timeout) => {}
                        Err(RecvTimeoutError::Disconnected) => return Err(io::ErrorKind::BrokenPipe.into()),
                    }
                }
            }
        }
    }
}

#[cfg(test)]
thread_local! {
    static TEST_READER: std::cell::RefCell<Option<Box<dyn Read + Send>>> = const { std::cell::RefCell::new(None) };
    static BUFFERS: std::cell::RefCell<Vec<usize>> = const { std::cell::RefCell::new(Vec::new()) };
}

// The next copy on this thread opens and checks its source normally, then reads this deterministic stand-in.
#[cfg(test)]
pub(super) fn test_reader(reader: impl Read + Send + 'static) {
    TEST_READER.with(|slot| *slot.borrow_mut() = Some(Box::new(reader)));
}

// Test seam: the length of every copy buffer this thread allocated since the last read.
#[cfg(test)]
pub(super) fn test_take_buffers() -> Vec<usize> {
    BUFFERS.with(|v| std::mem::take(&mut *v.borrow_mut()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::testdir::TestDir;

    #[test]
    fn only_fuse_sources_take_the_read_worker() {
        let d = TestDir::new("copyreadclass");
        let src = d.file("source", "body");
        for magic in [None, Some(0xEF53), Some(0x01021994), Some(FUSE_MAGIC)] {
            let file = File::open(&src).unwrap();
            let mut reader = Reader::new(file, 4, magic).unwrap();
            assert_eq!(matches!(&reader.source, Source::Pending(_)), magic == Some(FUSE_MAGIC));
            let cancel = AtomicBool::new(false);
            assert_eq!(reader.read(&cancel).unwrap(), 4);
            assert_eq!(&reader.buffer[..4], b"body");
            assert_eq!(reader.read(&cancel).unwrap(), 0);
        }
    }
}
