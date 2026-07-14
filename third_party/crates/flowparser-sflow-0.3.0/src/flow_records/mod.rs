pub mod app_initiator;
pub mod app_operation;
pub mod app_parent_context;
pub mod app_target;
pub mod extended_80211_payload;
pub mod extended_80211_rx;
pub mod extended_80211_tx;
pub mod extended_acl;
pub mod extended_decapsulate;
pub mod extended_egress_queue;
pub mod extended_entities;
pub mod extended_function;
pub mod extended_gateway;
pub mod extended_hw_trap;
pub mod extended_ib;
pub mod extended_linux_drop_reason;
pub mod extended_mpls;
pub mod extended_mpls_ftn;
pub mod extended_mpls_ldp_fec;
pub mod extended_mpls_tunnel;
pub mod extended_mpls_vc;
pub mod extended_nat;
pub mod extended_nat_port;
pub mod extended_proxy_request;
pub mod extended_proxy_socket_ipv4;
pub mod extended_proxy_socket_ipv6;
pub mod extended_queue;
pub mod extended_router;
pub mod extended_socket_ipv4;
pub mod extended_socket_ipv6;
pub mod extended_switch;
pub mod extended_tcp_info;
pub mod extended_timestamp;
pub mod extended_transit;
pub mod extended_url;
pub mod extended_user;
pub mod extended_vlan_tunnel;
pub mod extended_vni;
pub mod http_request;
pub mod jvm_runtime;
pub mod memcache_operation;
pub mod raw_packet_header;
pub mod sampled_ethernet;
pub mod sampled_ipv4;
pub mod sampled_ipv6;

use nom::IResult;
use nom::bytes::complete::take;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

pub use app_initiator::AppInitiator;
pub use app_operation::AppOperation;
pub use app_parent_context::AppParentContext;
pub use app_target::AppTarget;
pub use extended_80211_payload::Extended80211Payload;
pub use extended_80211_rx::Extended80211Rx;
pub use extended_80211_tx::Extended80211Tx;
pub use extended_acl::ExtendedAcl;
pub use extended_decapsulate::{ExtendedDecapsulateEgress, ExtendedDecapsulateIngress};
pub use extended_egress_queue::ExtendedEgressQueue;
pub use extended_entities::ExtendedEntities;
pub use extended_function::ExtendedFunction;
pub use extended_gateway::ExtendedGateway;
pub use extended_hw_trap::ExtendedHwTrap;
pub use extended_ib::{ExtendedIbBrh, ExtendedIbGrh, ExtendedIbLrh};
pub use extended_linux_drop_reason::ExtendedLinuxDropReason;
pub use extended_mpls::ExtendedMpls;
pub use extended_mpls_ftn::ExtendedMplsFtn;
pub use extended_mpls_ldp_fec::ExtendedMplsLdpFec;
pub use extended_mpls_tunnel::ExtendedMplsTunnel;
pub use extended_mpls_vc::ExtendedMplsVc;
pub use extended_nat::ExtendedNat;
pub use extended_nat_port::ExtendedNatPort;
pub use extended_proxy_request::ExtendedProxyRequest;
pub use extended_proxy_socket_ipv4::ExtendedProxySocketIpv4;
pub use extended_proxy_socket_ipv6::ExtendedProxySocketIpv6;
pub use extended_queue::ExtendedQueue;
pub use extended_router::ExtendedRouter;
pub use extended_socket_ipv4::ExtendedSocketIpv4;
pub use extended_socket_ipv6::ExtendedSocketIpv6;
pub use extended_switch::ExtendedSwitch;
pub use extended_tcp_info::ExtendedTcpInfo;
pub use extended_timestamp::ExtendedTimestamp;
pub use extended_transit::ExtendedTransit;
pub use extended_url::ExtendedUrl;
pub use extended_user::ExtendedUser;
pub use extended_vlan_tunnel::ExtendedVlanTunnel;
pub use extended_vni::{ExtendedVniEgress, ExtendedVniIngress};
pub use http_request::HttpRequest;
pub use jvm_runtime::JvmRuntime;
pub use memcache_operation::MemcacheOperation;
pub use raw_packet_header::RawPacketHeader;
pub use sampled_ethernet::SampledEthernet;
pub use sampled_ipv4::SampledIpv4;
pub use sampled_ipv6::SampledIpv6;

/// A flow record within a flow sample.
///
/// Flow records describe properties of a sampled packet, ranging from
/// raw header bytes to decoded L2/L3/L4 fields and extended routing data.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum FlowRecord {
    /// Raw packet header bytes (enterprise=0, format=1).
    RawPacketHeader(RawPacketHeader),
    /// Sampled Ethernet frame header (enterprise=0, format=2).
    SampledEthernet(SampledEthernet),
    /// Sampled IPv4 packet header (enterprise=0, format=3).
    SampledIpv4(SampledIpv4),
    /// Sampled IPv6 packet header (enterprise=0, format=4).
    SampledIpv6(SampledIpv6),
    /// Extended switch data — VLAN and priority (enterprise=0, format=1001).
    ExtendedSwitch(ExtendedSwitch),
    /// Extended router data — next hop and masks (enterprise=0, format=1002).
    ExtendedRouter(ExtendedRouter),
    /// Extended gateway data — BGP AS path and communities (enterprise=0, format=1003).
    ExtendedGateway(ExtendedGateway),
    /// Extended user data — source and destination user identifiers (enterprise=0, format=1004).
    ExtendedUser(ExtendedUser),
    /// Extended URL data — URL and host strings (enterprise=0, format=1005).
    ExtendedUrl(ExtendedUrl),
    /// Extended MPLS data — next hop and label stacks (enterprise=0, format=1006).
    ExtendedMpls(ExtendedMpls),
    /// Extended NAT data — translated source and destination addresses (enterprise=0, format=1007).
    ExtendedNat(ExtendedNat),
    /// Extended NAT port translation data (enterprise=0, format=1020).
    ExtendedNatPort(ExtendedNatPort),
    /// Extended MPLS tunnel data (enterprise=0, format=1008).
    ExtendedMplsTunnel(ExtendedMplsTunnel),
    /// Extended MPLS virtual circuit data (enterprise=0, format=1009).
    ExtendedMplsVc(ExtendedMplsVc),
    /// Extended MPLS FEC to NHLFE mapping (enterprise=0, format=1010).
    ExtendedMplsFtn(ExtendedMplsFtn),
    /// Extended MPLS LDP FEC data (enterprise=0, format=1011).
    ExtendedMplsLdpFec(ExtendedMplsLdpFec),
    /// Extended VLAN tunnel data — 802.1Q-in-Q stack (enterprise=0, format=1012).
    ExtendedVlanTunnel(ExtendedVlanTunnel),
    /// Extended 802.11 payload data (enterprise=0, format=1013).
    Extended80211Payload(Extended80211Payload),
    /// Extended 802.11 receive data (enterprise=0, format=1014).
    Extended80211Rx(Extended80211Rx),
    /// Extended 802.11 transmit data (enterprise=0, format=1015).
    Extended80211Tx(Extended80211Tx),
    /// Extended L2 tunnel egress — reuses sampled Ethernet (enterprise=0, format=1021).
    ExtendedL2TunnelEgress(SampledEthernet),
    /// Extended L2 tunnel ingress — reuses sampled Ethernet (enterprise=0, format=1022).
    ExtendedL2TunnelIngress(SampledEthernet),
    /// Extended IPv4 tunnel egress — reuses sampled IPv4 (enterprise=0, format=1023).
    ExtendedIpv4TunnelEgress(SampledIpv4),
    /// Extended IPv4 tunnel ingress — reuses sampled IPv4 (enterprise=0, format=1024).
    ExtendedIpv4TunnelIngress(SampledIpv4),
    /// Extended IPv6 tunnel egress — reuses sampled IPv6 (enterprise=0, format=1025).
    ExtendedIpv6TunnelEgress(SampledIpv6),
    /// Extended IPv6 tunnel ingress — reuses sampled IPv6 (enterprise=0, format=1026).
    ExtendedIpv6TunnelIngress(SampledIpv6),
    /// Extended decapsulate egress data (enterprise=0, format=1027).
    ExtendedDecapsulateEgress(ExtendedDecapsulateEgress),
    /// Extended decapsulate ingress data (enterprise=0, format=1028).
    ExtendedDecapsulateIngress(ExtendedDecapsulateIngress),
    /// Extended VNI egress data (enterprise=0, format=1029).
    ExtendedVniEgress(ExtendedVniEgress),
    /// Extended VNI ingress data (enterprise=0, format=1030).
    ExtendedVniIngress(ExtendedVniIngress),
    /// InfiniBand Local Routing Header (enterprise=0, format=1031).
    ExtendedIbLrh(ExtendedIbLrh),
    /// InfiniBand Global Routing Header (enterprise=0, format=1032).
    ExtendedIbGrh(ExtendedIbGrh),
    /// InfiniBand Base Transport Header (enterprise=0, format=1033).
    ExtendedIbBrh(ExtendedIbBrh),
    /// Extended egress queue identifier (enterprise=0, format=1036).
    ExtendedEgressQueue(ExtendedEgressQueue),
    /// Extended ACL data (enterprise=0, format=1037).
    ExtendedAcl(ExtendedAcl),
    /// Extended function/symbol data (enterprise=0, format=1038).
    ExtendedFunction(ExtendedFunction),
    /// Extended transit delay data (enterprise=0, format=1039).
    ExtendedTransit(ExtendedTransit),
    /// Extended queue depth data (enterprise=0, format=1040).
    ExtendedQueue(ExtendedQueue),
    /// Extended hardware trap data (enterprise=0, format=1041).
    ExtendedHwTrap(ExtendedHwTrap),
    /// Extended Linux kernel drop reason (enterprise=0, format=1042).
    ExtendedLinuxDropReason(ExtendedLinuxDropReason),
    /// Extended nanosecond-precision timestamp (enterprise=0, format=1043).
    ExtendedTimestamp(ExtendedTimestamp),
    /// Extended socket IPv4 data (enterprise=0, format=2100).
    ExtendedSocketIpv4(ExtendedSocketIpv4),
    /// Extended socket IPv6 data (enterprise=0, format=2101).
    ExtendedSocketIpv6(ExtendedSocketIpv6),
    /// Extended proxy socket IPv4 data (enterprise=0, format=2102).
    ExtendedProxySocketIpv4(ExtendedProxySocketIpv4),
    /// Extended proxy socket IPv6 data (enterprise=0, format=2103).
    ExtendedProxySocketIpv6(ExtendedProxySocketIpv6),
    /// JVM runtime information (enterprise=0, format=2105).
    JvmRuntime(JvmRuntime),
    /// Memcache operation data (enterprise=0, format=2200).
    MemcacheOperation(MemcacheOperation),
    /// Application operation data (enterprise=0, format=2202).
    AppOperation(AppOperation),
    /// Application parent context (enterprise=0, format=2203).
    AppParentContext(AppParentContext),
    /// Application initiator (enterprise=0, format=2204).
    AppInitiator(AppInitiator),
    /// Application target (enterprise=0, format=2205).
    AppTarget(AppTarget),
    /// HTTP request data (enterprise=0, format=2206).
    HttpRequest(HttpRequest),
    /// Extended proxy request data (enterprise=0, format=2207).
    ExtendedProxyRequest(ExtendedProxyRequest),
    /// Extended TCP info (enterprise=0, format=2209).
    ExtendedTcpInfo(ExtendedTcpInfo),
    /// Extended entities data (enterprise=0, format=2210).
    ExtendedEntities(ExtendedEntities),
    /// Unrecognized flow record type, preserved as raw bytes.
    Unknown {
        /// Enterprise code from the record header.
        enterprise: u32,
        /// Format code from the record header.
        format: u32,
        /// Raw record data.
        data: Vec<u8>,
    },
}

/// Parse an XDR-encoded sFlow string (length-prefixed, padded to 4-byte boundary).
///
/// Note: Invalid UTF-8 bytes are replaced with U+FFFD (replacement character).
pub(crate) fn parse_sflow_string(input: &[u8]) -> IResult<&[u8], String> {
    let (input, length) = be_u32(input)?;
    let (input, bytes) = take(length as usize)(input)?;
    // Pad to 4-byte boundary
    let padding = (4 - (length as usize % 4)) % 4;
    let (input, _) = take(padding)(input)?;
    let s = String::from_utf8_lossy(bytes).into_owned();
    Ok((input, s))
}

pub(crate) fn parse_flow_records(
    mut input: &[u8],
    num_records: u32,
) -> IResult<&[u8], Vec<FlowRecord>> {
    // Cap capacity to prevent DoS: each record needs at least 8 bytes (format + length)
    let cap = (num_records as usize).min(input.len() / 8);
    let mut records = Vec::with_capacity(cap);

    for _ in 0..num_records {
        let (rest, data_format) = be_u32(input)?;
        let enterprise = data_format >> 12;
        let format = data_format & 0xFFF;

        let (rest, record_length) = be_u32(rest)?;
        let record_length = record_length as usize;

        if rest.len() < record_length {
            return Err(nom::Err::Error(nom::error::Error::new(
                rest,
                nom::error::ErrorKind::Eof,
            )));
        }

        let record_data = &rest[..record_length];
        let after_record = &rest[record_length..];

        let record = if enterprise == 0 {
            match format {
                1 => {
                    let (_, r) = raw_packet_header::parse_raw_packet_header(record_data)?;
                    FlowRecord::RawPacketHeader(r)
                }
                2 => {
                    let (_, r) = sampled_ethernet::parse_sampled_ethernet(record_data)?;
                    FlowRecord::SampledEthernet(r)
                }
                3 => {
                    let (_, r) = sampled_ipv4::parse_sampled_ipv4(record_data)?;
                    FlowRecord::SampledIpv4(r)
                }
                4 => {
                    let (_, r) = sampled_ipv6::parse_sampled_ipv6(record_data)?;
                    FlowRecord::SampledIpv6(r)
                }
                1001 => {
                    let (_, r) = extended_switch::parse_extended_switch(record_data)?;
                    FlowRecord::ExtendedSwitch(r)
                }
                1002 => {
                    let (_, r) = extended_router::parse_extended_router(record_data)?;
                    FlowRecord::ExtendedRouter(r)
                }
                1003 => {
                    let (_, r) = extended_gateway::parse_extended_gateway(record_data)?;
                    FlowRecord::ExtendedGateway(r)
                }
                1004 => {
                    let (_, r) = extended_user::parse_extended_user(record_data)?;
                    FlowRecord::ExtendedUser(r)
                }
                1005 => {
                    let (_, r) = extended_url::parse_extended_url(record_data)?;
                    FlowRecord::ExtendedUrl(r)
                }
                1006 => {
                    let (_, r) = extended_mpls::parse_extended_mpls(record_data)?;
                    FlowRecord::ExtendedMpls(r)
                }
                1007 => {
                    let (_, r) = extended_nat::parse_extended_nat(record_data)?;
                    FlowRecord::ExtendedNat(r)
                }
                1008 => {
                    let (_, r) = extended_mpls_tunnel::parse_extended_mpls_tunnel(record_data)?;
                    FlowRecord::ExtendedMplsTunnel(r)
                }
                1009 => {
                    let (_, r) = extended_mpls_vc::parse_extended_mpls_vc(record_data)?;
                    FlowRecord::ExtendedMplsVc(r)
                }
                1010 => {
                    let (_, r) = extended_mpls_ftn::parse_extended_mpls_ftn(record_data)?;
                    FlowRecord::ExtendedMplsFtn(r)
                }
                1011 => {
                    let (_, r) =
                        extended_mpls_ldp_fec::parse_extended_mpls_ldp_fec(record_data)?;
                    FlowRecord::ExtendedMplsLdpFec(r)
                }
                1020 => {
                    let (_, r) = extended_nat_port::parse_extended_nat_port(record_data)?;
                    FlowRecord::ExtendedNatPort(r)
                }
                1012 => {
                    let (_, r) = extended_vlan_tunnel::parse_extended_vlan_tunnel(record_data)?;
                    FlowRecord::ExtendedVlanTunnel(r)
                }
                1013 => {
                    let (_, r) =
                        extended_80211_payload::parse_extended_80211_payload(record_data)?;
                    FlowRecord::Extended80211Payload(r)
                }
                1014 => {
                    let (_, r) = extended_80211_rx::parse_extended_80211_rx(record_data)?;
                    FlowRecord::Extended80211Rx(r)
                }
                1015 => {
                    let (_, r) = extended_80211_tx::parse_extended_80211_tx(record_data)?;
                    FlowRecord::Extended80211Tx(r)
                }
                1021 => {
                    let (_, r) = sampled_ethernet::parse_sampled_ethernet(record_data)?;
                    FlowRecord::ExtendedL2TunnelEgress(r)
                }
                1022 => {
                    let (_, r) = sampled_ethernet::parse_sampled_ethernet(record_data)?;
                    FlowRecord::ExtendedL2TunnelIngress(r)
                }
                1023 => {
                    let (_, r) = sampled_ipv4::parse_sampled_ipv4(record_data)?;
                    FlowRecord::ExtendedIpv4TunnelEgress(r)
                }
                1024 => {
                    let (_, r) = sampled_ipv4::parse_sampled_ipv4(record_data)?;
                    FlowRecord::ExtendedIpv4TunnelIngress(r)
                }
                1025 => {
                    let (_, r) = sampled_ipv6::parse_sampled_ipv6(record_data)?;
                    FlowRecord::ExtendedIpv6TunnelEgress(r)
                }
                1026 => {
                    let (_, r) = sampled_ipv6::parse_sampled_ipv6(record_data)?;
                    FlowRecord::ExtendedIpv6TunnelIngress(r)
                }
                1027 => {
                    let (_, r) =
                        extended_decapsulate::parse_extended_decapsulate_egress(record_data)?;
                    FlowRecord::ExtendedDecapsulateEgress(r)
                }
                1028 => {
                    let (_, r) =
                        extended_decapsulate::parse_extended_decapsulate_ingress(record_data)?;
                    FlowRecord::ExtendedDecapsulateIngress(r)
                }
                1029 => {
                    let (_, r) = extended_vni::parse_extended_vni_egress(record_data)?;
                    FlowRecord::ExtendedVniEgress(r)
                }
                1030 => {
                    let (_, r) = extended_vni::parse_extended_vni_ingress(record_data)?;
                    FlowRecord::ExtendedVniIngress(r)
                }
                1031 => {
                    let (_, r) = extended_ib::parse_extended_ib_lrh(record_data)?;
                    FlowRecord::ExtendedIbLrh(r)
                }
                1032 => {
                    let (_, r) = extended_ib::parse_extended_ib_grh(record_data)?;
                    FlowRecord::ExtendedIbGrh(r)
                }
                1033 => {
                    let (_, r) = extended_ib::parse_extended_ib_brh(record_data)?;
                    FlowRecord::ExtendedIbBrh(r)
                }
                1036 => {
                    let (_, r) =
                        extended_egress_queue::parse_extended_egress_queue(record_data)?;
                    FlowRecord::ExtendedEgressQueue(r)
                }
                1037 => {
                    let (_, r) = extended_acl::parse_extended_acl(record_data)?;
                    FlowRecord::ExtendedAcl(r)
                }
                1038 => {
                    let (_, r) = extended_function::parse_extended_function(record_data)?;
                    FlowRecord::ExtendedFunction(r)
                }
                1039 => {
                    let (_, r) = extended_transit::parse_extended_transit(record_data)?;
                    FlowRecord::ExtendedTransit(r)
                }
                1040 => {
                    let (_, r) = extended_queue::parse_extended_queue(record_data)?;
                    FlowRecord::ExtendedQueue(r)
                }
                1041 => {
                    let (_, r) = extended_hw_trap::parse_extended_hw_trap(record_data)?;
                    FlowRecord::ExtendedHwTrap(r)
                }
                1042 => {
                    let (_, r) = extended_linux_drop_reason::parse_extended_linux_drop_reason(
                        record_data,
                    )?;
                    FlowRecord::ExtendedLinuxDropReason(r)
                }
                1043 => {
                    let (_, r) = extended_timestamp::parse_extended_timestamp(record_data)?;
                    FlowRecord::ExtendedTimestamp(r)
                }
                2100 => {
                    let (_, r) = extended_socket_ipv4::parse_extended_socket_ipv4(record_data)?;
                    FlowRecord::ExtendedSocketIpv4(r)
                }
                2101 => {
                    let (_, r) = extended_socket_ipv6::parse_extended_socket_ipv6(record_data)?;
                    FlowRecord::ExtendedSocketIpv6(r)
                }
                2102 => {
                    let (_, r) = extended_proxy_socket_ipv4::parse_extended_proxy_socket_ipv4(
                        record_data,
                    )?;
                    FlowRecord::ExtendedProxySocketIpv4(r)
                }
                2103 => {
                    let (_, r) = extended_proxy_socket_ipv6::parse_extended_proxy_socket_ipv6(
                        record_data,
                    )?;
                    FlowRecord::ExtendedProxySocketIpv6(r)
                }
                2105 => {
                    let (_, r) = jvm_runtime::parse_jvm_runtime(record_data)?;
                    FlowRecord::JvmRuntime(r)
                }
                2200 => {
                    let (_, r) = memcache_operation::parse_memcache_operation(record_data)?;
                    FlowRecord::MemcacheOperation(r)
                }
                2202 => {
                    let (_, r) = app_operation::parse_app_operation(record_data)?;
                    FlowRecord::AppOperation(r)
                }
                2203 => {
                    let (_, r) = app_parent_context::parse_app_parent_context(record_data)?;
                    FlowRecord::AppParentContext(r)
                }
                2204 => {
                    let (_, r) = app_initiator::parse_app_initiator(record_data)?;
                    FlowRecord::AppInitiator(r)
                }
                2205 => {
                    let (_, r) = app_target::parse_app_target(record_data)?;
                    FlowRecord::AppTarget(r)
                }
                2206 => {
                    let (_, r) = http_request::parse_http_request(record_data)?;
                    FlowRecord::HttpRequest(r)
                }
                2207 => {
                    let (_, r) =
                        extended_proxy_request::parse_extended_proxy_request(record_data)?;
                    FlowRecord::ExtendedProxyRequest(r)
                }
                2209 => {
                    let (_, r) = extended_tcp_info::parse_extended_tcp_info(record_data)?;
                    FlowRecord::ExtendedTcpInfo(r)
                }
                2210 => {
                    let (_, r) = extended_entities::parse_extended_entities(record_data)?;
                    FlowRecord::ExtendedEntities(r)
                }
                _ => FlowRecord::Unknown {
                    enterprise,
                    format,
                    data: record_data.to_vec(),
                },
            }
        } else {
            FlowRecord::Unknown {
                enterprise,
                format,
                data: record_data.to_vec(),
            }
        };

        records.push(record);
        input = after_record;
    }

    Ok((input, records))
}
