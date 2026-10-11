use super::*;

#[test]
fn ascii_stops_at_nul_and_trims_spaces() {
    assert_eq!(ascii(b"Canon\0\0\0"), "Canon");
    assert_eq!(ascii(b"NIKON   "), "NIKON");
    assert_eq!(ascii(b""), "");
    assert_eq!(ascii(b"\0hidden"), "");
}

#[test]
fn ascii_caps_at_64_bytes_on_a_char_boundary() {
    let long = vec![b'A'; 200];
    assert_eq!(ascii(&long).len(), 64);
    let mut multi = vec![b'B'; 63];
    multi.extend_from_slice("é".as_bytes());
    multi.extend_from_slice(b"tail");
    let s = ascii(&multi);
    assert!(s.len() <= 64 && s != "", "cut before the two-byte é, never through it");
    assert!(String::from_utf8(s.into_bytes()).is_ok());
}

#[test]
fn ascii_replaces_non_utf8_lossily() {
    let s = ascii(b"ab\xFFcd\0");
    assert_eq!(s, "ab\u{FFFD}cd");
}

#[test]
fn rational_reads_both_orders() {
    let le = [0x28, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x00];
    assert_eq!(rational(&le, true), Some((40, 10)));
    let be = [0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x0A];
    assert_eq!(rational(&be, false), Some((40, 10)));
    assert_eq!(rational(&le[..7], true), None, "a short read is None, not a panic");
}

#[test]
fn small_reads_short_and_long_first_values() {
    assert_eq!(small(&[0x06, 0x00, 0x00, 0x00], 3, true), Some(6));
    assert_eq!(small(&[0x00, 0x06, 0x00, 0x00], 3, false), Some(6));
    assert_eq!(small(&[0x64, 0x00, 0x00, 0x00], 4, true), Some(100));
    assert_eq!(small(&[0x01], 3, true), None);
    assert_eq!(small(&[0x01, 0x00, 0x00, 0x00], 5, true), None, "a rational is not a small");
}

#[test]
fn type_size_covers_the_tiff_table_and_refuses_the_rest() {
    for t in [1u16, 2, 6, 7] {
        assert_eq!(type_size(t), Some(1));
    }
    for t in [3u16, 8] {
        assert_eq!(type_size(t), Some(2));
    }
    for t in [4u16, 9, 11] {
        assert_eq!(type_size(t), Some(4));
    }
    for t in [5u16, 10, 12] {
        assert_eq!(type_size(t), Some(8));
    }
    assert_eq!(type_size(0), None);
    assert_eq!(type_size(13), None);
    assert_eq!(type_size(0xFFFF), None);
}
