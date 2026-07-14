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
fn test_datagram_with_mixed_samples() {
    // datagram header: agent=10.0.0.1 seq=1 uptime=1000 samples=3
    // flow sample(0:1) len=32: seq=1 rate=256 pool=100 0 records
    // counter sample(0:2) len=12: seq=1 src_id=1 0 records
    // expanded flow(0:3) len=44: seq=1 type=0 idx=1
    //   rate=512 pool=200 in=1 out=2 0 records
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 03 00 00 00 01\n\
        0020   00 00 00 20 00 00 00 01 00 00 00 00 00 00 01 00\n\
        0030   00 00 00 64 00 00 00 00 00 00 00 01 00 00 00 02\n\
        0040   00 00 00 00 00 00 00 02 00 00 00 0c 00 00 00 01\n\
        0050   00 00 00 01 00 00 00 00 00 00 00 03 00 00 00 2c\n\
        0060   00 00 00 01 00 00 00 00 00 00 00 01 00 00 02 00\n\
        0070   00 00 00 c8 00 00 00 00 00 00 00 00 00 00 00 01\n\
        0080   00 00 00 00 00 00 00 02 00 00 00 00\
    ");

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());
    assert_eq!(result.datagrams.len(), 1);

    let samples = &result.datagrams[0].samples;
    assert_eq!(samples.len(), 3);
    assert!(matches!(samples[0], SflowSample::Flow(_)));
    assert!(matches!(samples[1], SflowSample::Counter(_)));
    assert!(matches!(samples[2], SflowSample::ExpandedFlow(_)));
}
