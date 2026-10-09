use super::graphics::Protocol;
use crate::{backend::regfile, oflags::O_NOFOLLOW};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::{fd::AsRawFd, unix::fs::MetadataExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

// One mpv for one preview: the child, the private directory that holds its IPC socket, and the file it reads.
pub struct Process {
    pub child: Child,
    pub directory: PathBuf,
    _input: File,
}
impl Process {
    pub fn spawn(
        path: &Path,
        protocol: Protocol,
        geometry: (usize, usize, usize, usize),
        terminal_size: (usize, usize),
        pixels: (usize, usize),
    ) -> io::Result<Self> {
        let before = fs::symlink_metadata(path)?;
        let input = regfile::open_if_regular(path, O_NOFOLLOW)?;
        let after = input.metadata()?;
        if before.dev() != after.dev() || before.ino() != after.ino() {
            return Err(io::Error::other("Selected item changed"));
        }
        let directory = temporary()?;
        let endpoint = directory.join("ipc");
        let mut command = Command::new("mpv");
        command
            .args(arguments(protocol, &endpoint, geometry, terminal_size, pixels))
            .arg("--")
            .arg(format!(
                "/proc/{}/fd/{}",
                std::process::id(),
                input.as_raw_fd()
            ))
            .stdin(Stdio::null())
            .stdout(Stdio::inherit())
            .stderr(Stdio::null());
        match command.spawn() {
            Ok(child) => Ok(Self { child, directory, _input: input }),
            Err(error) => {
                cleanup(&directory);
                Err(error)
            }
        }
    }
}
impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        cleanup(&self.directory);
    }
}
// mpv's options before the input: paused on the first frame, and drawing into the preview pane without clearing the screen around it.
fn arguments(
    protocol: Protocol,
    endpoint: &Path,
    geometry: (usize, usize, usize, usize),
    terminal_size: (usize, usize),
    pixels: (usize, usize),
) -> Vec<String> {
    let driver = match protocol {
        Protocol::Kitty => "kitty",
        Protocol::Sixel => "sixel",
        Protocol::None => "null",
    };
    let mut args: Vec<String> = [
        "--no-config",
        "--load-scripts=no",
        "--ytdl=no",
        "--pause=yes",
        "--keep-open=yes",
        "--terminal=no",
        "--input-default-bindings=no",
        "--input-vo-keyboard=no",
        "--force-window=no",
        "--osc=no",
        "--osd-level=0",
    ]
    .iter()
    .map(|arg| arg.to_string())
    .collect();
    args.push(format!("--vo={}", driver));
    args.push(format!("--input-ipc-server={}", endpoint.display()));
    if driver != "null" {
        for (option, value) in [
            ("cols", terminal_size.0),
            ("rows", terminal_size.1),
            ("width", pixels.0),
            ("height", pixels.1),
            ("left", geometry.2),
            ("top", geometry.3),
        ] {
            args.push(format!("--vo-{}-{}={}", driver, option, value));
        }
        args.push(format!("--vo-{}-alt-screen=no", driver));
        // The driver clears the whole terminal at each reconfigure by default, a blank frame under the listing.
        args.push(format!("--vo-{}-config-clear=no", driver));
    }
    args
}
fn temporary() -> io::Result<PathBuf> {
    let output = Command::new("mktemp")
        .args(["-d", "/tmp/flea-tui-XXXXXX"])
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other(
            "Could not create preview socket directory",
        ));
    }
    let path = PathBuf::from(String::from_utf8_lossy(&output.stdout).trim());
    if !path.is_absolute()
        || path.parent() != Some(Path::new("/tmp"))
        || !path
            .file_name()
            .is_some_and(|p| p.to_string_lossy().starts_with("flea-tui-"))
    {
        return Err(io::Error::other(
            "Preview socket directory is outside its sandbox",
        ));
    }
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path.join(".flea-tui-owned"))?
        .write_all(b"flea")?;
    Ok(path)
}
fn cleanup(root: &Path) {
    if !root.is_absolute()
        || root.parent() != Some(Path::new("/tmp"))
        || !root
            .file_name()
            .is_some_and(|p| p.to_string_lossy().starts_with("flea-tui-"))
        || !fs::symlink_metadata(root).is_ok_and(|m| m.file_type().is_dir())
        || fs::read(root.join(".flea-tui-owned")).ok().as_deref() != Some(b"flea")
    {
        return;
    }
    for name in ["ipc", ".flea-tui-owned"] {
        let path = root.join(name);
        if path.is_absolute() && path.starts_with(root) && path != root {
            let _ = fs::remove_file(path);
        }
    }
    let _ = fs::remove_dir(root);
}
#[cfg(test)]
#[path = "mpv_tests.rs"]
mod tests;
