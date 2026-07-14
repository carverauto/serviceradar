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
fn test_truncated_header() {
    let parser = SflowParser::default();
    let result = parser.parse_bytes(&h("0000   00 00 00"));
    assert!(result.error.is_some());
    assert!(matches!(
        result.error.unwrap(),
        SflowError::Incomplete { .. }
    ));
}

#[test]
fn test_wrong_version() {
    // version=4 (unsupported), rest is valid IPv4 header
    let data = h("\
        0000   00 00 00 04 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 00 64 00 00 00 00\
    ");

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_some());
    match result.error.unwrap() {
        SflowError::UnsupportedVersion { version } => {
            assert_eq!(version, 4)
        }
        other => panic!("Expected UnsupportedVersion, got {:?}", other),
    }
}

#[test]
fn test_max_samples_exceeded() {
    // Header claiming 100 samples
    let mut data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 00 64 00 00 00 64\
    ");

    // Empty flow sample (32 bytes body): seq=1, 0 records
    let empty_flow = h("\
        0000   00 00 00 01 00 00 00 20 00 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 00 00 00 00 00 00 00 00 00 00\n\
        0020   00 00 00 00 00 00 00 00\
    ");
    for _ in 0..100 {
        data.extend_from_slice(&empty_flow);
    }

    let parser = SflowParser::builder().with_max_samples(10).build();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_some());
    match result.error.unwrap() {
        SflowError::TooManySamples { count, max } => {
            assert_eq!(count, 100);
            assert_eq!(max, 10);
        }
        other => panic!("Expected TooManySamples, got {:?}", other),
    }
}

#[test]
fn test_error_display_messages() {
    let err = SflowError::UnsupportedVersion { version: 3 };
    let msg = format!("{}", err);
    assert!(msg.contains("3"));
    assert!(msg.contains("5"));

    let err = SflowError::Incomplete {
        available: 2,
        expected: None,
        context: ParseContext::DatagramHeader,
    };
    let msg = format!("{}", err);
    assert!(msg.contains("2"));

    let err = SflowError::TooManySamples { count: 50, max: 10 };
    let msg = format!("{}", err);
    assert!(msg.contains("50"));
    assert!(msg.contains("10"));
}

#[test]
fn test_empty_input() {
    let parser = SflowParser::default();
    let result = parser.parse_bytes(&[]);
    assert!(result.error.is_none());
    assert!(result.datagrams.is_empty());
}
