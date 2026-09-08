//! Data models for CNPG-backed SRQL queries.
//!
//! Row structs are grouped by domain; every type is re-exported here so
//! consumers keep using `crate::models::X` paths unchanged.

mod common;
mod composite_checks;
mod endpoint_inventory;
mod events;
mod inventory;
mod metrics;
mod observability;
mod system_metrics;

pub use composite_checks::CompositeResultRow;
pub use endpoint_inventory::{
    EndpointInventoryScanRow, EndpointPackageCatalogRow, EndpointPackageRow,
};
pub use events::{AlertRow, BmpRoutingEventRow, EventRow};
pub use inventory::{
    AddonStatusRow, AgentRow, DeviceRow, GatewayRow, ServiceStatusRow, SourceFactDisagreementRow,
    SweepCoverageRow, SweepExecutionRow, SweepGroupRow, SweepProfileRow, SweepResultRow,
};
pub use metrics::{OtelMetricPointRow, OtelMetricRow, TimeseriesMetricRow};
pub use observability::{CapacityForecastRow, LogRow, MtrTraceRow, TraceSpanRow, TraceSummaryRow};
pub use system_metrics::{CpuMetricRow, DiskMetricRow, MemoryMetricRow, ProcessMetricRow};
