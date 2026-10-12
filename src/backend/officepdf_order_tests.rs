use super::*;

#[test]
fn an_older_request_that_finishes_its_probe_last_is_replaced_and_the_newer_stays_queued() {
    let d = TestDir::new("officepdf-order");
    let (mut r, (open_tx, open_rx)) = (rig(&d, GATED, CONVERT_TIMEOUT), channel::<()>());
    let (gate_rx, entered) = (Mutex::new(open_rx), Arc::new(AtomicUsize::new(0)));
    let seen = Arc::clone(&entered);
    // The second probe to start is the older request's, and it waits here.
    Arc::get_mut(&mut r.svc).unwrap().resolve = Box::new(move || {
        if seen.fetch_add(1, Ordering::SeqCst) == 1 {
            let _ = gate_rx.lock().unwrap().recv_timeout(Duration::from_secs(10));
        }
        Some("/usr/bin/sh".to_string())
    });
    let gate = d.join("x.docx");
    mkfifo(&gate);
    let (older, newer) = (d.file("older.docx", "o"), d.file("newer.docx", "n"));
    assert_eq!(r.ask(1, &gate), converting_line(1));
    r.svc.start(2, 2, older, r.tx.clone());
    while entered.load(Ordering::SeqCst) < 2 {
        std::thread::sleep(Duration::from_millis(5));
    }
    r.svc.start(3, 3, newer, r.tx.clone());
    assert!(matches!(r.rx.recv_timeout(BOUND), Ok(OpMsg::Meta { line }) if line == converting_line(3)));
    open_tx.send(()).unwrap();
    assert!(matches!(r.rx.recv_timeout(BOUND), Ok(OpMsg::Meta { line }) if line == converting_line(2)));
    let (reg, line) = r.end();
    assert!(reg == 2 && line.contains(r#""state":"failed""#) && line.contains("replaced"), "the older request is the replaced one: {reg} {line}");
    within("the gate opens", move || drop(std::fs::OpenOptions::new().write(true).open(&gate).unwrap()));
    let mut ends = vec![r.end(), r.end()];
    ends.sort();
    assert_eq!(ends.iter().map(|e| e.0).collect::<Vec<_>>(), vec![1, 3]);
    assert!(ends.iter().all(|e| e.1.contains(r#""state":"ready""#)), "{ends:?}");
    assert_eq!(r.jobs(), 2, "the older request never ran");
}

#[test]
fn the_conversion_takes_the_canonical_input_the_probe_resolved() {
    let d = TestDir::new("officepdf-canonical");
    let mut r = rig(&d, MAKE_PDF, CONVERT_TIMEOUT);
    let (real, link) = (d.file("real.docx", "doc"), d.join("link.docx"));
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let inputs = Arc::new(Mutex::new(Vec::new()));
    let seen = Arc::clone(&inputs);
    let build: Build = Box::new(move |_, input, out| {
        seen.lock().unwrap().push(input.to_path_buf());
        ["/usr/bin/sh", "-c", MAKE_PDF, "sh", &input.to_string_lossy(), &out.to_string_lossy()].iter().map(|s| s.to_string()).collect()
    });
    r.svc = Arc::new(Service::new(Store::new(&r.cache), Box::new(|| Some("/usr/bin/sh".to_string())), build, Box::new(unjailed), CONVERT_TIMEOUT));
    r.ask(1, &link);
    r.end();
    assert_eq!(*inputs.lock().unwrap(), vec![std::fs::canonicalize(&real).unwrap()]);
}

#[test]
fn the_conversion_makes_no_path_call_of_its_own() {
    let d = TestDir::new("officepdf-no-path-call");
    let r = rig(&d, MAKE_PDF, CONVERT_TIMEOUT);
    let absent = d.join("resolved-by-the-probe.docx");
    let job = Job { key: "k".repeat(KEY_HEX_CHARS), program: "/usr/bin/sh".into(), input: absent, mtime: SystemTime::UNIX_EPOCH, seq: 0, waiters: Vec::new() };
    assert!(r.svc.convert(&job).is_ok(), "an input the job already carries needs no second resolve");
    assert_eq!(r.jobs(), 1);
}
