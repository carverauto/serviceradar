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
fn test_parse_complete_datagram_with_multiple_sample_types() {
    // agent=10.0.0.1 seq=42 uptime=5000 samples=2
    // flow sample with extended switch + counter sample with VLAN
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 2a 00 00 13 88 00 00 00 02 00 00 00 01\n\
        0020   00 00 00 38 00 00 00 01 00 00 00 03 00 00 01 00\n\
        0030   00 00 03 e8 00 00 00 00 00 00 00 01 00 00 00 02\n\
        0040   00 00 00 01 00 00 03 e9 00 00 00 10 00 00 00 64\n\
        0050   00 00 00 00 00 00 00 c8 00 00 00 00 00 00 00 02\n\
        0060   00 00 00 30 00 00 00 01 00 00 00 01 00 00 00 01\n\
        0070   00 00 00 05 00 00 00 1c 00 00 00 64 00 00 00 00\n\
        0080   00 00 10 00 00 00 00 32 00 00 00 05 00 00 00 02\n\
        0090   00 00 00 00\
    ");
    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);

    assert!(result.error.is_none());
    assert_eq!(result.datagrams.len(), 1);

    let dg = &result.datagrams[0];
    assert_eq!(dg.version, 5);
    assert_eq!(dg.sequence_number, 42);
    assert_eq!(dg.samples.len(), 2);

    assert!(matches!(&dg.samples[0], SflowSample::Flow(_)));
    assert!(matches!(&dg.samples[1], SflowSample::Counter(_)));
}

#[test]
fn test_parse_zero_sample_datagram() {
    // agent=192.168.1.1 seq=1 uptime=100 samples=0
    let data = h("\
        0000   00 00 00 05 00 00 00 01 c0 a8 01 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 00 64 00 00 00 00\
    ");

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());
    assert_eq!(result.datagrams[0].samples.len(), 0);
}

#[test]
fn test_default_parser_equals_builder() {
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 2a 00 00 13 88 00 00 00 02 00 00 00 01\n\
        0020   00 00 00 38 00 00 00 01 00 00 00 03 00 00 01 00\n\
        0030   00 00 03 e8 00 00 00 00 00 00 00 01 00 00 00 02\n\
        0040   00 00 00 01 00 00 03 e9 00 00 00 10 00 00 00 64\n\
        0050   00 00 00 00 00 00 00 c8 00 00 00 00 00 00 00 02\n\
        0060   00 00 00 30 00 00 00 01 00 00 00 01 00 00 00 01\n\
        0070   00 00 00 05 00 00 00 1c 00 00 00 64 00 00 00 00\n\
        0080   00 00 10 00 00 00 00 32 00 00 00 05 00 00 00 02\n\
        0090   00 00 00 00\
    ");

    let default_result = SflowParser::default().parse_bytes(&data);
    let builder_result = SflowParser::builder().build().parse_bytes(&data);

    assert_eq!(default_result, builder_result);
}
