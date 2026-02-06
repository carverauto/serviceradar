use log::{debug, warn};
use std::net::IpAddr;

pub mod mdnspb {
    include!(concat!(env!("OUT_DIR"), "/mdnspb.rs"));
}

/// Parse a raw DNS packet and extract mDNS records (A, AAAA, PTR) from the answer
/// and additional sections.
pub fn parse_mdns_packet(
    data: &[u8],
    source_ip: IpAddr,
    time_received_ns: u64,
) -> Vec<mdnspb::MdnsRecord> {
    let packet = match simple_dns::Packet::parse(data) {
        Ok(p) => p,
        Err(e) => {
            warn!("Failed to parse DNS packet: {}", e);
            return vec![];
        }
    };

    let is_response = packet.has_flags(simple_dns::PacketFlag::RESPONSE);

    // Only process responses (QR bit set)
    if !is_response {
        debug!("Ignoring mDNS query packet");
        return vec![];
    }

    let source_ip_bytes = ip_to_bytes(&source_ip);
    let mut records = Vec::new();

    // Process answers and additional records
    let all_records = packet
        .answers
        .iter()
        .chain(packet.additional_records.iter());

    for resource in all_records {
        let dns_name = resource.name.to_string();
        let dns_ttl = resource.ttl;

        match &resource.rdata {
            simple_dns::rdata::RData::A(a) => {
                let addr = std::net::Ipv4Addr::from(a.address);
                records.push(mdnspb::MdnsRecord {
                    record_type: i32::from(mdnspb::mdns_record::RecordType::A),
                    time_received_ns,
                    source_ip: source_ip_bytes.clone(),
                    hostname: dns_name.clone(),
                    resolved_addr: addr.octets().to_vec(),
                    resolved_addr_str: addr.to_string(),
                    dns_ttl,
                    dns_name,
                    is_response,
                });
            }
            simple_dns::rdata::RData::AAAA(aaaa) => {
                let addr = std::net::Ipv6Addr::from(aaaa.address);
                records.push(mdnspb::MdnsRecord {
                    record_type: i32::from(mdnspb::mdns_record::RecordType::Aaaa),
                    time_received_ns,
                    source_ip: source_ip_bytes.clone(),
                    hostname: dns_name.clone(),
                    resolved_addr: addr.octets().to_vec(),
                    resolved_addr_str: addr.to_string(),
                    dns_ttl,
                    dns_name,
                    is_response,
                });
            }
            simple_dns::rdata::RData::PTR(ptr) => {
                let target = ptr.0.to_string();
                records.push(mdnspb::MdnsRecord {
                    record_type: i32::from(mdnspb::mdns_record::RecordType::Ptr),
                    time_received_ns,
                    source_ip: source_ip_bytes.clone(),
                    hostname: target,
                    resolved_addr: vec![],
                    resolved_addr_str: String::new(),
                    dns_ttl,
                    dns_name,
                    is_response,
                });
            }
            _ => {
                debug!("Ignoring unsupported DNS record type in: {}", dns_name);
            }
        }
    }

    records
}

fn ip_to_bytes(ip: &IpAddr) -> Vec<u8> {
    match ip {
        IpAddr::V4(addr) => addr.octets().to_vec(),
        IpAddr::V6(addr) => addr.octets().to_vec(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use simple_dns::{rdata, Name, Packet, PacketFlag, ResourceRecord, CLASS};

    fn build_response_packet(records: Vec<ResourceRecord<'_>>) -> Vec<u8> {
        let mut packet = Packet::new_reply(0);
        packet.set_flags(PacketFlag::AUTHORITATIVE_ANSWER);
        for record in records {
            packet.answers.push(record);
        }
        packet.build_bytes_vec().unwrap()
    }

    fn build_query_packet() -> Vec<u8> {
        let mut packet = Packet::new_query(0);
        packet
            .questions
            .push(simple_dns::Question::new(
                Name::new_unchecked("_http._tcp.local"),
                simple_dns::QTYPE::TYPE(simple_dns::TYPE::PTR),
                simple_dns::QCLASS::CLASS(CLASS::IN),
                false,
            ));
        packet.build_bytes_vec().unwrap()
    }

    #[test]
    fn test_parse_a_record() {
        let rr = ResourceRecord::new(
            Name::new_unchecked("mydevice.local"),
            CLASS::IN,
            120,
            rdata::RData::A(rdata::A {
                address: u32::from(std::net::Ipv4Addr::new(192, 168, 1, 42)),
            }),
        );
        let data = build_response_packet(vec![rr]);
        let source = IpAddr::V4(std::net::Ipv4Addr::new(192, 168, 1, 42));
        let records = parse_mdns_packet(&data, source, 1_000_000_000);

        assert_eq!(records.len(), 1);
        assert_eq!(
            records[0].record_type,
            i32::from(mdnspb::mdns_record::RecordType::A)
        );
        assert_eq!(records[0].hostname, "mydevice.local");
        assert_eq!(records[0].resolved_addr, vec![192, 168, 1, 42]);
        assert_eq!(records[0].resolved_addr_str, "192.168.1.42");
        assert_eq!(records[0].dns_ttl, 120);
        assert!(records[0].is_response);
    }

    #[test]
    fn test_parse_aaaa_record() {
        let addr = std::net::Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 1);
        let rr = ResourceRecord::new(
            Name::new_unchecked("mydevice.local"),
            CLASS::IN,
            120,
            rdata::RData::AAAA(rdata::AAAA {
                address: u128::from(addr),
            }),
        );
        let data = build_response_packet(vec![rr]);
        let source = IpAddr::V4(std::net::Ipv4Addr::new(192, 168, 1, 42));
        let records = parse_mdns_packet(&data, source, 1_000_000_000);

        assert_eq!(records.len(), 1);
        assert_eq!(
            records[0].record_type,
            i32::from(mdnspb::mdns_record::RecordType::Aaaa)
        );
        assert_eq!(records[0].hostname, "mydevice.local");
        assert_eq!(records[0].resolved_addr, addr.octets().to_vec());
        assert_eq!(records[0].resolved_addr_str, "fe80::1");
    }

    #[test]
    fn test_parse_ptr_record() {
        let rr = ResourceRecord::new(
            Name::new_unchecked("_http._tcp.local"),
            CLASS::IN,
            4500,
            rdata::RData::PTR(rdata::PTR(Name::new_unchecked("mywebserver._http._tcp.local"))),
        );
        let data = build_response_packet(vec![rr]);
        let source = IpAddr::V4(std::net::Ipv4Addr::new(192, 168, 1, 10));
        let records = parse_mdns_packet(&data, source, 2_000_000_000);

        assert_eq!(records.len(), 1);
        assert_eq!(
            records[0].record_type,
            i32::from(mdnspb::mdns_record::RecordType::Ptr)
        );
        assert_eq!(records[0].hostname, "mywebserver._http._tcp.local");
        assert_eq!(records[0].dns_name, "_http._tcp.local");
        assert!(records[0].resolved_addr.is_empty());
        assert!(records[0].resolved_addr_str.is_empty());
        assert_eq!(records[0].dns_ttl, 4500);
    }

    #[test]
    fn test_ignores_queries() {
        let data = build_query_packet();
        let source = IpAddr::V4(std::net::Ipv4Addr::new(192, 168, 1, 10));
        let records = parse_mdns_packet(&data, source, 1_000_000_000);
        assert!(records.is_empty());
    }

    #[test]
    fn test_multiple_records() {
        let rr_a = ResourceRecord::new(
            Name::new_unchecked("device-a.local"),
            CLASS::IN,
            120,
            rdata::RData::A(rdata::A {
                address: u32::from(std::net::Ipv4Addr::new(10, 0, 0, 1)),
            }),
        );
        let rr_ptr = ResourceRecord::new(
            Name::new_unchecked("_tcp.local"),
            CLASS::IN,
            300,
            rdata::RData::PTR(rdata::PTR(Name::new_unchecked("device-a._tcp.local"))),
        );
        let data = build_response_packet(vec![rr_a, rr_ptr]);
        let source = IpAddr::V4(std::net::Ipv4Addr::new(10, 0, 0, 1));
        let records = parse_mdns_packet(&data, source, 1_000_000_000);

        assert_eq!(records.len(), 2);
        assert_eq!(
            records[0].record_type,
            i32::from(mdnspb::mdns_record::RecordType::A)
        );
        assert_eq!(
            records[1].record_type,
            i32::from(mdnspb::mdns_record::RecordType::Ptr)
        );
    }

    #[test]
    fn test_invalid_packet() {
        let records = parse_mdns_packet(
            &[0xff, 0xff, 0xff],
            IpAddr::V4(std::net::Ipv4Addr::new(10, 0, 0, 1)),
            1_000_000_000,
        );
        assert!(records.is_empty());
    }

    #[test]
    fn test_source_ip_bytes_v4() {
        let rr = ResourceRecord::new(
            Name::new_unchecked("test.local"),
            CLASS::IN,
            60,
            rdata::RData::A(rdata::A {
                address: u32::from(std::net::Ipv4Addr::new(10, 0, 0, 5)),
            }),
        );
        let data = build_response_packet(vec![rr]);
        let source = IpAddr::V4(std::net::Ipv4Addr::new(192, 168, 1, 100));
        let records = parse_mdns_packet(&data, source, 1_000_000_000);

        assert_eq!(records[0].source_ip, vec![192, 168, 1, 100]);
    }
}
