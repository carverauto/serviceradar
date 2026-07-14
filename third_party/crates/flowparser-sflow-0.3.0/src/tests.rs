use std::net::{Ipv4Addr, Ipv6Addr};

use crate::counter_records::*;
use crate::datagram::*;
use crate::error::{ParseContext, ParseErrorKind};
use crate::flow_records::*;
use crate::samples::*;
use crate::*;

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

// === Datagram Header Tests ===

#[test]
fn test_parse_datagram_ipv4_agent() {
    // version=5, addr_type=IPv4, agent=10.0.0.1,
    // sub_agent=0, seq=1, uptime=1000, samples=0
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 00\
    ");
    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());
    assert_eq!(result.datagrams.len(), 1);
    let dg = &result.datagrams[0];
    assert_eq!(dg.version, 5);
    assert_eq!(
        dg.agent_address,
        AddressType::IPv4(Ipv4Addr::new(10, 0, 0, 1))
    );
    assert_eq!(dg.sub_agent_id, 0);
    assert_eq!(dg.sequence_number, 1);
    assert_eq!(dg.uptime, 1000);
    assert_eq!(dg.samples.len(), 0);
}

#[test]
fn test_parse_datagram_ipv6_agent() {
    // version=5, addr_type=IPv6, agent=fe80::1,
    // sub_agent=0, seq=1, uptime=1000, samples=0
    let data = h("\
        0000   00 00 00 05 00 00 00 02 fe 80 00 00 00 00 00 00\n\
        0010   00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 01\n\
        0020   00 00 03 e8 00 00 00 00\
    ");
    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());
    assert_eq!(result.datagrams.len(), 1);
    let dg = &result.datagrams[0];
    assert_eq!(dg.version, 5);
    match &dg.agent_address {
        AddressType::IPv6(addr) => {
            assert_eq!(*addr, "fe80::1".parse::<Ipv6Addr>().unwrap());
        }
        _ => panic!("Expected IPv6 address"),
    }
}

#[test]
fn test_parse_datagram_bad_version() {
    // version=4 (unsupported)
    let data = h("\
        0000   00 00 00 04 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 00\
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
fn test_parse_truncated_input() {
    let data = h("0000   00 00 00");
    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_some());
    match result.error.unwrap() {
        SflowError::Incomplete { .. } => {}
        other => panic!("Expected Incomplete, got {:?}", other),
    }
}

// === Flow Sample Tests ===

#[test]
fn test_parse_flow_sample_with_extended_switch() {
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 01 00 00 00 01\n\
        0020   00 00 00 38 00 00 00 01 00 00 00 03 00 00 01 00\n\
        0030   00 00 03 e8 00 00 00 00 00 00 00 01 00 00 00 02\n\
        0040   00 00 00 01 00 00 03 e9 00 00 00 10 00 00 00 64\n\
        0050   00 00 00 00 00 00 00 c8 00 00 00 00\
    ");
    //  sample: enterprise=0 format=1, len=56
    //  flow: seq=1 src_id=3 rate=256 pool=1000
    //        drops=0 in=1 out=2 records=1
    //  record: enterprise=0 format=1001(switch), len=16
    //        src_vlan=100 src_pri=0 dst_vlan=200 dst_pri=0

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());
    let dg = &result.datagrams[0];
    assert_eq!(dg.samples.len(), 1);

    match &dg.samples[0] {
        SflowSample::Flow(fs) => {
            assert_eq!(fs.sequence_number, 1);
            assert_eq!(fs.source_id_type, 0);
            assert_eq!(fs.source_id_index, 3);
            assert_eq!(fs.sampling_rate, 256);
            assert_eq!(fs.records.len(), 1);
            match &fs.records[0] {
                FlowRecord::ExtendedSwitch(es) => {
                    assert_eq!(es.src_vlan, 100);
                    assert_eq!(es.dst_vlan, 200);
                }
                other => {
                    panic!("Expected ExtendedSwitch, got {:?}", other)
                }
            }
        }
        other => panic!("Expected Flow sample, got {:?}", other),
    }
}

#[test]
fn test_parse_expanded_flow_sample() {
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 01 00 00 00 03\n\
        0020   00 00 00 2c 00 00 00 01 00 00 00 00 00 00 00 05\n\
        0030   00 00 02 00 00 00 07 d0 00 00 00 00 00 00 00 00\n\
        0040   00 00 00 01 00 00 00 00 00 00 00 02 00 00 00 00\
    ");
    //  sample: enterprise=0 format=3(expanded flow), len=44
    //  seq=1 src_type=0 src_idx=5 rate=512
    //  pool=2000 drops=0 in_fmt=0 in_val=1
    //  out_fmt=0 out_val=2 records=0

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());

    match &result.datagrams[0].samples[0] {
        SflowSample::ExpandedFlow(efs) => {
            assert_eq!(efs.source_id_type, 0);
            assert_eq!(efs.source_id_index, 5);
            assert_eq!(efs.sampling_rate, 512);
            assert_eq!(efs.input_value, 1);
            assert_eq!(efs.output_value, 2);
        }
        other => panic!("Expected ExpandedFlow, got {:?}", other),
    }
}

// === Counter Sample Tests ===

#[test]
fn test_parse_counter_sample_with_vlan() {
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 01 00 00 00 02\n\
        0020   00 00 00 30 00 00 00 01 00 00 00 01 00 00 00 01\n\
        0030   00 00 00 05 00 00 00 1c 00 00 00 64 00 00 00 00\n\
        0040   00 00 10 00 00 00 00 32 00 00 00 05 00 00 00 02\n\
        0050   00 00 00 00\
    ");
    //  sample: enterprise=0 format=2(counter), len=48
    //  counter: seq=1 src_id=1 records=1
    //  record: enterprise=0 format=5(vlan), len=28
    //        vlan_id=100 octets=4096(u64)
    //        ucast=50 mcast=5 bcast=2 discards=0

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());

    match &result.datagrams[0].samples[0] {
        SflowSample::Counter(cs) => {
            assert_eq!(cs.sequence_number, 1);
            assert_eq!(cs.source_id_type, 0);
            assert_eq!(cs.source_id_index, 1);
            assert_eq!(cs.records.len(), 1);
            match &cs.records[0] {
                CounterRecord::Vlan(v) => {
                    assert_eq!(v.vlan_id, 100);
                    assert_eq!(v.octets, 4096);
                    assert_eq!(v.ucast_pkts, 50);
                }
                other => panic!("Expected Vlan, got {:?}", other),
            }
        }
        other => panic!("Expected Counter sample, got {:?}", other),
    }
}

#[test]
fn test_parse_expanded_counter_sample() {
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 01 00 00 00 04\n\
        0020   00 00 00 10 00 00 00 01 00 00 00 00 00 00 00 07\n\
        0030   00 00 00 00\
    ");
    //  sample: enterprise=0 format=4(expanded counter), len=16
    //  seq=1 src_type=0 src_idx=7 records=0

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());

    match &result.datagrams[0].samples[0] {
        SflowSample::ExpandedCounter(ecs) => {
            assert_eq!(ecs.source_id_type, 0);
            assert_eq!(ecs.source_id_index, 7);
        }
        other => panic!("Expected ExpandedCounter, got {:?}", other),
    }
}

// === Flow Record Type Tests ===

#[test]
fn test_parse_raw_packet_header() {
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 01 00 00 00 01\n\
        0020   00 00 00 3c 00 00 00 01 00 00 00 03 00 00 01 00\n\
        0030   00 00 03 e8 00 00 00 00 00 00 00 01 00 00 00 02\n\
        0040   00 00 00 01 00 00 00 01 00 00 00 14 00 00 00 01\n\
        0050   00 00 00 64 00 00 00 00 00 00 00 04 aa bb cc dd\
    ");
    //  record: raw_packet_header(0:1), len=20
    //        proto=1(eth) frame_len=100 stripped=0
    //        hdr_len=4 header=aabbccdd

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());

    let fs = match &result.datagrams[0].samples[0] {
        SflowSample::Flow(fs) => fs,
        other => panic!("Expected Flow, got {:?}", other),
    };
    match &fs.records[0] {
        FlowRecord::RawPacketHeader(rph) => {
            assert_eq!(rph.header_protocol, 1);
            assert_eq!(rph.frame_length, 100);
            assert_eq!(rph.header_length, 4);
            assert_eq!(rph.header, vec![0xAA, 0xBB, 0xCC, 0xDD]);
        }
        other => panic!("Expected RawPacketHeader, got {:?}", other),
    }
}

#[test]
fn test_parse_sampled_ipv4() {
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 01 00 00 00 01\n\
        0020   00 00 00 48 00 00 00 01 00 00 00 03 00 00 01 00\n\
        0030   00 00 03 e8 00 00 00 00 00 00 00 01 00 00 00 02\n\
        0040   00 00 00 01 00 00 00 03 00 00 00 20 00 00 00 64\n\
        0050   00 00 00 06 c0 a8 01 01 0a 00 00 01 00 00 00 50\n\
        0060   00 00 01 bb 00 00 00 02 00 00 00 00\
    ");
    //  record: sampled_ipv4(0:3), len=32
    //        len=100 proto=6(TCP)
    //        src=192.168.1.1 dst=10.0.0.1
    //        src_port=80 dst_port=443
    //        tcp_flags=2 tos=0

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());

    let fs = match &result.datagrams[0].samples[0] {
        SflowSample::Flow(fs) => fs,
        other => panic!("Expected Flow, got {:?}", other),
    };
    match &fs.records[0] {
        FlowRecord::SampledIpv4(s) => {
            assert_eq!(s.protocol, 6);
            assert_eq!(s.src_ip, Ipv4Addr::new(192, 168, 1, 1));
            assert_eq!(s.dst_ip, Ipv4Addr::new(10, 0, 0, 1));
            assert_eq!(s.src_port, 80);
            assert_eq!(s.dst_port, 443);
        }
        other => panic!("Expected SampledIpv4, got {:?}", other),
    }
}

#[test]
fn test_parse_sampled_ipv6() {
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 01 00 00 00 01\n\
        0020   00 00 00 60 00 00 00 01 00 00 00 03 00 00 01 00\n\
        0030   00 00 03 e8 00 00 00 00 00 00 00 01 00 00 00 02\n\
        0040   00 00 00 01 00 00 00 04 00 00 00 38 00 00 00 c8\n\
        0050   00 00 00 11 20 01 0d b8 00 00 00 00 00 00 00 00\n\
        0060   00 00 00 01 20 01 0d b8 00 00 00 00 00 00 00 00\n\
        0070   00 00 00 02 00 00 04 d2 00 00 16 2e 00 00 00 00\n\
        0080   00 00 00 00\
    ");
    //  record: sampled_ipv6(0:4), len=56
    //        len=200 proto=17(UDP)
    //        src=2001:db8::1 dst=2001:db8::2
    //        src_port=1234 dst_port=5678
    //        tcp_flags=0 priority=0

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());

    let fs = match &result.datagrams[0].samples[0] {
        SflowSample::Flow(fs) => fs,
        other => panic!("Expected Flow, got {:?}", other),
    };
    match &fs.records[0] {
        FlowRecord::SampledIpv6(s) => {
            assert_eq!(s.protocol, 17);
            assert_eq!(s.src_ip, Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1));
            assert_eq!(s.dst_ip, Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 2));
            assert_eq!(s.src_port, 1234);
            assert_eq!(s.dst_port, 5678);
        }
        other => panic!("Expected SampledIpv6, got {:?}", other),
    }
}

#[test]
fn test_parse_extended_router() {
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 01 00 00 00 01\n\
        0020   00 00 00 38 00 00 00 01 00 00 00 03 00 00 01 00\n\
        0030   00 00 03 e8 00 00 00 00 00 00 00 01 00 00 00 02\n\
        0040   00 00 00 01 00 00 03 ea 00 00 00 10 00 00 00 01\n\
        0050   0a 00 00 fe 00 00 00 18 00 00 00 10\
    ");
    //  record: extended_router(0:1002), len=16
    //        addr_type=IPv4 next_hop=10.0.0.254
    //        src_mask=24 dst_mask=16

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());

    let fs = match &result.datagrams[0].samples[0] {
        SflowSample::Flow(fs) => fs,
        other => panic!("Expected Flow, got {:?}", other),
    };
    match &fs.records[0] {
        FlowRecord::ExtendedRouter(er) => {
            assert_eq!(er.next_hop, AddressType::IPv4(Ipv4Addr::new(10, 0, 0, 254)));
            assert_eq!(er.src_mask_len, 24);
            assert_eq!(er.dst_mask_len, 16);
        }
        other => panic!("Expected ExtendedRouter, got {:?}", other),
    }
}

#[test]
fn test_parse_extended_gateway() {
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 01 00 00 00 01\n\
        0020   00 00 00 58 00 00 00 01 00 00 00 03 00 00 01 00\n\
        0030   00 00 03 e8 00 00 00 00 00 00 00 01 00 00 00 02\n\
        0040   00 00 00 01 00 00 03 eb 00 00 00 30 00 00 00 01\n\
        0050   0a 00 00 01 00 00 fd e8 00 00 fd e8 00 00 fd e9\n\
        0060   00 00 00 01 00 00 00 02 00 00 00 02 00 00 fd e9\n\
        0070   00 00 fd ea 00 00 00 01 ff ff 00 01\
    ");
    //  record: extended_gateway(0:1003), len=48
    //        addr=IPv4 next_hop=10.0.0.1
    //        as=65000 src_as=65000 peer_as=65001
    //        path_count=1 seg_type=2(SEQ) seg_len=2
    //        as_path=[65001,65002]
    //        communities_count=1 community=0xffff0001

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());

    let fs = match &result.datagrams[0].samples[0] {
        SflowSample::Flow(fs) => fs,
        other => panic!("Expected Flow, got {:?}", other),
    };
    match &fs.records[0] {
        FlowRecord::ExtendedGateway(eg) => {
            assert_eq!(eg.as_number, 65000);
            assert_eq!(eg.src_peer_as, 65001);
            assert_eq!(eg.as_path_segments.len(), 1);
            assert_eq!(eg.as_path_segments[0].segment_type, 2);
            assert_eq!(eg.as_path_segments[0].values, vec![65001, 65002]);
            assert_eq!(eg.communities, vec![0xFFFF0001]);
        }
        other => panic!("Expected ExtendedGateway, got {:?}", other),
    }
}

#[test]
fn test_parse_extended_user() {
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 01 00 00 00 01\n\
        0020   00 00 00 44 00 00 00 01 00 00 00 03 00 00 01 00\n\
        0030   00 00 03 e8 00 00 00 00 00 00 00 01 00 00 00 02\n\
        0040   00 00 00 01 00 00 03 ec 00 00 00 1c 00 00 00 00\n\
        0050   00 00 00 05 61 64 6d 69 6e 00 00 00 00 00 00 00\n\
        0060   00 00 00 04 72 6f 6f 74\
    ");
    //  record: extended_user(0:1004), len=28
    //        src_charset=0 src_user="admin"(+3 pad)
    //        dst_charset=0 dst_user="root"

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());

    let fs = match &result.datagrams[0].samples[0] {
        SflowSample::Flow(fs) => fs,
        other => panic!("Expected Flow, got {:?}", other),
    };
    match &fs.records[0] {
        FlowRecord::ExtendedUser(eu) => {
            assert_eq!(eu.src_user, "admin");
            assert_eq!(eu.dst_user, "root");
        }
        other => panic!("Expected ExtendedUser, got {:?}", other),
    }
}

#[test]
fn test_parse_extended_url() {
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 01 00 00 00 01\n\
        0020   00 00 00 4c 00 00 00 01 00 00 00 03 00 00 01 00\n\
        0030   00 00 03 e8 00 00 00 00 00 00 00 01 00 00 00 02\n\
        0040   00 00 00 01 00 00 03 ed 00 00 00 24 00 00 00 01\n\
        0050   00 00 00 0b 2f 69 6e 64 65 78 2e 68 74 6d 6c 00\n\
        0060   00 00 00 0b 65 78 61 6d 70 6c 65 2e 63 6f 6d 00\
    ");
    //  record: extended_url(0:1005), len=36
    //        direction=1
    //        url="/index.html"(+1 pad)
    //        host="example.com"(+1 pad)

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());

    let fs = match &result.datagrams[0].samples[0] {
        SflowSample::Flow(fs) => fs,
        other => panic!("Expected Flow, got {:?}", other),
    };
    match &fs.records[0] {
        FlowRecord::ExtendedUrl(eu) => {
            assert_eq!(eu.direction, 1);
            assert_eq!(eu.url, "/index.html");
            assert_eq!(eu.host, "example.com");
        }
        other => panic!("Expected ExtendedUrl, got {:?}", other),
    }
}

// === Counter Record Type Tests ===

#[test]
fn test_parse_generic_interface() {
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 01 00 00 00 02\n\
        0020   00 00 00 6c 00 00 00 01 00 00 00 01 00 00 00 01\n\
        0030   00 00 00 01 00 00 00 58 00 00 00 01 00 00 00 06\n\
        0040   00 00 00 00 3b 9a ca 00 00 00 00 01 00 00 00 03\n\
        0050   00 00 00 00 00 0f 42 40 00 00 01 f4 00 00 00 0a\n\
        0060   00 00 00 05 00 00 00 00 00 00 00 00 00 00 00 00\n\
        0070   00 00 00 00 00 1e 84 80 00 00 02 58 00 00 00 14\n\
        0080   00 00 00 08 00 00 00 01 00 00 00 00 00 00 00 00\
    ");
    //  sample: counter, len=108
    //  counter: seq=1 src_id=1 records=1
    //  record: generic_interface(0:1), len=88
    //        if_index=1 if_type=6(eth) if_speed=1G
    //        direction=1 status=3
    //        in_octets=1M in_ucast=500 in_mcast=10
    //        in_bcast=5 in_discard=0 in_err=0
    //        in_unknown=0 out_octets=2M out_ucast=600
    //        out_mcast=20 out_bcast=8 out_discard=1
    //        out_err=0 promiscuous=0

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());

    let cs = match &result.datagrams[0].samples[0] {
        SflowSample::Counter(cs) => cs,
        other => panic!("Expected Counter, got {:?}", other),
    };
    match &cs.records[0] {
        CounterRecord::GenericInterface(gi) => {
            assert_eq!(gi.if_index, 1);
            assert_eq!(gi.if_type, 6);
            assert_eq!(gi.if_speed, 1_000_000_000);
            assert_eq!(gi.if_in_octets, 1_000_000);
            assert_eq!(gi.if_out_octets, 2_000_000);
            assert_eq!(gi.if_in_ucast_pkts, 500);
        }
        other => {
            panic!("Expected GenericInterface, got {:?}", other)
        }
    }
}

#[test]
fn test_parse_ethernet_interface() {
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 01 00 00 00 02\n\
        0020   00 00 00 48 00 00 00 01 00 00 00 01 00 00 00 01\n\
        0030   00 00 00 02 00 00 00 34 00 00 00 00 00 00 00 01\n\
        0040   00 00 00 02 00 00 00 03 00 00 00 04 00 00 00 05\n\
        0050   00 00 00 06 00 00 00 07 00 00 00 08 00 00 00 09\n\
        0060   00 00 00 0a 00 00 00 0b 00 00 00 0c\
    ");
    //  sample: counter, len=72
    //  counter: seq=1 src_id=1 records=1
    //  record: ethernet_interface(0:2), len=52
    //        13 sequential u32 fields (0..12)

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());

    let cs = match &result.datagrams[0].samples[0] {
        SflowSample::Counter(cs) => cs,
        other => panic!("Expected Counter, got {:?}", other),
    };
    match &cs.records[0] {
        CounterRecord::EthernetInterface(ei) => {
            assert_eq!(ei.dot3_stats_alignment_errors, 0);
            assert_eq!(ei.dot3_stats_fcs_errors, 1);
            assert_eq!(ei.dot3_stats_symbol_errors, 12);
        }
        other => {
            panic!("Expected EthernetInterface, got {:?}", other)
        }
    }
}

#[test]
fn test_parse_processor() {
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 01 00 00 00 02\n\
        0020   00 00 00 30 00 00 00 01 00 00 00 01 00 00 00 01\n\
        0030   00 00 03 e9 00 00 00 1c 00 00 00 0a 00 00 00 0f\n\
        0040   00 00 00 0c 00 00 00 01 dc d6 50 00 00 00 00 00\n\
        0050   ee 6b 28 00\
    ");
    //  sample: counter, len=48
    //  counter: seq=1 src_id=1 records=1
    //  record: processor(0:1001), len=28
    //        cpu_5s=10 cpu_1m=15 cpu_5m=12
    //        total_mem=8G free_mem=4G

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());

    let cs = match &result.datagrams[0].samples[0] {
        SflowSample::Counter(cs) => cs,
        other => panic!("Expected Counter, got {:?}", other),
    };
    match &cs.records[0] {
        CounterRecord::Processor(p) => {
            assert_eq!(p.cpu_5s, 10);
            assert_eq!(p.cpu_1m, 15);
            assert_eq!(p.cpu_5m, 12);
            assert_eq!(p.total_memory, 8_000_000_000);
            assert_eq!(p.free_memory, 4_000_000_000);
        }
        other => panic!("Expected Processor, got {:?}", other),
    }
}

// === Unknown Record Handling ===

#[test]
fn test_unknown_sample_type() {
    // datagram header (1 sample) + unknown sample (enterprise=99, format=1)
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 01 00 06 30 01\n\
        0020   00 00 00 04 de ad be ef\
    ");

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());

    match &result.datagrams[0].samples[0] {
        SflowSample::Unknown {
            enterprise,
            format,
            data,
        } => {
            assert_eq!(*enterprise, 99);
            assert_eq!(*format, 1);
            assert_eq!(data, &[0xDE, 0xAD, 0xBE, 0xEF]);
        }
        other => panic!("Expected Unknown sample, got {:?}", other),
    }
}

#[test]
fn test_unknown_flow_record() {
    // datagram header + flow sample + unknown record (0:999)
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 01 00 00 00 01\n\
        0020   00 00 00 2c 00 00 00 01 00 00 00 03 00 00 01 00\n\
        0030   00 00 03 e8 00 00 00 00 00 00 00 01 00 00 00 02\n\
        0040   00 00 00 01 00 00 03 e7 00 00 00 04 01 02 03 04\
    ");

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());

    let fs = match &result.datagrams[0].samples[0] {
        SflowSample::Flow(fs) => fs,
        other => panic!("Expected Flow, got {:?}", other),
    };
    match &fs.records[0] {
        FlowRecord::Unknown {
            enterprise,
            format,
            data,
        } => {
            assert_eq!(*enterprise, 0);
            assert_eq!(*format, 999);
            assert_eq!(data, &[0x01, 0x02, 0x03, 0x04]);
        }
        other => panic!("Expected Unknown record, got {:?}", other),
    }
}

#[test]
fn test_unknown_counter_record() {
    // datagram header + counter sample + unknown record (enterprise=5, format=42)
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 01 00 00 00 02\n\
        0020   00 00 00 18 00 00 00 01 00 00 00 01 00 00 00 01\n\
        0030   00 00 50 2a 00 00 00 04 01 02 03 04\
    ");

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());

    let cs = match &result.datagrams[0].samples[0] {
        SflowSample::Counter(cs) => cs,
        other => panic!("Expected Counter, got {:?}", other),
    };
    match &cs.records[0] {
        CounterRecord::Unknown {
            enterprise,
            format,
            data,
        } => {
            assert_eq!(*enterprise, 5);
            assert_eq!(*format, 42);
            assert_eq!(data, &[0x01, 0x02, 0x03, 0x04]);
        }
        other => panic!("Expected Unknown record, got {:?}", other),
    }
}

// === Builder / API Tests ===

#[test]
fn test_max_samples_limit() {
    // Datagram header claiming 2 samples, parser limited to 1
    let mut data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 02\
    ");
    // Two identical empty flow samples
    let empty_flow = h("\
        0000   00 00 00 01 00 00 00 20 00 00 00 01 00 00 00 03\n\
        0010   00 00 01 00 00 00 03 e8 00 00 00 00 00 00 00 01\n\
        0020   00 00 00 02 00 00 00 00\
    ");
    data.extend_from_slice(&empty_flow);
    data.extend_from_slice(&empty_flow);

    let parser = SflowParser::builder().with_max_samples(1).build();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_some());
    match result.error.unwrap() {
        SflowError::TooManySamples { count, max } => {
            assert_eq!(count, 2);
            assert_eq!(max, 1);
        }
        other => panic!("Expected TooManySamples, got {:?}", other),
    }
}

#[test]
fn test_empty_input() {
    let parser = SflowParser::default();
    let result = parser.parse_bytes(&[]);
    assert!(result.error.is_none());
    assert_eq!(result.datagrams.len(), 0);
}

#[test]
fn test_parse_result_serialization() {
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 00\
    ");
    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);

    let json = serde_json::to_string(&result).unwrap();
    let deserialized: ParseResult = serde_json::from_str(&json).unwrap();
    assert_eq!(result, deserialized);
}

// === Coverage Gap Tests ===

#[test]
fn test_parse_sampled_ethernet() {
    // datagram header + flow sample + sampled_ethernet record (format=2)
    // sampled_ethernet: length(4) + src_mac(8) + dst_mac(8) + eth_type(4) = 24 bytes
    // sample_length = flow_header(32) + record_header(8) + record_body(24) = 64 = 0x40
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 01 00 00 00 01\n\
        0020   00 00 00 40 00 00 00 01 00 00 00 03 00 00 01 00\n\
        0030   00 00 03 e8 00 00 00 00 00 00 00 01 00 00 00 02\n\
        0040   00 00 00 01 00 00 00 02 00 00 00 18 00 00 00 40\n\
        0050   aa bb cc dd ee ff 00 00 11 22 33 44 55 66 00 00\n\
        0060   00 00 08 00\
    ");

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());

    let fs = match &result.datagrams[0].samples[0] {
        SflowSample::Flow(fs) => fs,
        other => panic!("Expected Flow, got {:?}", other),
    };
    match &fs.records[0] {
        FlowRecord::SampledEthernet(se) => {
            assert_eq!(se.length, 64);
            assert_eq!(se.src_mac.to_string(), "AA:BB:CC:DD:EE:FF");
            assert_eq!(se.dst_mac.to_string(), "11:22:33:44:55:66");
            assert_eq!(se.eth_type, 0x0800);
        }
        other => panic!("Expected SampledEthernet, got {:?}", other),
    }
}

#[test]
fn test_parse_error_display() {
    let err = SflowError::ParseError {
        offset: 42,
        context: ParseContext::FlowSample,
        kind: ParseErrorKind::NomError(nom::error::ErrorKind::Eof),
    };
    let msg = format!("{}", err);
    assert!(msg.contains("42"));
    assert!(msg.contains("flow sample"));
    assert!(msg.contains("Eof"));
}

#[test]
fn test_invalid_address_type() {
    // version=5, addr_type=3 (invalid — only 1=IPv4, 2=IPv6 are valid)
    let data = h("\
        0000   00 00 00 05 00 00 00 03 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 00\
    ");
    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_some());
    match result.error.unwrap() {
        SflowError::ParseError { context, kind, .. } => {
            assert_eq!(context, ParseContext::AgentAddress);
            assert_eq!(kind, ParseErrorKind::InvalidAddressType);
        }
        other => panic!("Expected ParseError for address, got {:?}", other),
    }
}

#[test]
fn test_multi_datagram_buffer() {
    // Two back-to-back datagrams in one buffer
    let single = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 00\
    ");
    let mut data = single.clone();
    data.extend_from_slice(&single);

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());
    assert_eq!(result.datagrams.len(), 2);
    assert_eq!(result.datagrams[0].sequence_number, 1);
    assert_eq!(result.datagrams[1].sequence_number, 1);
}

#[test]
fn test_extended_gateway_empty_segments() {
    // Extended gateway with 0 path segments and 0 communities
    // record_body: addr_type(4) + IPv4(4) + as(4) + src_as(4) + peer_as(4) + path_count(4) + communities_count(4) = 28
    // sample_length = flow_header(32) + record_header(8) + record_body(28) = 68 = 0x44
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 01 00 00 00 01\n\
        0020   00 00 00 44 00 00 00 01 00 00 00 03 00 00 01 00\n\
        0030   00 00 03 e8 00 00 00 00 00 00 00 01 00 00 00 02\n\
        0040   00 00 00 01 00 00 03 eb 00 00 00 1c 00 00 00 01\n\
        0050   0a 00 00 01 00 00 fd e8 00 00 fd e8 00 00 fd e9\n\
        0060   00 00 00 00 00 00 00 00\
    ");

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());

    let fs = match &result.datagrams[0].samples[0] {
        SflowSample::Flow(fs) => fs,
        other => panic!("Expected Flow, got {:?}", other),
    };
    match &fs.records[0] {
        FlowRecord::ExtendedGateway(eg) => {
            assert_eq!(eg.as_number, 65000);
            assert_eq!(eg.as_path_segments.len(), 0);
            assert_eq!(eg.communities.len(), 0);
        }
        other => panic!("Expected ExtendedGateway, got {:?}", other),
    }
}

#[test]
fn test_extended_router_ipv6_next_hop() {
    // Extended router with IPv6 next-hop
    // record_body: addr_type(4) + IPv6(16) + src_mask(4) + dst_mask(4) = 28
    // sample_length = flow_header(32) + record_header(8) + record_body(28) = 68 = 0x44
    let data = h("\
        0000   00 00 00 05 00 00 00 01 0a 00 00 01 00 00 00 00\n\
        0010   00 00 00 01 00 00 03 e8 00 00 00 01 00 00 00 01\n\
        0020   00 00 00 44 00 00 00 01 00 00 00 03 00 00 01 00\n\
        0030   00 00 03 e8 00 00 00 00 00 00 00 01 00 00 00 02\n\
        0040   00 00 00 01 00 00 03 ea 00 00 00 1c 00 00 00 02\n\
        0050   fe 80 00 00 00 00 00 00 00 00 00 00 00 00 00 01\n\
        0060   00 00 00 30 00 00 00 18\
    ");

    let parser = SflowParser::default();
    let result = parser.parse_bytes(&data);
    assert!(result.error.is_none());

    let fs = match &result.datagrams[0].samples[0] {
        SflowSample::Flow(fs) => fs,
        other => panic!("Expected Flow, got {:?}", other),
    };
    match &fs.records[0] {
        FlowRecord::ExtendedRouter(er) => {
            match &er.next_hop {
                AddressType::IPv6(addr) => {
                    assert_eq!(*addr, "fe80::1".parse::<Ipv6Addr>().unwrap());
                }
                other => panic!("Expected IPv6 next-hop, got {:?}", other),
            }
            assert_eq!(er.src_mask_len, 48);
            assert_eq!(er.dst_mask_len, 24);
        }
        other => panic!("Expected ExtendedRouter, got {:?}", other),
    }
}
