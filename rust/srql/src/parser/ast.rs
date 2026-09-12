use crate::{
    error::{Result, ServiceError},
    time::TimeFilterSpec,
};
use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Entity {
    Agents,
    Devices,
    Interfaces,
    DeviceGraph,
    GraphCypher,
    Events,
    SecurityFindings,
    ScanActivity,
    DnsActivity,
    BmpEvents,
    MtrTraces,
    FieldSurveySessions,
    FieldSurveyRasters,
    FieldSurveyArtifacts,
    FieldSurveyRfObservations,
    FieldSurveyPoseSamples,
    FieldSurveyRfPoseMatches,
    FieldSurveySpectrumObservations,
    WifiSites,
    WifiSiteSnapshots,
    WifiAccessPoints,
    WifiControllers,
    WifiRadiusGroups,
    WifiFleetHistory,
    WifiSiteReferences,
    VirtualizationClusters,
    VirtualizationHosts,
    VirtualizationGuests,
    VirtualizationDatastores,
    VirtualizationHostDisks,
    VirtualizationNetworkInterfaces,
    VirtualizationStorageSystems,
    Logs,
    Services,
    ServiceAvailability,
    MonitoredServices,
    SloEvaluations,
    Dashboards,
    Gateways,
    OtelMetrics,
    OtelMetricPoints,
    RperfMetrics,
    CpuMetrics,
    MemoryMetrics,
    DiskMetrics,
    ProcessMetrics,
    CapacityForecasts,
    CompositeResults,
    TimeseriesMetrics,
    TimeseriesMetricInterfaceHourly,
    TimeseriesMetricDiskHourly,
    SnmpMetrics,
    TraceSummaries,
    Traces,
    Flows,
    AttributedFlows,
    Alerts,
    AddonFleet,
    AddonStatuses,
    EndpointPackageCatalog,
    EndpointPackages,
    EndpointInventoryScans,
    PublicEndpoints,
    SourceFactDisagreements,
    MergeAudit,
    DeviceRevivalAudit,
    DeviceIdentifiers,
    IdentityReconciliationRuns,
    IdentityEvidenceEdges,
    VulnerabilityAdvisories,
    AdvisoryCoordinates,
    EndpointVulnerabilityAssessments,
    ThreatIntelMatches,
    SweepGroups,
    SweepProfiles,
    SweepExecutions,
    SweepResults,
    SweepCoverage,
    DeviceSweepOverlap,
}

#[derive(Debug, Clone, Serialize)]
pub struct QueryAst {
    pub entity: Entity,
    pub filters: Vec<Filter>,
    pub order: Vec<OrderClause>,
    pub limit: Option<i64>,
    pub time_filter: Option<TimeFilterSpec>,
    pub stats: Option<StatsSpec>,
    pub downsample: Option<DownsampleSpec>,
    /// Rollup stats type for querying pre-computed CAGGs (e.g., "severity", "summary", "availability")
    pub rollup_stats: Option<String>,
    pub other: bool,
}

/// Parsed stats specification with structured aggregation info
#[derive(Debug, Clone, Serialize)]
pub struct StatsSpec {
    /// The raw stats expression (for backwards compatibility)
    pub raw: String,
    /// Parsed aggregations
    pub aggregations: Vec<StatsAggregation>,
}

impl StatsSpec {
    /// Returns the raw stats expression string for backwards compatibility
    /// with existing query modules that parse stats themselves.
    pub fn as_raw(&self) -> &str {
        &self.raw
    }

    /// Create a StatsSpec from a raw expression string.
    /// This is useful for creating test fixtures.
    pub fn from_raw(raw: &str) -> Self {
        super::stats::parse_stats_expr(raw)
    }
}

/// A single stats aggregation like count(), sum(field), etc.
#[derive(Debug, Clone, Serialize)]
pub struct StatsAggregation {
    /// The aggregation function type
    #[serde(rename = "type")]
    pub agg_type: StatsAggType,
    /// The field to aggregate (None for count())
    pub field: Option<String>,
    /// The alias for the result
    pub alias: String,
}

/// Stats aggregation function types
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum StatsAggType {
    Count,
    Sum,
    Avg,
    Min,
    Max,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DownsampleAgg {
    Avg,
    Min,
    Max,
    Sum,
    Count,
    /// Rate of change per second - for counter metrics like SNMP byte counters.
    /// Calculates (current_value - previous_value) / time_delta_seconds,
    /// then averages within each bucket. Skips rows where counter appears to wrap/reset.
    Rate,
    /// Rate of change per second, SUMMED across the series collapsed into each
    /// display bucket rather than averaged.
    ///
    /// `Rate` answers "what is the typical rate of one of these"; `RateSum`
    /// answers "what is the combined rate of all of them". They differ whenever
    /// a display series aggregates more than one underlying counter -- several
    /// controllers each keeping their own counters for the same RADIUS server,
    /// for example, where the fleet total is the sum and the average understates
    /// it by the number of controllers.
    RateSum,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DownsampleSpec {
    pub bucket_seconds: i64,
    pub agg: DownsampleAgg,
    pub series: Option<String>,
    pub value_field: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Filter {
    pub field: String,
    pub op: FilterOp,
    pub value: FilterValue,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FilterOp {
    Eq,
    NotEq,
    Like,
    NotLike,
    In,
    NotIn,
    Gt,
    Gte,
    Lt,
    Lte,
}

#[derive(Debug, Clone, Serialize)]
#[serde(untagged)]
pub enum FilterValue {
    Scalar(String),
    List(Vec<String>),
}

impl FilterValue {
    pub fn as_scalar(&self) -> Result<&str> {
        match self {
            FilterValue::Scalar(v) => Ok(v.as_str()),
            FilterValue::List(_) => {
                Err(ServiceError::InvalidRequest("expected scalar value".into()))
            }
        }
    }

    pub fn as_list(&self) -> Result<&[String]> {
        match self {
            FilterValue::List(items) => Ok(items.as_slice()),
            FilterValue::Scalar(_) => {
                Err(ServiceError::InvalidRequest("expected list value".into()))
            }
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct OrderClause {
    pub field: String,
    pub direction: OrderDirection,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum OrderDirection {
    Asc,
    Desc,
}
