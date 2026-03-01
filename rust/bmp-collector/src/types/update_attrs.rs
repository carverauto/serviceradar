use serde::Serialize;

#[derive(Debug, Serialize)]
pub(crate) struct UpdateAttrs<'a> {
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