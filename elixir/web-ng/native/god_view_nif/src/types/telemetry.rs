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
