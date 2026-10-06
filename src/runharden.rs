// The run child's hardening (R6): no Flea descriptor above fd 2 and none of its private variables reach a program the card starts; terminal::detach keeps the rest.
use std::ffi::OsString;
use std::os::raw::c_int;
use std::os::unix::process::CommandExt;

// Every Flea-private variable starts here; the child keeps PATH, HOME, the session bus and the rest of the operator's environment.
const PRIVATE_ENV_PREFIX: &[u8] = b"FLEA_";

extern "C" {
    fn close_range(first: u32, last: u32, flags: c_int) -> c_int;
    fn close(fd: c_int) -> c_int;
}

// Best effort after the fork: close_range is kernel 5.9 and the loop covers older ones.
fn close_inherited() -> std::io::Result<()> {
    let fell_back = unsafe { close_range(3, u32::MAX, 0) } != 0;
    if fell_back {
        let mut fd: c_int = 3;
        while fd < 1024 {
            unsafe {
                close(fd);
            }
            fd += 1;
        }
    }
    Ok(())
}

// Strips the private variables off the spawn and closes every inherited descriptor above 2 in the child; Rust dups 0, 1 and 2 before pre_exec runs, so those survive.
pub fn harden(child: &mut std::process::Command) {
    let doomed: Vec<OsString> = std::env::vars_os()
        .map(|(key, _)| key)
        .filter(|key| key.as_encoded_bytes().starts_with(PRIVATE_ENV_PREFIX))
        .collect();
    for key in doomed {
        child.env_remove(key);
    }
    unsafe {
        child.pre_exec(close_inherited);
    }
}
