use super::*;
use crate::backend::testdir::TestDir;
use std::fs::{File, FileTimes};

fn saved(d: &TestDir, resources: &str) -> PathBuf {
    let png = d.join("cached.png");
    let bytes = record(resources, d.path(), SystemTime::now() + Duration::from_secs(1)).unwrap();
    std::fs::write(sidecar(&png), bytes).unwrap();
    png
}

#[test]
fn engine_resources_record_nested_styles_images_fonts_and_encoded_names() {
    let d = TestDir::new("html-dependencies");
    d.dir("sub");
    for name in ["sub/style.css", "image #?.png", "font.woff"] { d.file(name, "data"); }
    let png = saved(&d, r#"{"resources":["file:///page/sub/style.css","file:///page/image%20%23%3F.png","file:///page/font.woff","data:image/png;base64,abc"],"overflow":false}"#);
    assert!(unchanged(&png, d.path()));
    let document = jsondoc::parse(&std::fs::read_to_string(sidecar(&png)).unwrap()).unwrap();
    assert_eq!(document.get("dependencies").unwrap().as_array().unwrap().len(), 3);
    d.replace_file(&d.join("sub/style.css"), "new!");
    assert!(!unchanged(&png, d.path()));
}

#[test]
fn each_size_nanosecond_mtime_and_inode_change_invalidates_the_record() {
    let d = TestDir::new("html-dependency-stamps");
    let css = d.file("style.css", "old!");
    let stamp = SystemTime::UNIX_EPOCH + Duration::new(9, 20);
    let resources = r#"{"resources":["file:///page/style.css"],"overflow":false}"#;
    for change in ["size", "seconds", "nanoseconds", "inode"] {
        std::fs::write(&css, "old!").unwrap();
        File::open(&css).unwrap().set_times(FileTimes::new().set_modified(stamp)).unwrap();
        let png = saved(&d, resources);
        assert!(unchanged(&png, d.path()));
        match change {
            "size" => { std::fs::write(&css, "longer").unwrap(); File::open(&css).unwrap().set_times(FileTimes::new().set_modified(stamp)).unwrap(); }
            "seconds" => File::open(&css).unwrap().set_times(FileTimes::new().set_modified(stamp + Duration::from_secs(1))).unwrap(),
            "nanoseconds" => File::open(&css).unwrap().set_times(FileTimes::new().set_modified(stamp + Duration::from_nanos(1))).unwrap(),
            _ => { d.replace_file(&css, "new!"); File::open(&css).unwrap().set_times(FileTimes::new().set_modified(stamp)).unwrap(); }
        }
        assert!(!unchanged(&png, d.path()), "{change} must invalidate");
    }
}

#[test]
fn missing_malformed_oversized_and_escaping_records_are_misses() {
    let d = TestDir::new("html-dependency-records");
    let png = d.join("cached.png");
    assert!(!unchanged(&png, d.path()));
    for bad in ["null".to_string(), "{}".into(), "x".repeat(MAX_RECORD_BYTES + 1),
        r#"{"version":1,"dependencies":[["../outside",1,2,3,4,5]]}"#.into(),
        r#"{"version":1,"dependencies":[["missing",1,2,3,4,5]]}"#.into()] {
        std::fs::write(sidecar(&png), bad).unwrap();
        assert!(!unchanged(&png, d.path()));
    }
    let outside = TestDir::new("html-dependency-outside");
    let target = outside.file("other.css", "data");
    std::os::unix::fs::symlink(target, d.join("escape.css")).unwrap();
    assert!(record(r#"{"resources":["file:///page/escape.css"],"overflow":false}"#, d.path(), SystemTime::now()).is_none());
}

#[test]
fn overflow_and_edits_during_render_disable_reuse() {
    let d = TestDir::new("html-dependency-bounds");
    let started = SystemTime::UNIX_EPOCH;
    d.file("style.css", "data");
    let resources = r#"{"resources":["file:///page/style.css"],"overflow":false}"#;
    assert!(record(resources, d.path(), started).is_none());
    assert!(record(r#"{"resources":[],"overflow":true}"#, d.path(), SystemTime::now()).is_none());
    let urls = vec![Json::Str("file:///page/style.css".into()); MAX_RESOURCES + 1];
    let document = Json::Obj(vec![("resources".into(), Json::Arr(urls)), ("overflow".into(), Json::Bool(false))]);
    assert!(record(&jsondoc::render(&document), d.path(), SystemTime::now()).is_none());
    let rows = vec![Json::Arr(vec![Json::Str("style.css".into()), number(4), number(1), number(0), number(1), number(1)]); MAX_RESOURCES + 1];
    let document = Json::Obj(vec![("version".into(), number(1)), ("dependencies".into(), Json::Arr(rows))]);
    let png = d.join("cached.png");
    std::fs::write(sidecar(&png), jsondoc::render(&document)).unwrap();
    assert!(!unchanged(&png, d.path()));
    assert!(record(&" ".repeat(MAX_RECORD_BYTES + 1), d.path(), SystemTime::now()).is_none());
}
