use bgpkit_parser::bmp::messages::{BmpMessage, PerPeerFlags, RouteMonitoring};
use bgpkit_parser::models::*;
use chrono::{DateTime, TimeZone, Utc};
use core::net::IpAddr;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;
use tracing::warn;

#[derive(Debug, Clone, PartialEq)]
pub struct UpdateMetadata {
    pub time_bmp_header_ns: i64,
    pub router_socket: SocketAddr,
    pub peer_addr: IpAddr,
    pub peer_bgp_id: Ipv4Addr,
    pub peer_asn: u32,
    pub is_post_policy: bool,
    pub is_adj_rib_out: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Update {
    pub time_received_ns: DateTime<Utc>,
    pub time_bmp_header_ns: DateTime<Utc>,
    pub router_addr: IpAddr,
    pub router_port: u16,
    pub peer_addr: IpAddr,
    pub peer_bgp_id: Ipv4Addr,
    pub peer_asn: u32,
    pub prefix_addr: IpAddr,
    pub prefix_len: u8,
    pub is_post_policy: bool,
    pub is_adj_rib_out: bool,
    pub announced: bool,
    pub synthetic: bool,
    pub attrs: Arc<UpdateAttributes>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct UpdateAttributes {
    pub origin: String,
    pub as_path: Vec<u32>,
    pub next_hop: Option<IpAddr>,
    pub multi_exit_discriminator: Option<u32>,
    pub local_preference: Option<u32>,
    pub only_to_customer: Option<u32>,
    pub atomic_aggregate: bool,
    pub aggregator_asn: Option<u32>,
    pub aggregator_bgp_id: Option<u32>,
    pub communities: Vec<(u32, u16)>,
    pub extended_communities: Vec<(u8, u8, Vec<u8>)>, // (type_high, type_low, value)
    pub large_communities: Vec<(u32, u32, u32)>,      // (global_admin, local_data1, local_data2)
    pub originator_id: Option<u32>,
    pub cluster_list: Vec<u32>,
    pub mp_reach_afi: Option<u16>,
    pub mp_reach_safi: Option<u8>,
    pub mp_unreach_afi: Option<u16>,
    pub mp_unreach_safi: Option<u8>,
}

impl UpdateAttributes {
    pub fn synthetic_withdraw() -> Self {
        Self {
            origin: "INCOMPLETE".to_string(),
            ..Default::default()
        }
    }
}

impl Update {
    /// Generate a partition key for streaming pipelines based on router and peer
    /// This ensures all updates for the same router/peer combination
    /// are routed to the same partition for ordered processing
    pub fn partition_key(&self) -> String {
        format!("{}:{}", self.router_addr, self.peer_addr)
    }
}

pub fn decode_updates(message: RouteMonitoring, metadata: UpdateMetadata) -> Option<Vec<Update>> {
    let bgp_update = match message.bgp_message {
        bgpkit_parser::models::BgpMessage::Update(update) => update,
        _ => return None,
    };

    // Collect all prefixes with their announcement status in one go
    let prefixes_to_update: Vec<_> = bgp_update
        .announced_prefixes
        .into_iter()
        .map(|p| (p, true))
        .chain(
            bgp_update
                .withdrawn_prefixes
                .into_iter()
                .map(|p| (p, false)),
        )
        .chain(
            bgp_update
                .attributes
                .get_reachable_nlri()
                .map(|nlri| nlri.prefixes.iter().map(|&p| (p, true)))
                .into_iter()
                .flatten(),
        )
        .chain(
            bgp_update
                .attributes
                .get_unreachable_nlri()
                .map(|nlri| nlri.prefixes.iter().map(|&p| (p, false)))
                .into_iter()
                .flatten(),
        )
        .collect();

    if prefixes_to_update.is_empty() {
        return None;
    }

    // Extract all attributes once
    let attributes = &bgp_update.attributes;
    let communities: Vec<MetaCommunity> = attributes.iter_communities().collect();

    // Parse timestamp once
    let time_bmp_header_ns = Utc
        .timestamp_millis_opt(metadata.time_bmp_header_ns)
        .single()
        .unwrap_or_else(|| {
            warn!(
                "failed to parse timestamp: {}, using Utc::now()",
                metadata.time_bmp_header_ns
            );
            Utc::now()
        });

    let shared_attrs = Arc::new(UpdateAttributes {
        origin: attributes.origin().to_string(),
        as_path: new_path(attributes.as_path().cloned()),
        next_hop: attributes.next_hop().map(map_to_ipv6),
        multi_exit_discriminator: attributes.multi_exit_discriminator(),
        local_preference: attributes.local_preference(),
        only_to_customer: attributes.only_to_customer().map(|asn| asn.to_u32()),
        atomic_aggregate: attributes.atomic_aggregate(),
        aggregator_asn: attributes.aggregator().map(|(asn, _)| asn.to_u32()),
        aggregator_bgp_id: attributes.aggregator().map(|(_, id)| u32::from(id)),
        communities: new_communities(&communities),
        extended_communities: extract_extended_communities(&communities),
        large_communities: extract_large_communities(&communities),
        originator_id: attributes.origin_id().map(u32::from),
        cluster_list: attributes.clusters().map_or_else(Vec::new, |c| c.to_vec()),
        mp_reach_afi: attributes.get_reachable_nlri().map(|nlri| match nlri.afi {
            bgpkit_parser::models::Afi::Ipv4 => 1u16,
            bgpkit_parser::models::Afi::Ipv6 => 2u16,
            bgpkit_parser::models::Afi::LinkState => 16388u16,
        }),
        mp_reach_safi: attributes.get_reachable_nlri().map(|nlri| match nlri.safi {
            bgpkit_parser::models::Safi::Unicast => 1u8,
            bgpkit_parser::models::Safi::Multicast => 2u8,
            _ => 0u8,
        }),
        mp_unreach_afi: attributes
            .get_unreachable_nlri()
            .map(|nlri| match nlri.afi {
                bgpkit_parser::models::Afi::Ipv4 => 1u16,
                bgpkit_parser::models::Afi::Ipv6 => 2u16,
                bgpkit_parser::models::Afi::LinkState => 16388u16,
            }),
        mp_unreach_safi: attributes
            .get_unreachable_nlri()
            .map(|nlri| match nlri.safi {
                bgpkit_parser::models::Safi::Unicast => 1u8,
                bgpkit_parser::models::Safi::Multicast => 2u8,
                _ => 0u8,
            }),
    });

    // Create base update template to avoid repetition
    let base_update = Update {
        time_received_ns: Utc::now(),
        time_bmp_header_ns,
        router_addr: map_to_ipv6(metadata.router_socket.ip()),
        router_port: metadata.router_socket.port(),
        peer_addr: map_to_ipv6(metadata.peer_addr),
        peer_bgp_id: metadata.peer_bgp_id,
        peer_asn: metadata.peer_asn,
        is_post_policy: metadata.is_post_policy,
        is_adj_rib_out: metadata.is_adj_rib_out,
        synthetic: false,
        attrs: shared_attrs,

        // These will be overridden per prefix
        prefix_addr: std::net::IpAddr::V4(std::net::Ipv4Addr::UNSPECIFIED),
        prefix_len: 0,
        announced: false,
    };

    // Generate updates for each prefix
    let updates = prefixes_to_update
        .into_iter()
        .map(|(prefix, announced)| Update {
            prefix_addr: map_to_ipv6(prefix.prefix.addr()),
            prefix_len: prefix.prefix.prefix_len(),
            announced,
            ..base_update.clone()
        })
        .collect();

    Some(updates)
}

pub fn new_metadata(socket: SocketAddr, message: &BmpMessage) -> Option<UpdateMetadata> {
    // Get peer information
    let pph = message.per_peer_header?;
    let peer = Peer::new(pph.peer_bgp_id, pph.peer_ip, pph.peer_asn);

    // Get header information
    let time_bmp_header_ns = (pph.timestamp * 1000.0) as i64;

    let is_post_policy = match pph.peer_flags {
        PerPeerFlags::PeerFlags(flags) => flags.is_post_policy(),
        PerPeerFlags::LocalRibPeerFlags(_) => false,
    };

    let is_adj_rib_out = match pph.peer_flags {
        PerPeerFlags::PeerFlags(flags) => flags.is_adj_rib_out(),
        PerPeerFlags::LocalRibPeerFlags(_) => false,
    };

    Some(UpdateMetadata {
        time_bmp_header_ns,
        router_socket: socket,
        peer_addr: peer.peer_ip,
        peer_bgp_id: peer.peer_bgp_id,
        peer_asn: peer.peer_asn.to_u32(),
        is_post_policy,
        is_adj_rib_out,
    })
}

pub fn new_peer_from_metadata(metadata: UpdateMetadata) -> Peer {
    Peer::new(
        metadata.peer_bgp_id,
        metadata.peer_addr,
        Asn::new_32bit(metadata.peer_asn),
    )
}

pub fn new_path(path: Option<AsPath>) -> Vec<u32> {
    match path {
        Some(mut path) => {
            let mut constructed_path: Vec<u32> = Vec::new();
            path.coalesce();
            for segment in path.into_segments_iter() {
                if let AsPathSegment::AsSequence(dedup_asns) = segment {
                    for asn in dedup_asns {
                        constructed_path.push(asn.to_u32());
                    }
                }
            }
            constructed_path
        }
        None => Vec::new(),
    }
}

pub fn new_communities(communities: &[MetaCommunity]) -> Vec<(u32, u16)> {
    communities
        .iter()
        .filter_map(|community| match community {
            MetaCommunity::Plain(community) => match community {
                bgpkit_parser::models::Community::Custom(asn, value) => {
                    Some((asn.to_u32(), *value))
                }
                // Well-known communities use reserved ASN 65535 (0xFFFF)
                bgpkit_parser::models::Community::NoExport => Some((0xFFFF, 0xFF01)),
                bgpkit_parser::models::Community::NoAdvertise => Some((0xFFFF, 0xFF02)),
                bgpkit_parser::models::Community::NoExportSubConfed => Some((0xFFFF, 0xFF03)),
            },
            // For extended and large communities, we could extract the first 32 bits
            // but since the return type is (u32, u16), we'll skip them for now
            // as they don't fit the standard community format
            MetaCommunity::Extended(_)
            | MetaCommunity::Ipv6Extended(_)
            | MetaCommunity::Large(_) => None,
        })
        .collect()
}

pub fn map_to_ipv6(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V4(v4) => IpAddr::V6(v4.to_ipv6_mapped()),
        IpAddr::V6(v6) => IpAddr::V6(v6),
    }
}

// Helper functions for extracting community data into simple types
fn extract_extended_communities(communities: &[MetaCommunity]) -> Vec<(u8, u8, Vec<u8>)> {
    communities
        .iter()
        .filter_map(|community| match community {
            MetaCommunity::Extended(ext_comm) => {
                let type_byte = u8::from(ext_comm.community_type());
                match ext_comm {
                    bgpkit_parser::models::ExtendedCommunity::TransitiveTwoOctetAs(ec)
                    | bgpkit_parser::models::ExtendedCommunity::NonTransitiveTwoOctetAs(ec) => {
                        Some((
                            type_byte,
                            ec.subtype,
                            [
                                &ec.global_admin.to_u32().to_be_bytes()[2..],
                                &ec.local_admin,
                            ]
                            .concat(),
                        ))
                    }
                    bgpkit_parser::models::ExtendedCommunity::TransitiveIpv4Addr(ec)
                    | bgpkit_parser::models::ExtendedCommunity::NonTransitiveIpv4Addr(ec) => {
                        Some((
                            type_byte,
                            ec.subtype,
                            [
                                ec.global_admin.octets().as_slice(),
                                ec.local_admin.as_slice(),
                            ]
                            .concat(),
                        ))
                    }
                    bgpkit_parser::models::ExtendedCommunity::TransitiveFourOctetAs(ec)
                    | bgpkit_parser::models::ExtendedCommunity::NonTransitiveFourOctetAs(ec) => {
                        Some((
                            type_byte,
                            ec.subtype,
                            [
                                ec.global_admin.to_u32().to_be_bytes().as_slice(),
                                ec.local_admin.as_slice(),
                            ]
                            .concat(),
                        ))
                    }
                    bgpkit_parser::models::ExtendedCommunity::TransitiveOpaque(ec)
                    | bgpkit_parser::models::ExtendedCommunity::NonTransitiveOpaque(ec) => {
                        Some((type_byte, ec.subtype, ec.value.to_vec()))
                    }
                    bgpkit_parser::models::ExtendedCommunity::FlowSpecTrafficRate(fs) => Some((
                        type_byte,
                        0,
                        [
                            &fs.as_number.to_be_bytes()[..],
                            &fs.rate_bytes_per_sec.to_be_bytes()[..],
                        ]
                        .concat(),
                    )),
                    bgpkit_parser::models::ExtendedCommunity::FlowSpecTrafficAction(fs) => {
                        Some((type_byte, 0, vec![fs.sample as u8, fs.terminal as u8]))
                    }
                    bgpkit_parser::models::ExtendedCommunity::FlowSpecRedirect(ec) => Some((
                        type_byte,
                        ec.subtype,
                        [
                            &ec.global_admin.to_u32().to_be_bytes()[2..],
                            &ec.local_admin,
                        ]
                        .concat(),
                    )),
                    bgpkit_parser::models::ExtendedCommunity::FlowSpecTrafficMarking(fs) => {
                        Some((type_byte, 0, vec![fs.dscp]))
                    }
                    bgpkit_parser::models::ExtendedCommunity::Raw(raw) => {
                        Some((raw[0], raw[1], raw[2..].to_vec()))
                    }
                }
            }
            MetaCommunity::Ipv6Extended(ipv6_ext_comm) => {
                let type_byte = u8::from(ipv6_ext_comm.community_type);
                Some((
                    type_byte,
                    ipv6_ext_comm.subtype,
                    [
                        ipv6_ext_comm.global_admin.octets().as_slice(),
                        &ipv6_ext_comm.local_admin,
                    ]
                    .concat(),
                ))
            }
            _ => None,
        })
        .collect()
}

fn extract_large_communities(communities: &[MetaCommunity]) -> Vec<(u32, u32, u32)> {
    communities
        .iter()
        .filter_map(|community| match community {
            MetaCommunity::Large(large_comm) => Some((
                large_comm.global_admin,
                large_comm.local_data[0],
                large_comm.local_data[1],
            )),
            _ => None,
        })
        .collect()
}
