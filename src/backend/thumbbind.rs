use crate::backend::manifestdir::current_uid;
use crate::backend::sandbox;
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path};

// The jail mounts /usr and /etc and links these four names into usr, so a program under any of them is in reach already.
const JAIL_ROOTS: [&str; 6] = ["/usr", "/etc", "/bin", "/sbin", "/lib", "/lib64"];
// Only these two are real mounts, so a link that leaves them has to bind its own target.
const MOUNTED: [&str; 2] = ["/usr", "/etc"];
// The jail mounts these itself, and a bind must never shadow them.
const KERNEL: [&str; 3] = ["/proc", "/dev", "/sys"];
const ANY_EXECUTE_BIT: u32 = 0o111;
const GROUP_OR_OTHER_WRITE: u32 = 0o022;

// The decoder's jail for one job plus the read-only bind that puts its program in reach; None refuses the job. See AGENTS.md "Thumbnail sandbox".
pub fn wrap(inner: &[String], input: &Path, output: &Path) -> Option<Vec<String>> {
    let binds = program_binds(Path::new(inner.first()?), input, output)?;
    let mut argv = sandbox::wrap(inner, input, output);
    let at = argv.len() - inner.len();
    argv.splice(at..at, binds);
    sandbox::add_status(&mut argv, inner.len());
    Some(argv)
}

// Sample answers: "/usr/bin/convert" gives no argument, "/home/u/.local/bin/t" gives "--ro-bind <target> /home/u/.local/bin/t".
fn program_binds(program: &Path, input: &Path, output: &Path) -> Option<Vec<String>> {
    if !program.is_absolute() || program.components().any(|c| c == Component::ParentDir) {
        return None;
    }
    let target = std::fs::canonicalize(program).ok()?;
    let args = rows(program, &target);
    if args.is_empty() {
        return Some(args);
    }
    let clear = |p: &Path| !within(p, &KERNEL) && p != input && p != output;
    let meta = std::fs::metadata(&target).ok()?;
    (trusted(&meta, current_uid()) && clear(program) && clear(&target)).then_some(args)
}

// The bind arguments by path alone: a program the jail reaches binds nothing, a link out of /usr binds its target, and any other path gets the target under the program's own name.
fn rows(program: &Path, target: &Path) -> Vec<String> {
    let inside = within(program, &JAIL_ROOTS);
    if inside && within(target, &MOUNTED) {
        return Vec::new();
    }
    let at = if inside { target } else { program };
    vec!["--ro-bind".to_string(), target.to_string_lossy().to_string(), at.to_string_lossy().to_string()]
}

// A regular executable that only root or this user can have written, so the bind hands the jail nothing a stranger shaped.
fn trusted(meta: &std::fs::Metadata, me: u32) -> bool {
    let mode = meta.mode();
    meta.is_file() && mode & ANY_EXECUTE_BIT != 0 && mode & GROUP_OR_OTHER_WRITE == 0 && (meta.uid() == 0 || meta.uid() == me)
}

fn within(path: &Path, roots: &[&str]) -> bool {
    roots.iter().any(|r| path.starts_with(r))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::testdir::TestDir;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;

    const INPUT: &str = "/in/a.url";
    const OUTPUT: &str = "/out/t.png";

    fn exec_file(path: &Path, mode: u32) -> PathBuf {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, b"#!/bin/sh\n").unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
        path.to_path_buf()
    }

    fn binds_for(program: &Path) -> Option<Vec<String>> {
        program_binds(program, Path::new(INPUT), Path::new(OUTPUT))
    }

    fn strings(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn a_program_the_jail_reaches_binds_nothing() {
        assert_eq!(rows(Path::new("/usr/bin/convert"), Path::new("/usr/bin/convert")), Vec::<String>::new());
        assert_eq!(rows(Path::new("/bin/sh"), Path::new("/usr/bin/bash")), Vec::<String>::new());
        assert_eq!(binds_for(Path::new("/usr/bin/sh")), Some(Vec::new()));
    }

    #[test]
    fn a_link_out_of_usr_binds_its_target_at_itself() {
        assert_eq!(rows(Path::new("/usr/bin/t"), Path::new("/opt/t/bin/t")), strings(&["--ro-bind", "/opt/t/bin/t", "/opt/t/bin/t"]));
    }

    #[test]
    fn a_program_outside_usr_binds_its_target_under_its_own_name() {
        assert_eq!(rows(Path::new("/home/u/.local/bin/t"), Path::new("/home/u/.local/bin/t")),
                   strings(&["--ro-bind", "/home/u/.local/bin/t", "/home/u/.local/bin/t"]));
        assert_eq!(rows(Path::new("/home/u/bin/t"), Path::new("/usr/bin/t")), strings(&["--ro-bind", "/usr/bin/t", "/home/u/bin/t"]));
    }

    #[test]
    fn a_symlinked_program_binds_its_target_at_the_link_path() {
        let d = TestDir::new("thumbbind-link");
        let real = exec_file(&d.join("real/tool"), 0o755);
        std::fs::create_dir_all(d.join("link")).unwrap();
        let link = d.join("link/tool");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let want = strings(&["--ro-bind", &real.to_string_lossy(), &link.to_string_lossy()]);
        assert_eq!(binds_for(&link), Some(want.clone()));
        let inner = vec![link.to_string_lossy().to_string(), "%i".to_string()];
        let argv = wrap(&inner, Path::new(INPUT), Path::new(OUTPUT)).unwrap();
        assert!(argv.windows(3).any(|w| w == want.as_slice()), "the target is not bound at the link: {:?}", argv);
        assert_eq!(argv[argv.len() - 2], link.to_string_lossy(), "argv[0] is still the link path");
    }

    #[test]
    fn a_program_that_is_not_a_trusted_executable_file_is_refused() {
        let d = TestDir::new("thumbbind-refuse");
        let plain = exec_file(&d.join("plain"), 0o755);
        assert!(binds_for(&plain).is_some(), "the control: a private executable binds");
        assert_eq!(binds_for(&d.join("sub-dir")), None, "a missing path");
        std::fs::create_dir_all(d.join("a-directory")).unwrap();
        assert_eq!(binds_for(&d.join("a-directory")), None, "a directory");
        assert_eq!(binds_for(&exec_file(&d.join("no-exec"), 0o644)), None, "no execute bit");
        assert_eq!(binds_for(&exec_file(&d.join("group-writable"), 0o775)), None, "group writable");
        assert_eq!(binds_for(&exec_file(&d.join("world-writable"), 0o757)), None, "world writable");
    }

    #[test]
    fn only_root_and_this_user_own_a_bound_program() {
        let d = TestDir::new("thumbbind-owner");
        let meta = std::fs::metadata(exec_file(&d.join("mine"), 0o755)).unwrap();
        assert!(trusted(&meta, meta.uid()));
        if meta.uid() != 0 {
            assert!(!trusted(&meta, meta.uid().wrapping_add(1)), "another user's file");
        }
        assert!(trusted(&std::fs::metadata("/usr/bin/sh").unwrap(), 4_000_000), "root's file is trusted whoever asks");
    }

    #[test]
    fn a_kernel_path_is_never_bound() {
        assert_eq!(binds_for(Path::new("/proc/self/exe")), None);
        for p in ["/proc/1/x", "/dev/shm/x", "/sys/x"] {
            assert!(within(Path::new(p), &KERNEL), "{}", p);
        }
        assert!(!within(Path::new("/procession/x"), &KERNEL), "whole components only");
    }

    #[test]
    fn a_program_that_is_the_input_or_the_output_is_refused() {
        let d = TestDir::new("thumbbind-same");
        let tool = exec_file(&d.join("tool"), 0o755);
        assert!(program_binds(&tool, Path::new(INPUT), Path::new(OUTPUT)).is_some());
        assert_eq!(program_binds(&tool, &tool, Path::new(OUTPUT)), None, "the input");
        assert_eq!(program_binds(&tool, Path::new(INPUT), &tool), None, "the output");
    }

    #[test]
    fn a_relative_or_dotted_program_path_is_refused() {
        let d = TestDir::new("thumbbind-relative");
        let tool = exec_file(&d.join("sub/tool"), 0o755);
        assert_eq!(binds_for(Path::new("tool")), None);
        assert_eq!(binds_for(&d.join("sub/../sub/tool")), None);
        assert!(binds_for(&tool).is_some());
    }

    #[test]
    fn the_jail_keeps_exactly_one_writable_bind_and_the_inner_argv_last() {
        let d = TestDir::new("thumbbind-argv");
        let tool = exec_file(&d.join("bin/tool"), 0o755);
        let inner = vec![tool.to_string_lossy().to_string(), INPUT.to_string(), OUTPUT.to_string(), "256".to_string()];
        let argv = wrap(&inner, Path::new(INPUT), Path::new(OUTPUT)).unwrap();
        assert_eq!(argv.iter().filter(|a| a.as_str() == "--bind").count(), 1);
        assert_eq!(&argv[argv.len() - inner.len()..], inner.as_slice());
        let status = argv.iter().position(|a| a == "--json-status-fd").unwrap();
        let bound = argv.windows(2).position(|w| w[0] == "--ro-bind" && w[1] == tool.to_string_lossy()).unwrap();
        assert!(bound < status, "the program bind sits before the status flag and the inner argv");
        assert_eq!(argv[0], "prlimit");
    }

    #[test]
    fn a_program_in_usr_gets_the_unchanged_jail_and_an_empty_inner_argv_is_refused() {
        let inner = vec!["/usr/bin/sh".to_string(), "-c".to_string(), "true".to_string()];
        let mut want = sandbox::wrap(&inner, Path::new(INPUT), Path::new(OUTPUT));
        sandbox::add_status(&mut want, inner.len());
        assert_eq!(wrap(&inner, Path::new(INPUT), Path::new(OUTPUT)), Some(want));
        assert_eq!(wrap(&[], Path::new(INPUT), Path::new(OUTPUT)), None);
    }
}
