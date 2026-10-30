#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct HttpHeader {
    pub status: u16,
    pub fields: Vec<(String, String)>,
}

impl HttpHeader {
    pub fn get(&self, name: &str) -> Option<&str> {
        get_field(&self.fields, name)
    }

    pub fn get_ignore_case(&self, name: &str) -> Option<&str> {
        self.fields
            .iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

pub(crate) fn get_field<'a>(fields: &'a [(String, String)], name: &str) -> Option<&'a str> {
    fields
        .iter()
        .find(|(n, _)| n == name)
        .map(|(_, v)| v.as_str())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Strictness {
    Strict,
    Tolerant,
}

pub(crate) fn header_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n").map(|p| p + 4)
}

pub(crate) fn parse_response(text: &[u8], strictness: Strictness) -> Option<HttpHeader> {
    let rest = text.strip_prefix(b"HTTP/1.1 ")?;
    let digits = rest.iter().take_while(|b| b.is_ascii_digit()).count();
    if digits == 0 || digits > 5 {
        return None;
    }
    let status: u16 = std::str::from_utf8(&rest[..digits]).ok()?.parse().ok()?;
    let line_end = rest.iter().position(|&b| b == b'\n').unwrap_or(rest.len());
    let after = rest.get(line_end + 1..).unwrap_or_default();
    let fields = parse_fields(after, strictness)?;
    Some(HttpHeader { status, fields })
}

pub(crate) fn parse_fields(text: &[u8], strictness: Strictness) -> Option<Vec<(String, String)>> {
    let mut fields = Vec::new();
    for raw in text.split(|&b| b == b'\n') {
        let line = raw.strip_suffix(b"\r").unwrap_or(raw);
        if line.is_empty() {
            continue;
        }
        let Some(colon) = line.iter().position(|&b| b == b':') else {
            match strictness {
                Strictness::Strict => return None,
                Strictness::Tolerant => continue,
            }
        };
        let name = &line[..colon];
        let mut value = &line[colon + 1..];
        if let Some(v) = value.strip_prefix(b" ") {
            value = v;
        }
        if value.is_empty() {
            match strictness {
                Strictness::Strict => return None,
                Strictness::Tolerant => continue,
            }
        }
        fields.push((
            String::from_utf8_lossy(name).into_owned(),
            String::from_utf8_lossy(value).into_owned(),
        ));
    }
    Some(fields)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_status_and_fields() {
        let h = parse_response(
            b"HTTP/1.1 200 OK\r\nRP-Nonce: abc\r\nrp-version:1.0\r\n\r\n",
            Strictness::Strict,
        )
        .unwrap();
        assert_eq!(h.status, 200);
        assert_eq!(h.get("RP-Nonce"), Some("abc"));
        assert_eq!(h.get("RP-Version"), None);
        assert_eq!(h.get_ignore_case("RP-Version"), Some("1.0"));
    }

    #[test]
    fn strict_rejects_bad_lines_tolerant_skips() {
        let text = b"HTTP/1.1 403 Forbidden\nbroken line\nA: \nB: x\n";
        assert!(parse_response(text, Strictness::Strict).is_none());
        let h = parse_response(text, Strictness::Tolerant).unwrap();
        assert_eq!(h.fields, vec![("B".to_string(), "x".to_string())]);
    }

    #[test]
    fn rejects_wrong_status_line() {
        assert!(parse_response(b"HTTP/1.0 200 OK\r\n", Strictness::Tolerant).is_none());
        assert!(parse_response(b"HTTP/1.1 OK\r\n", Strictness::Tolerant).is_none());
    }

    #[test]
    fn finds_header_end() {
        assert_eq!(header_end(b"a\r\n\r\nbody"), Some(5));
        assert_eq!(header_end(b"a\r\n\r"), None);
    }
}
