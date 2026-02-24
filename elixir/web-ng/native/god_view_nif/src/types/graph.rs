use rustler::{NifMap, Term};
use std::sync::RwLock;

#[derive(Clone, Debug, NifMap)]
pub struct RuntimeGraphRow {
    pub local_device_id: String,
    pub local_device_ip: String,
    pub local_if_name: String,
    pub local_if_index: i64,
    pub neighbor_device_id: String,
    pub neighbor_mgmt_addr: String,
    pub neighbor_system_name: String,
    pub protocol: String,
    pub confidence_tier: String,
    pub metadata_json: String,
}

pub struct RuntimeGraphResource {
    pub links: RwLock<Vec<RuntimeGraphRow>>,
}

pub mod runtime_graph_atoms {
    rustler::atoms! {
        local_device_id,
        local_device_ip,
        local_if_name,
        local_if_index,
        neighbor_device_id,
        neighbor_mgmt_addr,
        neighbor_system_name,
        protocol,
        confidence_tier,
        metadata,
        source,
        inference,
        confidence_score
    }
}
