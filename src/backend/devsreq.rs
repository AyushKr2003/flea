// The device of each path the client names, symlinks followed; see docs/protocol.md "devs".
use super::fsinfo::dev_of;
use super::iomount;
use super::opsreq::OpMsg;
use crate::json::escape;
use std::path::PathBuf;
use std::sync::mpsc::Sender;

// Answered on its own thread: a stat through a mount that stopped answering never returns, and the loop never waits on one.
pub fn request(paths: Vec<String>, replies: Sender<OpMsg>) {
    std::thread::spawn(move || {
        let _ = replies.send(OpMsg::Meta { line: answer(&paths, &iomount::mount_body()) });
    });
}

// Sample output: {"t":"devs","devs":{"/":66305,"/home":66306,"/gone":0}}, each asked path once, in the order asked.
fn answer(paths: &[String], body: &str) -> String {
    let mut seen = std::collections::HashSet::new();
    let devs: Vec<String> = paths.iter().filter(|path| seen.insert(path.as_str()))
        .map(|path| format!(r#""{}":{}"#, escape(path), device(path, body))).collect();
    format!(r#"{{"t":"devs","devs":{{{}}}}}"#, devs.join(","))
}

// 0 where the stat fails or the mount does not answer in time, and for a relative path, which names this process's own directory and nothing the client means.
fn device(path: &str, body: &str) -> u64 {
    if !path.starts_with('/') {
        return 0;
    }
    let owned = PathBuf::from(path);
    let target = owned.clone();
    iomount::call(&owned, body, "devs", move || dev_of(&target)).unwrap_or(0)
}

#[cfg(test)]
#[path = "devsreq_tests.rs"]
mod tests;
