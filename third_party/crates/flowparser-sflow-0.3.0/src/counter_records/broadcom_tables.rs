use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

/// Broadcom ASIC hardware table utilization counters (enterprise=4413, format=3).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BroadcomHwTables {
    pub host_entries: u32,
    pub host_entries_max: u32,
    pub ipv4_entries: u32,
    pub ipv4_entries_max: u32,
    pub ipv6_entries: u32,
    pub ipv6_entries_max: u32,
    pub ipv4_ipv6_entries: u32,
    pub ipv4_ipv6_entries_max: u32,
    pub long_ipv6_entries: u32,
    pub long_ipv6_entries_max: u32,
    pub total_routes: u32,
    pub total_routes_max: u32,
    pub ecmp_nexthops: u32,
    pub ecmp_nexthops_max: u32,
    pub mac_entries: u32,
    pub mac_entries_max: u32,
    pub ipv4_neighbors: u32,
    pub ipv6_neighbors: u32,
    pub ipv4_routes: u32,
    pub ipv6_routes: u32,
    pub acl_ingress_entries: u32,
    pub acl_ingress_entries_max: u32,
    pub acl_ingress_counters: u32,
    pub acl_ingress_counters_max: u32,
    pub acl_ingress_meters: u32,
    pub acl_ingress_meters_max: u32,
    pub acl_ingress_slices: u32,
    pub acl_ingress_slices_max: u32,
    pub acl_egress_entries: u32,
    pub acl_egress_entries_max: u32,
    pub acl_egress_counters: u32,
    pub acl_egress_counters_max: u32,
    pub acl_egress_meters: u32,
    pub acl_egress_meters_max: u32,
    pub acl_egress_slices: u32,
    pub acl_egress_slices_max: u32,
}

pub(crate) fn parse_broadcom_hw_tables(input: &[u8]) -> IResult<&[u8], BroadcomHwTables> {
    let (input, host_entries) = be_u32(input)?;
    let (input, host_entries_max) = be_u32(input)?;
    let (input, ipv4_entries) = be_u32(input)?;
    let (input, ipv4_entries_max) = be_u32(input)?;
    let (input, ipv6_entries) = be_u32(input)?;
    let (input, ipv6_entries_max) = be_u32(input)?;
    let (input, ipv4_ipv6_entries) = be_u32(input)?;
    let (input, ipv4_ipv6_entries_max) = be_u32(input)?;
    let (input, long_ipv6_entries) = be_u32(input)?;
    let (input, long_ipv6_entries_max) = be_u32(input)?;
    let (input, total_routes) = be_u32(input)?;
    let (input, total_routes_max) = be_u32(input)?;
    let (input, ecmp_nexthops) = be_u32(input)?;
    let (input, ecmp_nexthops_max) = be_u32(input)?;
    let (input, mac_entries) = be_u32(input)?;
    let (input, mac_entries_max) = be_u32(input)?;
    let (input, ipv4_neighbors) = be_u32(input)?;
    let (input, ipv6_neighbors) = be_u32(input)?;
    let (input, ipv4_routes) = be_u32(input)?;
    let (input, ipv6_routes) = be_u32(input)?;
    let (input, acl_ingress_entries) = be_u32(input)?;
    let (input, acl_ingress_entries_max) = be_u32(input)?;
    let (input, acl_ingress_counters) = be_u32(input)?;
    let (input, acl_ingress_counters_max) = be_u32(input)?;
    let (input, acl_ingress_meters) = be_u32(input)?;
    let (input, acl_ingress_meters_max) = be_u32(input)?;
    let (input, acl_ingress_slices) = be_u32(input)?;
    let (input, acl_ingress_slices_max) = be_u32(input)?;
    let (input, acl_egress_entries) = be_u32(input)?;
    let (input, acl_egress_entries_max) = be_u32(input)?;
    let (input, acl_egress_counters) = be_u32(input)?;
    let (input, acl_egress_counters_max) = be_u32(input)?;
    let (input, acl_egress_meters) = be_u32(input)?;
    let (input, acl_egress_meters_max) = be_u32(input)?;
    let (input, acl_egress_slices) = be_u32(input)?;
    let (input, acl_egress_slices_max) = be_u32(input)?;

    Ok((
        input,
        BroadcomHwTables {
            host_entries,
            host_entries_max,
            ipv4_entries,
            ipv4_entries_max,
            ipv6_entries,
            ipv6_entries_max,
            ipv4_ipv6_entries,
            ipv4_ipv6_entries_max,
            long_ipv6_entries,
            long_ipv6_entries_max,
            total_routes,
            total_routes_max,
            ecmp_nexthops,
            ecmp_nexthops_max,
            mac_entries,
            mac_entries_max,
            ipv4_neighbors,
            ipv6_neighbors,
            ipv4_routes,
            ipv6_routes,
            acl_ingress_entries,
            acl_ingress_entries_max,
            acl_ingress_counters,
            acl_ingress_counters_max,
            acl_ingress_meters,
            acl_ingress_meters_max,
            acl_ingress_slices,
            acl_ingress_slices_max,
            acl_egress_entries,
            acl_egress_entries_max,
            acl_egress_counters,
            acl_egress_counters_max,
            acl_egress_meters,
            acl_egress_meters_max,
            acl_egress_slices,
            acl_egress_slices_max,
        },
    ))
}
