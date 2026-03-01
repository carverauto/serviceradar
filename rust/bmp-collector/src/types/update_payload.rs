use serde::Serialize;
use crate::types::update_attrs::UpdateAttrs;

#[derive(Debug, Serialize)]
pub(crate) struct UpdatePayload<'a> {
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