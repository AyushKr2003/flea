// Bulk rename plan and execution, driven inside a sandbox directory.
use super::*;
use crate::backend::testdir::TestDir;

#[test]
fn a_swap_moves_through_temp_names_and_undo_puts_both_back() {
    let directory = TestDir::new("bulk-swap");
    let a = directory.file("a.txt", "aaa");
    let b = directory.file("b.txt", "bbb");
    let (items, unchanged) = plan(
        &[a.to_string_lossy().to_string(), b.to_string_lossy().to_string()],
        &["b.txt".to_string(), "a.txt".to_string()],
    ).unwrap();
    assert_eq!(unchanged, 0);
    let (steps, result) = execute(items);
    result.unwrap();
    assert_eq!(std::fs::read_to_string(directory.join("a.txt")).unwrap(), "bbb");
    assert_eq!(std::fs::read_to_string(directory.join("b.txt")).unwrap(), "aaa");
    assert!(steps.len() >= 3, "a swap needs a staging move: {:?}", steps);
}

#[test]
fn validation_is_whole_before_any_rename() {
    let directory = TestDir::new("bulk-whole");
    let a = directory.file("a.txt", "aaa");
    let b = directory.file("b.txt", "bbb");
    for names in [
        vec!["b.txt".to_string(), "b.txt".to_string()],
        vec!["".to_string(), "c.txt".to_string()],
        vec!["a/b".to_string(), "c.txt".to_string()],
    ] {
        let paths = vec![a.to_string_lossy().to_string(), b.to_string_lossy().to_string()];
        assert!(plan(&paths, &names).is_err());
        assert_eq!(std::fs::read_to_string(&a).unwrap(), "aaa");
        assert_eq!(std::fs::read_to_string(&b).unwrap(), "bbb");
    }
    // A destination outside the batch refuses while a swap through the batch does not.
    directory.file("taken.txt", "taken");
    let paths = vec![a.to_string_lossy().to_string(), b.to_string_lossy().to_string()];
    assert!(plan(&paths, &["taken.txt".to_string(), "c.txt".to_string()]).is_err());
    assert!(plan(&paths, &["b.txt".to_string(), "a.txt".to_string()]).is_ok());
}

fn strings(paths: &[&PathBuf]) -> Vec<String> {
    paths.iter().map(|path| path.to_string_lossy().to_string()).collect()
}

fn names(names: &[&str]) -> Vec<String> {
    names.iter().map(|name| name.to_string()).collect()
}

fn listing(directory: &TestDir) -> Vec<String> {
    let mut out: Vec<String> = std::fs::read_dir(directory.path()).unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().to_string())
        .filter(|name| name != ".flea-test-sandbox").collect();
    out.sort();
    out
}

fn run_batch(paths: &[&PathBuf], new_names: &[&str]) -> Vec<Step> {
    let (items, _) = plan(&strings(paths), &names(new_names)).unwrap();
    let (steps, result) = execute(items);
    result.unwrap();
    steps
}

#[test]
fn a_chain_lands_with_its_mover_listed_first() {
    let directory = TestDir::new("bulk-chain-mover");
    let a = directory.file("a.txt", "aaa");
    let b = directory.file("b.txt", "bbb");
    run_batch(&[&a, &b], &["b.txt", "c.txt"]);
    assert_eq!(listing(&directory), ["b.txt", "c.txt"]);
    assert_eq!(std::fs::read_to_string(directory.join("b.txt")).unwrap(), "aaa");
    assert_eq!(std::fs::read_to_string(directory.join("c.txt")).unwrap(), "bbb");
}

#[test]
fn a_chain_lands_with_its_occupant_listed_first() {
    let directory = TestDir::new("bulk-chain-occupant");
    let a = directory.file("a.txt", "aaa");
    let b = directory.file("b.txt", "bbb");
    run_batch(&[&b, &a], &["c.txt", "b.txt"]);
    assert_eq!(listing(&directory), ["b.txt", "c.txt"]);
    assert_eq!(std::fs::read_to_string(directory.join("b.txt")).unwrap(), "aaa");
    assert_eq!(std::fs::read_to_string(directory.join("c.txt")).unwrap(), "bbb");
}

#[test]
fn a_three_cycle_rotates_every_name() {
    let directory = TestDir::new("bulk-cycle3");
    let a = directory.file("a.txt", "aaa");
    let b = directory.file("b.txt", "bbb");
    let c = directory.file("c.txt", "ccc");
    run_batch(&[&a, &b, &c], &["b.txt", "c.txt", "a.txt"]);
    assert_eq!(listing(&directory), ["a.txt", "b.txt", "c.txt"]);
    assert_eq!(std::fs::read_to_string(directory.join("a.txt")).unwrap(), "ccc");
    assert_eq!(std::fs::read_to_string(directory.join("b.txt")).unwrap(), "aaa");
    assert_eq!(std::fs::read_to_string(directory.join("c.txt")).unwrap(), "bbb");
}

#[test]
fn a_partial_cycle_lands_beside_a_chain() {
    let directory = TestDir::new("bulk-partial");
    let a = directory.file("a.txt", "aaa");
    let b = directory.file("b.txt", "bbb");
    let c = directory.file("c.txt", "ccc");
    let e = directory.file("e.txt", "eee");
    run_batch(&[&e, &c, &a, &b], &["c.txt", "d.txt", "b.txt", "a.txt"]);
    assert_eq!(listing(&directory), ["a.txt", "b.txt", "c.txt", "d.txt"]);
    assert_eq!(std::fs::read_to_string(directory.join("a.txt")).unwrap(), "bbb");
    assert_eq!(std::fs::read_to_string(directory.join("b.txt")).unwrap(), "aaa");
    assert_eq!(std::fs::read_to_string(directory.join("c.txt")).unwrap(), "eee");
    assert_eq!(std::fs::read_to_string(directory.join("d.txt")).unwrap(), "ccc");
}

#[test]
fn a_source_replaced_after_the_plan_refuses_the_whole_batch() {
    let directory = TestDir::new("bulk-replaced");
    let a = directory.file("a.txt", "aaa");
    let b = directory.file("b.txt", "bbb");
    let (items, _) = plan(&strings(&[&a, &b]), &names(&["x.txt", "y.txt"])).unwrap();
    let other = directory.file("other.txt", "new");
    std::fs::rename(&other, &b).unwrap();
    let (steps, result) = execute(items);
    assert_eq!(result.unwrap_err().path, b.to_string_lossy(), "the refusal names the replaced item");
    assert!(steps.is_empty());
    assert_eq!(listing(&directory), ["a.txt", "b.txt"]);
    assert_eq!(std::fs::read_to_string(&b).unwrap(), "new");
}

#[test]
fn a_source_gone_before_the_plan_is_named_in_the_refusal() {
    let directory = TestDir::new("bulk-gone");
    let a = directory.file("a.txt", "aaa");
    let gone = directory.join("gone.txt");
    let refused = plan(&strings(&[&a, &gone]), &names(&["x.txt", "y.txt"])).err().expect("a missing source refuses the plan");
    assert_eq!(refused.path, gone.to_string_lossy(), "the refusal names the missing item");
}

#[test]
fn a_landed_rename_keeps_its_step_when_the_identity_read_fails() {
    let directory = TestDir::new("bulk-inspect");
    let a = directory.file("a.txt", "aaa");
    let before = ItemIdentity::inspect(&a).unwrap();
    let to = directory.join("z.txt");
    let step = move_one_with(&a, &to, before.clone(), |_| Err(refused("the drive did not answer"))).unwrap();
    assert_eq!(std::fs::read_to_string(&to).unwrap(), "aaa");
    match step {
        Step::Moved { from, to: landed, before: was, after } => {
            assert_eq!((from, landed), (a.clone(), to.clone()));
            assert!(was.same_item(&after));
        }
        other => panic!("expected a Moved step: {:?}", other),
    }
}

#[test]
fn an_unchanged_name_is_counted_and_records_nothing() {
    let directory = TestDir::new("bulk-unchanged");
    let a = directory.file("a.txt", "aaa");
    let paths = vec![a.to_string_lossy().to_string()];
    let (items, unchanged) = plan(&paths, &["a.txt".to_string()]).unwrap();
    assert!(items.is_empty());
    assert_eq!(unchanged, 1);
}
