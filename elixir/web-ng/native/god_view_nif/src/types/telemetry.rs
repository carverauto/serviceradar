//! Types mapping metrics and telemetry directly from hardware components.

/// Core representation of raw physical interface network metrics.
///
/// Designed primarily to resolve port bandwidth configurations as fallbacks
/// when telemetry flows are unavailable over the primary control loop.
#[derive(Debug, Clone, Default)]
pub(crate) struct InterfaceTelemetryRecord {
    /// Interface index associated with the record.
    pub(crate) if_index: i64,
    /// The discovered or statically declared speed/capacity in bits-per-second (`bps`).
    pub(crate) speed_bps: u64,
}

/// One topology edge as handed over from Elixir, before telemetry enrichment.
///
/// Tuple layout: `(source_device_id, target_device_id, protocol,
/// (if_index_ab, if_name_ab, if_index_ba, if_name_ba),
/// (typed_flow_pps, typed_flow_bps, typed_capacity_bps))`.
pub(crate) type RawEdgeTelemetry = (
    String,
    String,
    String,
    (i64, String, i64, String),
    (u32, u64, u64),
);

/// One topology edge after interface metrics have been attributed to it.
///
/// Tuple layout: `(source_device_id, target_device_id, flow_pps, flow_bps,
/// capacity_bps, label, (flow_pps_ab, flow_pps_ba, flow_bps_ab, flow_bps_ba))`.
pub(crate) type EnrichedEdgeTelemetry =
    (String, String, u32, u64, u64, String, (u32, u32, u64, u64));
