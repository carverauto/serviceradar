use arancini_lib::update::Update;
use crate::types::update_attrs::UpdateAttrs;
use crate::types::update_payload::UpdatePayload;

pub(crate) fn to_payload(update: &Update) -> UpdatePayload<'_> {
    UpdatePayload {
        time_received_ns: update.time_received_ns.to_rfc3339(),
        time_bmp_header_ns: update.time_bmp_header_ns.to_rfc3339(),
        router_addr: update.router_addr.to_string(),
        router_port: update.router_port,
        peer_addr: update.peer_addr.to_string(),
        peer_bgp_id: update.peer_bgp_id.to_string(),
        peer_asn: update.peer_asn,
        prefix_addr: update.prefix_addr.to_string(),
        prefix_len: update.prefix_len,
        is_post_policy: update.is_post_policy,
        is_adj_rib_out: update.is_adj_rib_out,
        announced: update.announced,
        synthetic: update.synthetic,
        attrs: UpdateAttrs {
            origin: update.attrs.origin.as_str(),
            as_path: update.attrs.as_path.as_slice(),
            next_hop: update.attrs.next_hop.map(|ip| ip.to_string()),
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