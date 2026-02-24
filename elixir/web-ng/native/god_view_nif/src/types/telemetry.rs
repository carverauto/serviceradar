//! Types mapping metrics and telemetry directly from hardware components.

/// Core representation of raw physical interface network metrics.
///
/// Designed primarily to resolve port bandwidth configurations as fallbacks
/// when telemetry flows are unavailable over the primary control loop.
#[derive(Debug, Clone, Default)]
pub(crate) struct InterfaceTelemetryRecord {
    /// The discovered or statically declared speed/capacity in bits-per-second (`bps`).
    pub(crate) speed_bps: u64,
}
