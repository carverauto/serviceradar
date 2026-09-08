use arancini_lib::update::Update;
use serde::Serialize;
use std::net::IpAddr;

#[derive(Debug, Serialize)]
pub struct UpdatePayload<'a> {
    pub time_received_ns: String,
    pub time_bmp_header_ns: String,
    pub router_addr: String,
    pub router_port: u16,
    pub peer_addr: String,
    pub peer_bgp_id: String,
    pub peer_asn: u32,
    pub prefix_addr: String,
    pub prefix_len: u8,
    pub is_post_policy: bool,
    pub is_adj_rib_out: bool,
    pub announced: bool,
    pub synthetic: bool,
    pub attrs: UpdateAttrs<'a>,
}

#[derive(Debug, Serialize)]
pub struct UpdateAttrs<'a> {
    pub origin: &'a str,
    pub as_path: &'a [u32],
    pub next_hop: Option<String>,
    pub multi_exit_discriminator: Option<u32>,
    pub local_preference: Option<u32>,
    pub only_to_customer: Option<u32>,
    pub atomic_aggregate: bool,
    pub aggregator_asn: Option<u32>,
    pub aggregator_bgp_id: Option<u32>,
    pub communities: &'a [(u32, u16)],
    pub extended_communities: &'a [(u8, u8, Vec<u8>)],
    pub large_communities: &'a [(u32, u32, u32)],
    pub originator_id: Option<u32>,
    pub cluster_list: &'a [u32],
    pub mp_reach_afi: Option<u16>,
    pub mp_reach_safi: Option<u8>,
    pub mp_unreach_afi: Option<u16>,
    pub mp_unreach_safi: Option<u8>,
}

pub fn to_payload(update: &Update) -> UpdatePayload<'_> {
    UpdatePayload {
        time_received_ns: update.time_received_ns.to_rfc3339(),
        time_bmp_header_ns: update.time_bmp_header_ns.to_rfc3339(),
        router_addr: canonical_ip_string(update.router_addr),
        router_port: update.router_port,
        peer_addr: canonical_ip_string(update.peer_addr),
        peer_bgp_id: update.peer_bgp_id.to_string(),
        peer_asn: update.peer_asn,
        prefix_addr: canonical_ip_string(update.prefix_addr),
        prefix_len: update.prefix_len,
        is_post_policy: update.is_post_policy,
        is_adj_rib_out: update.is_adj_rib_out,
        announced: update.announced,
        synthetic: update.synthetic,
        attrs: UpdateAttrs {
            origin: update.attrs.origin.as_str(),
            as_path: update.attrs.as_path.as_slice(),
            next_hop: update.attrs.next_hop.map(canonical_ip_string),
            multi_exit_discriminator: update.attrs.multi_exit_discriminator,
            local_preference: update.attrs.local_preference,
            only_to_customer: update.attrs.only_to_customer,
            atomic_aggregate: update.attrs.atomic_aggregate,
            aggregator_asn: update.attrs.aggregator_asn,
            aggregator_bgp_id: update.attrs.aggregator_bgp_id,
            communities: update.attrs.communities.as_slice(),
            extended_communities: update.attrs.extended_communities.as_slice(),
            large_communities: update.attrs.large_communities.as_slice(),
            originator_id: update.attrs.originator_id,
            cluster_list: update.attrs.cluster_list.as_slice(),
            mp_reach_afi: update.attrs.mp_reach_afi,
            mp_reach_safi: update.attrs.mp_reach_safi,
            mp_unreach_afi: update.attrs.mp_unreach_afi,
            mp_unreach_safi: update.attrs.mp_unreach_safi,
        },
    }
}

// Arancini uses IPv4-mapped IPv6 addresses internally so its fixed-width wire
// representations and state keys work uniformly. The ServiceRadar JSON event
// contract is human-facing, however: render only the mapped form as IPv4 while
// preserving genuine IPv6 addresses.
fn canonical_ip_string(ip: IpAddr) -> String {
    match ip {
        IpAddr::V4(v4) => v4.to_string(),
        IpAddr::V6(v6) => v6
            .to_ipv4_mapped()
            .map(IpAddr::V4)
            .unwrap_or(IpAddr::V6(v6))
            .to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use arancini_lib::update::UpdateAttributes;
    use chrono::Utc;
    use std::net::{Ipv4Addr, Ipv6Addr};
    use std::sync::Arc;

    fn update(
        router_addr: IpAddr,
        peer_addr: IpAddr,
        prefix_addr: IpAddr,
        next_hop: Option<IpAddr>,
    ) -> Update {
        Update {
            time_received_ns: Utc::now(),
            time_bmp_header_ns: Utc::now(),
            router_addr,
            router_port: 11_019,
            peer_addr,
            peer_bgp_id: Ipv4Addr::new(192, 0, 2, 1),
            peer_asn: 64_512,
            prefix_addr,
            prefix_len: 24,
            is_post_policy: false,
            is_adj_rib_out: false,
            announced: true,
            synthetic: false,
            attrs: Arc::new(UpdateAttributes {
                next_hop,
                ..Default::default()
            }),
        }
    }

    #[test]
    fn payload_converts_ipv4_mapped_addresses_to_ipv4() {
        let mapped = |octets: [u8; 4]| IpAddr::V6(Ipv4Addr::from(octets).to_ipv6_mapped());

        let event = update(
            mapped([10, 42, 57, 39]),
            mapped([169, 254, 0, 179]),
            mapped([10, 43, 73, 194]),
            Some(mapped([10, 42, 57, 1])),
        );
        let payload = serde_json::to_value(to_payload(&event)).expect("serialize BMP payload");

        assert_eq!(payload["router_addr"], "10.42.57.39");
        assert_eq!(payload["peer_addr"], "169.254.0.179");
        assert_eq!(payload["prefix_addr"], "10.43.73.194");
        assert_eq!(payload["attrs"]["next_hop"], "10.42.57.1");
    }

    #[test]
    fn payload_preserves_genuine_ipv6_addresses() {
        let router: Ipv6Addr = "2001:db8:1::39".parse().unwrap();
        let peer: Ipv6Addr = "2001:db8:2::179".parse().unwrap();
        let prefix: Ipv6Addr = "2001:db8:3::".parse().unwrap();
        let next_hop: Ipv6Addr = "2001:db8:4::1".parse().unwrap();
        let expected_next_hop = next_hop.to_string();

        let event = update(
            IpAddr::V6(router),
            IpAddr::V6(peer),
            IpAddr::V6(prefix),
            Some(IpAddr::V6(next_hop)),
        );
        let payload = serde_json::to_value(to_payload(&event)).expect("serialize BMP payload");

        assert_eq!(payload["router_addr"], router.to_string());
        assert_eq!(payload["peer_addr"], peer.to_string());
        assert_eq!(payload["prefix_addr"], prefix.to_string());
        assert_eq!(payload["attrs"]["next_hop"], expected_next_hop);
    }
}
