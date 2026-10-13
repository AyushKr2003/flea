use crate::json::{field_bool, field_str};

// Only raw table requests align records; csv "," and "\t" select their field separator.
// Sample input: delimiter(r#"{"csv":",","raw":false}"#) returns None.
pub fn delimiter(request: &str) -> Option<u8> {
    if !field_bool(request, "raw") {
        return None;
    }
    match field_str(request, "csv").as_deref() {
        Some(",") => Some(b','),
        Some("\t") => Some(b'\t'),
        _ => None,
    }
}

// Expand the physical-line window to whole RFC 4180 records, scanning the bytes the code request already holds.
// Sample input: align(b"id,note\n1,\"two\nlines\",9\n2,last\n", 3, 1, b',') returns (2, 2).
pub fn align(data: &[u8], first: usize, count: usize, delim: u8) -> (usize, usize) {
    let wanted_end = first.saturating_add(count.saturating_sub(1));
    let mut line = 1;
    let mut record_first = 1;
    let mut aligned_first = None;
    let mut quoted = false;
    let mut field_start = true;
    let mut at = 0;
    while at < data.len() {
        let byte = data[at];
        if byte == b'\n' {
            if !quoted {
                if aligned_first.is_none() && line >= first {
                    aligned_first = Some(record_first);
                }
                if line >= wanted_end {
                    let start = aligned_first.unwrap_or(first);
                    return (start, line - start + 1);
                }
                record_first = line + 1;
                field_start = true;
            }
            line += 1;
        } else if quoted {
            if byte == b'"' {
                if data.get(at + 1) == Some(&b'"') {
                    at += 1;
                } else {
                    quoted = false;
                }
            }
        } else if byte == delim {
            field_start = true;
        } else {
            if byte == b'"' && field_start {
                quoted = true;
            }
            field_start = false;
        }
        at += 1;
    }
    let last = line - usize::from(data.is_empty() || data.ends_with(b"\n"));
    if first > last {
        return (first, 0);
    }
    let start = aligned_first.unwrap_or(record_first);
    (start, last - start + 1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::super::{plain, Ask};
    use crate::json::escape;
    use crate::jsondoc::{parse, Json};

    fn reply(data: &str, first: usize, count: usize, csv: &str) -> Json {
        let request = Ask::parse(&format!(
            r#"{{"text":"{}","raw":true,"csv":"{}","first":{first},"count":{count}}}"#,
            escape(data), escape(csv)
        ));
        parse(&plain(&request, data.as_bytes())).unwrap()
    }

    fn window(reply: &Json) -> (usize, usize) {
        (reply.get("first").and_then(Json::as_f64).unwrap() as usize,
         reply.get("lines").and_then(Json::as_array).unwrap().len())
    }

    #[test]
    fn code_csv_moves_first_back_inside_a_quoted_newline() {
        let data = "id,note\n1,\"two\nlines\",9\n2,last\n";
        assert_eq!(window(&reply(data, 3, 1, ",")), (2, 2));
        assert_eq!(window(&reply(data, 2, 1, ",")), (2, 2));
    }

    #[test]
    fn code_csv_continues_past_line_cap_to_a_record_end() {
        let data = format!("id,note\n1,\"open\n{}closed\",9\n2,last\n", "still\n".repeat(500));
        assert_eq!(window(&reply(&data, 1, 400, ",")), (1, 503));
    }

    #[test]
    fn code_csv_unterminated_quote_extends_to_file_end() {
        for data in ["id,note\n1,\"open\nstill", "id,note\n1,\"open\nstill\n"] {
            assert_eq!(window(&reply(data, 3, 1, ",")), (2, 2));
            assert_eq!(window(&reply(data, 1, 2, ",")), (1, 3));
        }
    }

    #[test]
    fn code_csv_doubled_quotes_keep_the_quoted_field_open() {
        let data = "id,note\n1,\"say \"\"hi\"\"\nnext\",9\n2,last\n";
        assert_eq!(window(&reply(data, 3, 1, ",")), (2, 2));
    }

    #[test]
    fn code_csv_a_quote_inside_an_unquoted_field_is_literal() {
        let data = "id,note\n1,5\" disk\n2,last\n";
        assert_eq!(window(&reply(data, 2, 1, ",")), (2, 1));
        assert_eq!(window(&reply(data, 3, 1, ",")), (3, 1));
    }

    #[test]
    fn code_csv_tsv_opens_quotes_after_tabs_and_keeps_commas_literal() {
        let data = "id\tnote\n1\t\"two\nlines\"\t9\n2,\"literal\tlast\n3\tdone\n";
        assert_eq!(window(&reply(data, 3, 1, "\t")), (2, 2));
        assert_eq!(window(&reply(data, 4, 1, "\t")), (4, 1));
    }

    #[test]
    fn code_csv_plain_requests_and_invalid_delimiters_keep_the_old_window() {
        let data = "id,note\n1,\"two\nlines\",9\n";
        for csv in ["", "|", "comma"] {
            assert_eq!(window(&reply(data, 3, 1, csv)), (3, 1));
        }
        assert_eq!(delimiter(r#"{"csv":",","raw":false}"#), None);
        assert_eq!(align(b"", 1, 400, b','), (1, 0));
        assert_eq!(align(b"h\nv\n", 3, 400, b','), (3, 0));
    }
}
