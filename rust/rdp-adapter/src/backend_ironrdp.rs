#![cfg_attr(serviceradar_rdp_connector_link_probe, allow(dead_code))]

include!("backend_ironrdp/core.rs");
include!("backend_ironrdp/connector_handshake.rs");
include!("backend_ironrdp/active_stage.rs");
include!("backend_ironrdp/network.rs");
include!("backend_ironrdp/live_probe.rs");
include!("backend_ironrdp/planning.rs");

#[cfg(test)]
mod tests;
