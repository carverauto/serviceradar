use flowparser_sflow::*;
use std::net::Ipv4Addr;

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
fn test_real_flow_with_switch_and_raw_header() {
    // Real pcap: agent=10.0.0.20 seq=35136 uptime=69674000 samples=2
    // Counter(GenericInterface) + Flow(ExtendedSwitch, RawPacketHeader)
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 14 00 00 00 00\n\
        0010   00 00 89 40 04 27 24 10 00 00 00 02 00 00 00 02\n\
        0020   00 00 00 6c 00 00 0d 9c 00 00 00 10 00 00 00 01\n\
        0030   00 00 00 01 00 00 00 58 00 00 00 10 00 00 00 06\n\
        0040   00 00 00 00 05 f5 e1 00 00 00 00 00 00 00 00 03\n\
        0050   00 00 00 00 1a 22 f5 6e 00 21 fe e7 00 00 00 00\n\
        0060   ff ff ff ff 00 00 00 00 00 00 00 00 ff ff ff ff\n\
        0070   00 00 00 00 9d ad 17 05 02 3d 0d 17 ff ff ff ff\n\
        0080   ff ff ff ff 00 00 02 ad 00 00 00 00 00 00 00 00\n\
        0090   00 00 00 01 00 00 00 bc 00 00 1d ae 00 00 00 16\n\
        00a0   00 00 01 90 00 2f 25 e3 00 00 00 00 00 00 00 16\n\
        00b0   00 00 00 02 00 00 00 02 00 00 03 e9 00 00 00 10\n\
        00c0   00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n\
        00d0   00 00 00 01 00 00 00 7c 00 00 00 01 00 00 00 6d\n\
        00e0   00 00 00 04 00 00 00 69 3e 5b 35 4b 3a 72 f2 29\n\
        00f0   01 70 58 25 08 00 45 00 00 5b 55 3e 40 00 40 06\n\
        0100   d0 32 0a 00 00 97 0a 00 00 96 2b cb c1 f3 47 e9\n\
        0110   a7 d7 b0 5a a0 59 80 18 00 2e e3 9e 00 00 01 01\n\
        0120   08 0a 3e d9 3b 26 3e d9 4a dc 56 41 4c 55 45 20\n\
        0130   73 65 73 73 69 6f 6e 2e 74 69 6d 65 20 30 20 38\n\
        0140   0d 0a 31 31 3a 34 38 3a 32 38 0d 0a 45 4e 44 0d\n\
        0150   0a 56 80 18\
    ");

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());
    assert_eq!(result.datagrams.len(), 1);

    let dg = &result.datagrams[0];
    assert_eq!(dg.version, 5);
    assert_eq!(
        dg.agent_address,
        AddressType::IPv4(Ipv4Addr::new(10, 0, 0, 20))
    );
    assert_eq!(dg.sequence_number, 35136);
    assert_eq!(dg.uptime, 69_674_000);
    assert_eq!(dg.samples.len(), 2);

    // Sample 0: Counter with GenericInterface
    let cs = match &dg.samples[0] {
        SflowSample::Counter(cs) => cs,
        other => panic!("expected Counter, got {other:?}"),
    };
    assert_eq!(cs.sequence_number, 3484);
    assert_eq!(cs.records.len(), 1);
    let gi = match &cs.records[0] {
        CounterRecord::GenericInterface(gi) => gi,
        other => panic!("expected GenericInterface, got {other:?}"),
    };
    assert_eq!(gi.if_speed, 100_000_000);
    assert_eq!(gi.if_in_broadcast_pkts, 0xFFFF_FFFF);

    // Sample 1: Flow with ExtendedSwitch + RawPacketHeader
    let fs = match &dg.samples[1] {
        SflowSample::Flow(fs) => fs,
        other => panic!("expected Flow, got {other:?}"),
    };
    assert_eq!(fs.sequence_number, 7598);
    assert_eq!(fs.sampling_rate, 400);
    assert_eq!(fs.records.len(), 2);

    let esw = match &fs.records[0] {
        FlowRecord::ExtendedSwitch(esw) => esw,
        other => panic!("expected ExtendedSwitch, got {other:?}"),
    };
    assert_eq!(esw.src_vlan, 0);
    assert_eq!(esw.dst_vlan, 0);

    let rph = match &fs.records[1] {
        FlowRecord::RawPacketHeader(rph) => rph,
        other => panic!("expected RawPacketHeader, got {other:?}"),
    };
    assert_eq!(rph.header_protocol, 1);
    assert_eq!(rph.frame_length, 109);
    assert_eq!(rph.header_length, 105);
}

#[test]
fn test_real_unknown_http_records() {
    // Real pcap: agent=10.0.0.150 seq=60411 samples=2
    // Two flow samples with sFlow HTTP extension records (formats 2100, 2206)
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 96 00 00 00 00\n\
        0010   00 00 eb fb 04 26 d5 f0 00 00 00 02 00 00 00 01\n\
        0020   00 00 00 bc 00 02 03 d6 03 00 00 50 00 00 00 64\n\
        0030   00 c5 52 e2 00 00 00 00 00 00 00 00 3f ff ff ff\n\
        0040   00 00 00 02 00 00 08 34 00 00 00 14 00 00 00 06\n\
        0050   0a 00 00 96 0a 00 00 98 00 00 00 50 00 00 a6 ff\n\
        0060   00 00 08 9e 00 00 00 78 00 00 00 02 00 00 03 e9\n\
        0070   00 00 00 11 2f 69 6d 61 67 65 73 2f 71 75 69 6c\n\
        0080   6c 2e 70 6e 67 00 00 00 00 00 00 0a 31 30 2e 30\n\
        0090   2e 30 2e 31 35 30 00 00 00 00 00 00 00 00 00 0d\n\
        00a0   4a 61 76 61 2f 31 2e 36 2e 30 5f 32 32 00 00 00\n\
        00b0   00 00 00 00 00 00 00 00 00 00 00 09 69 6d 61 67\n\
        00c0   65 2f 70 6e 67 00 00 00 00 00 00 00 00 00 00 00\n\
        00d0   00 00 00 00 00 00 01 3b 00 00 01 60 00 00 00 c8\n\
        00e0   00 00 00 01 00 00 00 c8 00 02 03 d7 03 00 00 50\n\
        00f0   00 00 00 64 00 c5 53 10 00 00 00 00 00 00 00 00\n\
        0100   3f ff ff ff 00 00 00 02 00 00 08 34 00 00 00 14\n\
        0110   00 00 00 06 0a 00 00 96 0a 00 00 98 00 00 00 50\n\
        0120   00 00 a7 39 00 00 08 9e 00 00 00 84 00 00 00 02\n\
        0130   00 00 03 e9 00 00 00 12 2f 67 61 6d 65 73 2f 70\n\
        0140   75 7a 7a 6c 65 73 2e 70 68 70 00 00 00 00 00 0a\n\
        0150   31 30 2e 30 2e 30 2e 31 35 30 00 00 00 00 00 00\n\
        0160   00 00 00 0d 4a 61 76 61 2f 31 2e 36 2e 30 5f 32\n\
        0170   32 00 00 00 00 00 00 00 00 00 00 00 00 00 00 18\n\
        0180   74 65 78 74 2f 68 74 6d 6c 3b 20 63 68 61 72 73\n\
        0190   65 74 3d 55 54 46 2d 38 00 00 00 00 00 00 00 00\n\
        01a0   00 00 00 00 00 00 00 99 00 00 1a 01 00 00 00 c8\
    ");

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());
    assert_eq!(result.datagrams.len(), 1);

    let dg = &result.datagrams[0];
    assert_eq!(
        dg.agent_address,
        AddressType::IPv4(Ipv4Addr::new(10, 0, 0, 150))
    );
    assert_eq!(dg.sequence_number, 60411);
    assert_eq!(dg.samples.len(), 2);

    // Sample 0: Flow with src_id_type=3, src_id_index=80
    let fs0 = match &dg.samples[0] {
        SflowSample::Flow(fs) => fs,
        other => panic!("expected Flow, got {other:?}"),
    };
    assert_eq!(fs0.source_id_type, 3);
    assert_eq!(fs0.source_id_index, 80);
    assert_eq!(fs0.records.len(), 2);

    // Record 0: ExtendedSocketIpv4 (format 2100)
    let sock0 = match &fs0.records[0] {
        FlowRecord::ExtendedSocketIpv4(s) => s,
        other => panic!("expected ExtendedSocketIpv4, got {other:?}"),
    };
    assert_eq!(sock0.protocol, 6); // TCP
    assert_eq!(sock0.local_ip, Ipv4Addr::new(10, 0, 0, 150));
    assert_eq!(sock0.remote_ip, Ipv4Addr::new(10, 0, 0, 152));
    assert_eq!(sock0.local_port, 80);
    assert_eq!(sock0.remote_port, 42751);

    // Record 1: HttpRequest (format 2206)
    let http0 = match &fs0.records[1] {
        FlowRecord::HttpRequest(h) => h,
        other => panic!("expected HttpRequest, got {other:?}"),
    };
    assert_eq!(http0.method, 2); // GET
    assert_eq!(http0.uri, "/images/quill.png");
    assert_eq!(http0.host, "10.0.0.150");
    assert_eq!(http0.status, 200);

    // Sample 1: Flow with same parsed record formats
    let fs1 = match &dg.samples[1] {
        SflowSample::Flow(fs) => fs,
        other => panic!("expected Flow, got {other:?}"),
    };
    assert_eq!(fs1.records.len(), 2);

    // Record 0: ExtendedSocketIpv4
    let sock1 = match &fs1.records[0] {
        FlowRecord::ExtendedSocketIpv4(s) => s,
        other => panic!("expected ExtendedSocketIpv4, got {other:?}"),
    };
    assert_eq!(sock1.protocol, 6);
    assert_eq!(sock1.local_port, 80);

    // Record 1: HttpRequest
    let http1 = match &fs1.records[1] {
        FlowRecord::HttpRequest(h) => h,
        other => panic!("expected HttpRequest, got {other:?}"),
    };
    assert_eq!(http1.uri, "/games/puzzles.php");
    assert_eq!(http1.status, 200);
}

#[test]
fn test_real_mixed_samples_with_three_record_flow() {
    // Real pcap: agent=10.0.0.30 seq=180308 samples=3
    // Counter(GenericInterface) + Flow(RawPacketHeader) +
    // Flow(Unknown:1030, Unknown:1029, RawPacketHeader)
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 1e 00 00 00 00\n\
        0010   00 02 c0 54 0b 30 13 20 00 00 00 03 00 00 00 02\n\
        0020   00 00 00 6c 00 00 24 a9 00 00 00 04 00 00 00 01\n\
        0030   00 00 00 01 00 00 00 58 00 00 00 04 00 00 00 06\n\
        0040   00 00 00 00 3b 9a ca 00 00 00 00 03 00 00 00 03\n\
        0050   00 00 00 01 65 a5 a3 b7 00 c9 df 4d 00 17 1b f8\n\
        0060   02 36 91 33 00 02 6a 3b ff ff ff ff ff ff ff ff\n\
        0070   00 00 00 01 00 e1 f3 6c 00 fd e7 b4 00 0d 50 d8\n\
        0080   00 46 c4 f8 00 00 00 5c ff ff ff ff 00 00 00 02\n\
        0090   00 00 00 01 00 00 00 b8 00 02 ba 4a 00 00 00 02\n\
        00a0   00 00 01 90 04 43 13 a0 00 00 00 5f 00 00 00 02\n\
        00b0   00 00 00 01 00 00 00 01 00 00 00 01 00 00 00 90\n\
        00c0   00 00 00 01 00 00 f5 76 00 00 00 04 00 00 00 80\n\
        00d0   00 15 5d 00 1e 00 00 15 5d 00 1e 01 08 00 45 00\n\
        00e0   00 00 3b 6c 40 00 80 06 00 00 0a 00 00 34 0a 00\n\
        00f0   00 36 00 50 ed 18 18 5d 95 6f be fa 50 3a 50 10\n\
        0100   02 01 14 70 00 00 f2 24 96 cb 06 05 b5 ab ad 4d\n\
        0110   0d 07 a7 25 ae 02 9c 74 f5 85 30 87 bd bb 5d ab\n\
        0120   76 b4 6b 73 ba e1 c5 fd 94 b6 a8 25 00 ae 4f 57\n\
        0130   bf 3e 45 7a 8d 60 34 91 d1 c6 90 3b eb 19 b8 76\n\
        0140   ea 98 22 bf 79 93 cf 47 e2 0e 63 47 8c 63 d1 98\n\
        0150   00 00 00 01 00 00 00 d0 00 00 7b 50 00 00 00 05\n\
        0160   00 00 01 90 00 c0 ad 00 00 00 00 5f 00 00 00 05\n\
        0170   00 00 00 06 00 00 00 03 00 00 04 06 00 00 00 04\n\
        0180   00 00 17 70 00 00 04 05 00 00 00 04 00 00 17 70\n\
        0190   00 00 00 01 00 00 00 90 00 00 00 01 00 00 28 26\n\
        01a0   00 00 00 04 00 00 00 80 00 15 5d 00 1e 03 00 15\n\
        01b0   5d 00 1e 02 08 00 45 02 00 00 35 5e 40 00 80 06\n\
        01c0   00 00 c0 a8 0a 01 c0 a8 0a 02 01 bd c0 07 77 7a\n\
        01d0   8c c5 44 a7 78 ff 50 10 10 04 95 5a 00 00 22 91\n\
        01e0   2d 37 a2 7b 19 8e 7b 7c 45 b6 a8 bc 6d 21 a6 2a\n\
        01f0   b5 b6 f4 50 23 a2 6e cb 84 fd 24 9d 94 cd 8b 12\n\
        0200   d9 7a 83 b0 66 d1 16 4d a6 da a2 86 48 a2 dc 7b\n\
        0210   40 a1 58 d7 02 32 f1 b3 8b 9f ae 67 8f 1e db 31\n\
        0220   66 93 30 7a fa f5 41 e6\
    ");

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());
    assert_eq!(result.datagrams.len(), 1);

    let dg = &result.datagrams[0];
    assert_eq!(
        dg.agent_address,
        AddressType::IPv4(Ipv4Addr::new(10, 0, 0, 30))
    );
    assert_eq!(dg.sequence_number, 180308);
    assert_eq!(dg.samples.len(), 3);

    // Sample 0: Counter with GenericInterface (1G, direction=3)
    let cs = match &dg.samples[0] {
        SflowSample::Counter(cs) => cs,
        other => panic!("expected Counter, got {other:?}"),
    };
    assert_eq!(cs.sequence_number, 9385);
    let gi = match &cs.records[0] {
        CounterRecord::GenericInterface(gi) => gi,
        other => panic!("expected GenericInterface, got {other:?}"),
    };
    assert_eq!(gi.if_speed, 1_000_000_000);
    assert_eq!(gi.if_direction, 3);

    // Sample 1: Flow with 1 RawPacketHeader (jumbo-like frame)
    let fs1 = match &dg.samples[1] {
        SflowSample::Flow(fs) => fs,
        other => panic!("expected Flow, got {other:?}"),
    };
    assert_eq!(fs1.records.len(), 1);
    let rph = match &fs1.records[0] {
        FlowRecord::RawPacketHeader(rph) => rph,
        other => panic!("expected RawPacketHeader, got {other:?}"),
    };
    assert_eq!(rph.frame_length, 62838);

    // Sample 2: Flow with 3 records
    let fs2 = match &dg.samples[2] {
        SflowSample::Flow(fs) => fs,
        other => panic!("expected Flow, got {other:?}"),
    };
    assert_eq!(fs2.records.len(), 3);

    // Record 0: ExtendedVniIngress (format 1030)
    let vni_in = match &fs2.records[0] {
        FlowRecord::ExtendedVniIngress(v) => v,
        other => panic!("expected ExtendedVniIngress, got {other:?}"),
    };
    assert_eq!(vni_in.vni, 6000);

    // Record 1: ExtendedVniEgress (format 1029)
    let vni_out = match &fs2.records[1] {
        FlowRecord::ExtendedVniEgress(v) => v,
        other => panic!("expected ExtendedVniEgress, got {other:?}"),
    };
    assert_eq!(vni_out.vni, 6000);

    // Record 2: RawPacketHeader
    assert!(matches!(&fs2.records[2], FlowRecord::RawPacketHeader(_)));
}

#[test]
fn test_real_large_datagram_eight_samples() {
    // Real pcap: agent=10.0.0.16 seq=94825 uptime=69689000 samples=8
    // 1 Counter(GenericInterface) + 7 Flow(ExtendedSwitch, RawPacketHeader)
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 10 00 00 00 00\n\
        0010   00 01 72 69 04 27 5e a8 00 00 00 08 00 00 00 02\n\
        0020   00 00 00 6c 00 00 0d 9d 00 00 00 18 00 00 00 01\n\
        0030   00 00 00 01 00 00 00 58 00 00 00 18 00 00 00 06\n\
        0040   00 00 00 00 05 f5 e1 00 00 00 00 00 00 00 00 03\n\
        0050   00 00 00 00 8c d5 fe af 00 b1 dd 3d 00 00 00 00\n\
        0060   ff ff ff ff 00 00 00 00 00 00 00 00 ff ff ff ff\n\
        0070   00 00 00 03 80 c9 2b 47 03 c8 f2 89 ff ff ff ff\n\
        0080   ff ff ff ff 00 00 00 01 00 00 00 00 00 00 00 00\n\
        0090   00 00 00 01 00 00 00 9c 00 00 aa 91 00 00 00 04\n\
        00a0   00 00 01 90 27 38 31 ac 00 00 00 00 00 00 00 04\n\
        00b0   00 00 00 15 00 00 00 02 00 00 03 e9 00 00 00 10\n\
        00c0   00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n\
        00d0   00 00 00 01 00 00 00 5c 00 00 00 01 00 00 00 4e\n\
        00e0   00 00 00 04 00 00 00 4a 3e 5b 35 4b 3a 72 f2 29\n\
        00f0   01 70 58 25 08 00 45 00 00 3c f3 f6 40 00 40 06\n\
        0100   31 99 0a 00 00 97 0a 00 00 96 2b cb c1 ee 47 d2\n\
        0110   4a df 8d af 17 85 80 18 00 2e 3e 00 00 00 01 01\n\
        0120   08 0a 3e d9 3d ab 3e d9 4d 60 53 54 4f 52 45 44\n\
        0130   0d 0a a8 bf 00 00 00 01 00 00 00 94 00 00 aa 92\n\
        0140   00 00 00 04 00 00 01 90 27 38 33 1a 00 00 00 00\n\
        0150   00 00 00 04 00 00 00 15 00 00 00 02 00 00 03 e9\n\
        0160   00 00 00 10 00 00 00 00 00 00 00 00 00 00 00 00\n\
        0170   00 00 00 00 00 00 00 01 00 00 00 54 00 00 00 01\n\
        0180   00 00 00 46 00 00 00 04 00 00 00 42 3e 5b 35 4b\n\
        0190   3a 72 8e e6 ce f9 57 74 08 00 45 00 00 34 b0 45\n\
        01a0   40 00 40 06 75 51 0a 00 00 98 0a 00 00 96 a9 04\n\
        01b0   00 50 2b c0 f4 d4 b4 64 43 fc 80 10 00 36 8f 24\n\
        01c0   00 00 01 01 08 0a 3e d9 44 a0 3e d9 4d 98 a8 d7\n\
        01d0   00 00 00 01 00 00 00 9c 00 00 aa 93 00 00 00 04\n\
        01e0   00 00 01 90 27 38 33 a1 00 00 00 00 00 00 00 04\n\
        01f0   00 00 00 15 00 00 00 02 00 00 03 e9 00 00 00 10\n\
        0200   00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n\
        0210   00 00 00 01 00 00 00 5c 00 00 00 01 00 00 00 4e\n\
        0220   00 00 00 04 00 00 00 4a 3e 5b 35 4b 3a 72 8e e6\n\
        0230   ce f9 57 74 08 00 45 00 00 3c da 9e 40 00 40 06\n\
        0240   4a f0 0a 00 00 98 0a 00 00 96 a9 1f 00 50 b1 f1\n\
        0250   9e 37 00 00 00 00 a0 02 16 d0 9e e7 00 00 02 04\n\
        0260   05 b4 04 02 08 0a 3e d9 44 a9 00 00 00 00 01 03\n\
        0270   03 07 00 00 00 00 00 01 00 00 00 bc 00 00 aa 94\n\
        0280   00 00 00 04 00 00 01 90 27 38 34 2f 00 00 00 00\n\
        0290   00 00 00 04 00 00 00 15 00 00 00 02 00 00 03 e9\n\
        02a0   00 00 00 10 00 00 00 00 00 00 00 00 00 00 00 00\n\
        02b0   00 00 00 00 00 00 00 01 00 00 00 7c 00 00 00 01\n\
        02c0   00 00 00 6d 00 00 00 04 00 00 00 69 3e 5b 35 4b\n\
        02d0   3a 72 f2 29 01 70 58 25 08 00 45 00 00 5b f3 fb\n\
        02e0   40 00 40 06 31 75 0a 00 00 97 0a 00 00 96 2b cb\n\
        02f0   c1 ee 47 d2 4b 42 8d af 17 f1 80 18 00 2e e5 77\n\
        0300   00 00 01 01 08 0a 3e d9 3e 1c 3e d9 4d d2 56 41\n\
        0310   4c 55 45 20 73 65 73 73 69 6f 6e 2e 74 69 6d 65\n\
        0320   20 30 20 38 0d 0a 31 31 3a 34 38 3a 32 38 0d 0a\n\
        0330   45 4e 44 0d 0a e6 ce f9 00 00 00 01 00 00 00 b4\n\
        0340   00 03 97 8b 00 00 00 15 00 00 01 90 3f 21 81 93\n\
        0350   00 00 00 00 00 00 00 15 00 00 00 04 00 00 00 02\n\
        0360   00 00 03 e9 00 00 00 10 00 00 00 00 00 00 00 00\n\
        0370   00 00 00 00 00 00 00 00 00 00 00 01 00 00 00 74\n\
        0380   00 00 00 01 00 00 00 65 00 00 00 04 00 00 00 61\n\
        0390   f2 29 01 70 58 25 3e 5b 35 4b 3a 72 08 00 45 00\n\
        03a0   00 53 ae d1 40 00 40 06 76 a7 0a 00 00 96 0a 00\n\
        03b0   00 97 c1 ee 2b cb 8d af 18 07 47 d2 4b 8d 80 18\n\
        03c0   00 2e 44 78 00 00 01 01 08 0a 3e d9 4d d2 3e d9\n\
        03d0   3e 1c 73 65 74 20 61 6e 69 6d 61 6c 73 2e 68 61\n\
        03e0   6d 73 74 65 72 73 20 30 20 30 20 31 0d 0a 31 0d\n\
        03f0   0a 98 00 50 00 00 00 01 00 00 00 b4 00 03 97 8c\n\
        0400   00 00 00 15 00 00 01 90 3f 21 81 a3 00 00 00 00\n\
        0410   00 00 00 15 00 00 00 04 00 00 00 02 00 00 03 e9\n\
        0420   00 00 00 10 00 00 00 00 00 00 00 00 00 00 00 00\n\
        0430   00 00 00 00 00 00 00 01 00 00 00 74 00 00 00 01\n\
        0440   00 00 00 67 00 00 00 04 00 00 00 63 f2 29 01 70\n\
        0450   58 25 3e 5b 35 4b 3a 72 08 00 45 00 00 55 8a 0d\n\
        0460   40 00 40 06 9b 69 0a 00 00 96 0a 00 00 97 c1 fa\n\
        0470   2b cb b2 4c eb b5 48 19 6d ca 80 18 00 2e 43 49\n\
        0480   00 00 01 01 08 0a 3e d9 4d d4 3e d9 3e 1c 73 65\n\
        0490   74 20 73 65 73 73 69 6f 6e 2e 75 73 65 72 5f 69\n\
        04a0   64 20 30 20 30 20 34 0d 0a 75 73 65 72 0d 0a d9\n\
        04b0   00 00 00 01 00 00 00 94 00 00 aa 95 00 00 00 04\n\
        04c0   00 00 01 90 27 38 34 cd 00 00 00 00 00 00 00 04\n\
        04d0   00 00 00 15 00 00 00 02 00 00 03 e9 00 00 00 10\n\
        04e0   00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n\
        04f0   00 00 00 01 00 00 00 54 00 00 00 01 00 00 00 46\n\
        0500   00 00 00 04 00 00 00 42 3e 5b 35 4b 3a 72 8e e6\n\
        0510   ce f9 57 74 08 00 45 00 00 34 ae 03 40 00 40 06\n\
        0520   77 93 0a 00 00 98 0a 00 00 96 a9 4c 00 50 fd a6\n\
        0530   ea e8 c5 cf 05 95 80 10 00 2e f3 59 00 00 01 01\n\
        0540   08 0a 3e d9 44 e6 3e d9 4d de fd eb\
    ");

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());
    assert_eq!(result.datagrams.len(), 1);

    let dg = &result.datagrams[0];
    assert_eq!(
        dg.agent_address,
        AddressType::IPv4(Ipv4Addr::new(10, 0, 0, 16))
    );
    assert_eq!(dg.sequence_number, 94825);
    assert_eq!(dg.uptime, 69_689_000);
    assert_eq!(dg.samples.len(), 8);

    // Sample 0: Counter with GenericInterface
    assert!(matches!(
        &dg.samples[0],
        SflowSample::Counter(cs) if cs.records.len() == 1
            && matches!(&cs.records[0], CounterRecord::GenericInterface(_))
    ));

    // Samples 1..8: Flow, each with ExtendedSwitch + RawPacketHeader
    for (i, sample) in dg.samples[1..].iter().enumerate() {
        let fs = match sample {
            SflowSample::Flow(fs) => fs,
            other => panic!("sample[{}]: expected Flow, got {other:?}", i + 1),
        };
        assert_eq!(
            fs.records.len(),
            2,
            "sample[{}]: expected 2 records, got {}",
            i + 1,
            fs.records.len()
        );
        assert!(
            matches!(&fs.records[0], FlowRecord::ExtendedSwitch(_)),
            "sample[{}] record[0]: expected ExtendedSwitch",
            i + 1
        );
        assert!(
            matches!(&fs.records[1], FlowRecord::RawPacketHeader(_)),
            "sample[{}] record[1]: expected RawPacketHeader",
            i + 1
        );
    }
}
