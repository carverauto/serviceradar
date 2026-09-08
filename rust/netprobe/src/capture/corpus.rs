//! A crafted packet corpus for the differential test against libpcap.
//!
//! Live traffic cannot exercise the cases where a filter compiler actually
//! goes wrong. A loopback capture produces well-formed IPv4 with no options
//! and no fragments, so a compiler missing the fragment guard or the variable
//! header length passes it identically to a correct one. Each packet below
//! exists to make one specific mistake observable:
//!
//! | packet | catches |
//! |---|---|
//! | [`ipv4_fragment_payload_looks_like_port`] | a missing 0x1fff fragment guard, which WIDENS `port` to non-first fragments |
//! | [`ipv4_with_options_tcp_443`] | a fixed 20-byte header assumption, which NARROWS `port` past every packet with options |
//! | [`arp_request_in_test_net`] / [`rarp_in_test_net`] | `host`/`net` checking only the IP header, silently under-matching |
//! | [`ipv6_tcp_443`], [`ipv6_fragment_tcp`], [`ipv6_icmp6`] | v4-only assumptions in `tcp`, `udp`, `icmp6` |
//! | [`ipv4_sctp_443`] | bare `port` failing to match SCTP, which tcpdump does match |
//! | [`ipv4_tcp_443_outbound`] | direction handled as a packet read rather than an ancillary load |
//!
//! Frames are built by hand rather than captured so the awkward cases are
//! exact and reviewable.

use super::interp::Packet;

const PACKET_HOST: u32 = 0;
pub const PACKET_OUTGOING: u32 = 4;

const ETHERTYPE_IPV4: [u8; 2] = [0x08, 0x00];
const ETHERTYPE_IPV6: [u8; 2] = [0x86, 0xdd];
const ETHERTYPE_ARP: [u8; 2] = [0x08, 0x06];
const ETHERTYPE_RARP: [u8; 2] = [0x80, 0x35];

/// 192.0.2.1 and 192.0.2.2, inside 192.0.2.0/24 — the addresses the filters
/// under test name.
const TEST_SRC: [u8; 4] = [192, 0, 2, 1];
const TEST_DST: [u8; 4] = [192, 0, 2, 2];
/// 198.51.100.1 — deliberately OUTSIDE 192.0.2.0/24.
const OTHER_SRC: [u8; 4] = [198, 51, 100, 1];

fn ethernet(ethertype: [u8; 2]) -> Vec<u8> {
    let mut frame = Vec::with_capacity(64);
    frame.extend_from_slice(&[0x02, 0x00, 0x00, 0x00, 0x00, 0x02]); // dst mac
    frame.extend_from_slice(&[0x02, 0x00, 0x00, 0x00, 0x00, 0x01]); // src mac
    frame.extend_from_slice(&ethertype);
    frame
}

/// `ihl` is in 32-bit words, so 5 is a plain header and 6 carries 4 bytes of
/// options. `frag_off_flags` is the raw big-endian flags+offset field.
fn ipv4(
    ihl: u8,
    protocol: u8,
    frag_off_flags: u16,
    src: [u8; 4],
    dst: [u8; 4],
    payload: &[u8],
) -> Vec<u8> {
    let mut frame = ethernet(ETHERTYPE_IPV4);
    let header_len = usize::from(ihl) * 4;
    let total_len = (header_len + payload.len()) as u16;

    frame.push(0x40 | ihl);
    frame.push(0x00); // dscp/ecn
    frame.extend_from_slice(&total_len.to_be_bytes());
    frame.extend_from_slice(&[0x00, 0x01]); // identification
    frame.extend_from_slice(&frag_off_flags.to_be_bytes());
    frame.push(64); // ttl
    frame.push(protocol);
    frame.extend_from_slice(&[0x00, 0x00]); // checksum, not verified by BPF
    frame.extend_from_slice(&src);
    frame.extend_from_slice(&dst);
    // Options, if any. 0x01 is NOP, which is a legal filler.
    frame.extend(std::iter::repeat_n(0x01, header_len.saturating_sub(20)));
    frame.extend_from_slice(payload);
    frame
}

fn tcp_header(src_port: u16, dst_port: u16) -> Vec<u8> {
    let mut seg = Vec::with_capacity(20);
    seg.extend_from_slice(&src_port.to_be_bytes());
    seg.extend_from_slice(&dst_port.to_be_bytes());
    seg.extend_from_slice(&[0, 0, 0, 1]); // seq
    seg.extend_from_slice(&[0, 0, 0, 0]); // ack
    seg.push(0x50); // data offset 5
    seg.push(0x02); // SYN
    seg.extend_from_slice(&[0xff, 0xff]); // window
    seg.extend_from_slice(&[0, 0, 0, 0]); // checksum + urgent
    seg
}

fn udp_header(src_port: u16, dst_port: u16) -> Vec<u8> {
    let mut dgram = Vec::with_capacity(8);
    dgram.extend_from_slice(&src_port.to_be_bytes());
    dgram.extend_from_slice(&dst_port.to_be_bytes());
    dgram.extend_from_slice(&[0x00, 0x10]); // length
    dgram.extend_from_slice(&[0x00, 0x00]); // checksum
    dgram
}

pub fn ipv4_tcp_443() -> Packet {
    Packet::new(
        ipv4(5, 6, 0x4000, TEST_SRC, TEST_DST, &tcp_header(50000, 443)),
        PACKET_HOST,
    )
}

pub fn ipv4_tcp_443_outbound() -> Packet {
    Packet::new(
        ipv4(5, 6, 0x4000, TEST_SRC, TEST_DST, &tcp_header(50000, 443)),
        PACKET_OUTGOING,
    )
}

pub fn ipv4_tcp_80() -> Packet {
    Packet::new(
        ipv4(5, 6, 0x4000, TEST_SRC, TEST_DST, &tcp_header(50000, 80)),
        PACKET_HOST,
    )
}

pub fn ipv4_udp_443() -> Packet {
    Packet::new(
        ipv4(5, 17, 0x4000, TEST_SRC, TEST_DST, &udp_header(50000, 443)),
        PACKET_HOST,
    )
}

/// SCTP on port 443. `tcpdump port 443` matches SCTP as well as TCP and UDP;
/// a compiler that checks only TCP and UDP silently under-matches.
pub fn ipv4_sctp_443() -> Packet {
    let mut chunk = Vec::new();
    chunk.extend_from_slice(&50000u16.to_be_bytes());
    chunk.extend_from_slice(&443u16.to_be_bytes());
    chunk.extend_from_slice(&[0u8; 8]);
    Packet::new(
        ipv4(5, 132, 0x4000, TEST_SRC, TEST_DST, &chunk),
        PACKET_HOST,
    )
}

/// IPv4 with `ihl = 6`: four bytes of options before the TCP header.
///
/// A compiler assuming a fixed 20-byte header reads the ports from the wrong
/// offset and misses this packet entirely — silently NARROWING the filter.
pub fn ipv4_with_options_tcp_443() -> Packet {
    Packet::new(
        ipv4(6, 6, 0x4000, TEST_SRC, TEST_DST, &tcp_header(50000, 443)),
        PACKET_HOST,
    )
}

/// A NON-FIRST IPv4 fragment whose payload bytes at the port offset happen to
/// read as 443.
///
/// There are no ports in a non-first fragment — those bytes are payload. A
/// compiler missing the `0x1fff` fragment guard matches this packet, silently
/// WIDENING the filter. That is the data-exfiltration direction the design
/// forbids, and no live-traffic test will produce this packet by accident.
pub fn ipv4_fragment_payload_looks_like_port() -> Packet {
    // Fragment offset 185 (in 8-byte units) with no MF bit: a later fragment.
    let frag_off_flags: u16 = 185;
    let payload = tcp_header(50000, 443);
    Packet::new(
        ipv4(5, 6, frag_off_flags, TEST_SRC, TEST_DST, &payload),
        PACKET_HOST,
    )
}

/// The first fragment of the same datagram, which DOES carry real ports and
/// which tcpdump matches. Included so the fragment guard cannot be "fixed" by
/// rejecting every fragment.
pub fn ipv4_first_fragment_tcp_443() -> Packet {
    let frag_off_flags: u16 = 0x2000; // MF set, offset 0
    Packet::new(
        ipv4(
            5,
            6,
            frag_off_flags,
            TEST_SRC,
            TEST_DST,
            &tcp_header(50000, 443),
        ),
        PACKET_HOST,
    )
}

pub fn ipv4_icmp_echo() -> Packet {
    let icmp = vec![0x08, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01];
    Packet::new(ipv4(5, 1, 0x4000, TEST_SRC, TEST_DST, &icmp), PACKET_HOST)
}

/// The reverse direction: 192.0.2.1 as DESTINATION.
///
/// Added because the differential test caught `dst host 192.0.2.1` matching
/// nothing in the corpus — agreement on a filter that never fires proves
/// nothing about either implementation.
pub fn ipv4_tcp_443_reverse() -> Packet {
    Packet::new(
        ipv4(5, 6, 0x4000, TEST_DST, TEST_SRC, &tcp_header(443, 50000)),
        PACKET_HOST,
    )
}

pub fn ipv4_tcp_outside_test_net() -> Packet {
    Packet::new(
        ipv4(5, 6, 0x4000, OTHER_SRC, OTHER_SRC, &tcp_header(50000, 443)),
        PACKET_HOST,
    )
}

fn ipv6(next_header: u8, payload: &[u8]) -> Vec<u8> {
    let mut frame = ethernet(ETHERTYPE_IPV6);
    frame.push(0x60); // version 6
    frame.extend_from_slice(&[0x00, 0x00, 0x00]); // traffic class + flow label
    frame.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    frame.push(next_header);
    frame.push(64); // hop limit
    frame.extend_from_slice(&[0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);
    frame.extend_from_slice(&[0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2]);
    frame.extend_from_slice(payload);
    frame
}

pub fn ipv6_tcp_443() -> Packet {
    Packet::new(ipv6(6, &tcp_header(50000, 443)), PACKET_HOST)
}

pub fn ipv6_udp_443() -> Packet {
    Packet::new(ipv6(17, &udp_header(50000, 443)), PACKET_HOST)
}

pub fn ipv6_icmp6() -> Packet {
    Packet::new(ipv6(58, &[0x80, 0x00, 0x00, 0x00]), PACKET_HOST)
}

/// IPv6 carrying a fragment header (next-header 44) ahead of TCP.
///
/// tcpdump follows exactly one fragment header to a second protocol byte at
/// offset 54; this packet is what distinguishes a compiler that does from one
/// that stops at the first next-header field.
pub fn ipv6_fragment_tcp() -> Packet {
    let mut payload = Vec::new();
    payload.push(6); // next header: TCP
    payload.push(0); // reserved
    payload.extend_from_slice(&[0x00, 0x01]); // fragment offset + M flag
    payload.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]); // identification
    payload.extend_from_slice(&tcp_header(50000, 443));
    Packet::new(ipv6(44, &payload), PACKET_HOST)
}

fn arp_like(ethertype: [u8; 2], sender: [u8; 4], target: [u8; 4]) -> Vec<u8> {
    let mut frame = ethernet(ethertype);
    frame.extend_from_slice(&[0x00, 0x01]); // hardware type: Ethernet
    frame.extend_from_slice(&ETHERTYPE_IPV4); // protocol type
    frame.push(6); // hardware size
    frame.push(4); // protocol size
    frame.extend_from_slice(&[0x00, 0x01]); // opcode: request
    frame.extend_from_slice(&[0x02, 0x00, 0x00, 0x00, 0x00, 0x01]); // sender mac
    frame.extend_from_slice(&sender); // sender protocol address, offset 28
    frame.extend_from_slice(&[0x00, 0x00, 0x00, 0x00, 0x00, 0x00]); // target mac
    frame.extend_from_slice(&target); // target protocol address, offset 38
    frame
}

/// An ARP request whose sender/target protocol addresses fall inside the
/// tested host and net.
///
/// tcpdump's `host` and `net` match these, not just the IPv4 header. A
/// compiler that checks only the IP header silently under-matches, and the gap
/// never shows on IP-only traffic.
pub fn arp_request_in_test_net() -> Packet {
    Packet::new(arp_like(ETHERTYPE_ARP, TEST_SRC, TEST_DST), PACKET_HOST)
}

pub fn arp_request_outside_test_net() -> Packet {
    Packet::new(arp_like(ETHERTYPE_ARP, OTHER_SRC, OTHER_SRC), PACKET_HOST)
}

pub fn rarp_in_test_net() -> Packet {
    Packet::new(arp_like(ETHERTYPE_RARP, TEST_SRC, TEST_DST), PACKET_HOST)
}

/// Every packet, with a stable name for failure messages.
pub fn all() -> Vec<(&'static str, Packet)> {
    vec![
        ("ipv4_tcp_443", ipv4_tcp_443()),
        ("ipv4_tcp_443_outbound", ipv4_tcp_443_outbound()),
        ("ipv4_tcp_80", ipv4_tcp_80()),
        ("ipv4_udp_443", ipv4_udp_443()),
        ("ipv4_sctp_443", ipv4_sctp_443()),
        ("ipv4_with_options_tcp_443", ipv4_with_options_tcp_443()),
        (
            "ipv4_fragment_payload_looks_like_port",
            ipv4_fragment_payload_looks_like_port(),
        ),
        ("ipv4_first_fragment_tcp_443", ipv4_first_fragment_tcp_443()),
        ("ipv4_icmp_echo", ipv4_icmp_echo()),
        ("ipv4_tcp_443_reverse", ipv4_tcp_443_reverse()),
        ("ipv4_tcp_outside_test_net", ipv4_tcp_outside_test_net()),
        ("ipv6_tcp_443", ipv6_tcp_443()),
        ("ipv6_udp_443", ipv6_udp_443()),
        ("ipv6_icmp6", ipv6_icmp6()),
        ("ipv6_fragment_tcp", ipv6_fragment_tcp()),
        ("arp_request_in_test_net", arp_request_in_test_net()),
        (
            "arp_request_outside_test_net",
            arp_request_outside_test_net(),
        ),
        ("rarp_in_test_net", rarp_in_test_net()),
    ]
}
