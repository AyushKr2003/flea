// The words a refused LocalSend run shows; each pins the sentence a person reads, not the branch that raises it.
use super::*;

// A write the terminal's input side refuses is the CLI no longer answering, not a fault in a terminal.
#[test]
fn a_key_that_cannot_be_written_says_localsend_stopped_answering() {
    let unwritable = OwnedFd::from(std::fs::File::open("/dev/null").expect("/dev/null"));
    let error = press(&unwritable, KEY_ENTER).unwrap_err();
    assert!(error.starts_with("LocalSend stopped answering: ") && error.ends_with('.') && !error.contains("CLI"), "{}", error);
}

// Lines no fixture reaches (a pty that will not open, a descriptor that will not clone) are pinned by their source.
#[test]
fn retired_localsend_wording_is_gone_from_the_live_source() {
    let live = include_str!("localsend.rs").split("\n#[cfg(test)]\nmod tests").next().unwrap();
    for retired in ["its own CLI", "for its own", "terminal setup failed", "could not reach", "its own terminal", "could not name the terminal",
                    "could not size the terminal", "could not prepare a terminal", "could not open a terminal", "could not open {}"] {
        assert!(!live.contains(retired), "retired wording came back: {}", retired);
    }
    assert_eq!(live.matches("LocalSend could not start: {}.").count(), 6, "the pty, its three clones and the two master clones");
    assert_eq!(live.matches("LocalSend stopped answering: {}.").count(), 3, "the three key writes");
    assert!(live.contains("LocalSend stopped before sending to {}."));
    assert_eq!(live.matches("Err(NOT_STARTED.into())").count(), 4, "the four bare pty setup refusals");
    assert!(live.contains("const NOT_STARTED: &str = \"LocalSend could not start.\";"));
}
