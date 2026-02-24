//! Defines the core runtime topology graph representation.
//!
//! This module contains data structures and Elixir atom definitions used
//! for bridging high-performance topology ingestion from Elixir strings
//! and maps into canonical native Rust structures.

use rustler::NifMap;
use std::sync::RwLock;

/// Represents a single discovered connection between a local interface and a remote neighbor.
///
/// This structure maps directly to an Elixir map containing link layer metadata.
/// It encompasses both the origin routing information (e.g., local management IPs
/// and interface metadata) alongside the discovered neighbor topology data.
#[derive(Clone, Debug, NifMap)]
pub(crate) struct RuntimeGraphRow {
    /// The canonical identifier of the originating device.
    pub(crate) local_device_id: String,
    /// The IP address allocated to the local device.
    pub(crate) local_device_ip: String,
    /// The human-readable name of the local interface (e.g., "eth0").
    pub(crate) local_if_name: String,
    /// The logical interface index of the local device instance.
    pub(crate) local_if_index: i64,
    /// The identified or assumed MAC/ID of the receiving neighbor.
    pub(crate) neighbor_device_id: String,
    /// The management IP address discovered for the neighbor.
    pub(crate) neighbor_mgmt_addr: String,
    /// The OS-reported system name of the neighbor.
    pub(crate) neighbor_system_name: String,
    /// The protocol used to establish this link (e.g., LLDP, CDP, OSPF).
    pub(crate) protocol: String,
    /// A categorical string representing the confidence mapping algorithm (e.g., "high", "inferred").
    pub(crate) confidence_tier: String,
    /// A raw JSON string containing nested inference scores and algorithm meta-parameters.
    pub(crate) metadata_json: String,
}

/// A stateful container holding the real-time cache of network topology edges.
///
/// This resource is held open by the Erlang VM via `ResourceArc` to allow
/// multiple Dirty NIF executions against a shared, mutable topology state.
pub(crate) struct RuntimeGraphResource {
    /// The thread-safe vector of current `RuntimeGraphRow` link items.
    pub(crate) links: RwLock<Vec<RuntimeGraphRow>>,
}

/// A macro-derived module housing canonical Rustler Atom instances.
///
/// By generating them up front, the NIF layer avoids the overhead of converting
/// `&str` to erlang Atoms individually during heavy runtime map decodings.
pub(crate) mod runtime_graph_atoms {
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
