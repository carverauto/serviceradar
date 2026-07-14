use flowparser_sflow::*;

/// Decode a Wireshark-style hex dump into bytes.
/// Strips offset prefixes (e.g., "0000   ") and whitespace.
fn h(hex: &str) -> Vec<u8> {
    let mut out = String::new();
    for line in hex.lines() {
        let t = line.trim();
        if t.is_empty() {
            continue;
        }
        let data = match t.find("  ") {
            Some(pos) if pos >= 4 && t[..pos].bytes().all(|b| b.is_ascii_hexdigit()) => {
                &t[pos..]
            }
            _ => t,
        };
        out.push_str(data);
    }
    hex::decode(out.replace(' ', "")).unwrap()
}

#[test]
fn test_json_round_trip() {
    // Minimal v5 datagram: agent=10.0.0.1, seq=1, uptime=1000, 0 samples
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 00\
    ");
    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);

    let json = serde_json::to_string_pretty(&result).unwrap();
    let deserialized: ParseResult = serde_json::from_str(&json).unwrap();
    assert_eq!(result, deserialized);
}

#[test]
fn test_json_contains_readable_ip() {
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 00\
    ");
    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    let json = serde_json::to_string(&result).unwrap();
    assert!(json.contains("10.0.0.1"));
}

#[test]
fn test_error_serialization() {
    let err = SflowError::UnsupportedVersion { version: 4 };
    let json = serde_json::to_string(&err).unwrap();
    let deserialized: SflowError = serde_json::from_str(&json).unwrap();
    assert_eq!(err, deserialized);
}

#[test]
fn test_datagram_debug_display() {
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 00\
    ");
    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    let debug = format!("{:?}", result.datagrams[0]);
    assert!(debug.contains("SflowDatagram"));
    assert!(debug.contains("version: 5"));
}
