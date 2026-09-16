mod events;
mod fieldsurvey;
mod inventory;
mod metrics;
mod network;
mod observability;
mod sbom;
mod services;
mod wifi;

use crate::parser::Entity;
use serde::Serialize;

use super::QueryPlan;

#[derive(Debug, Clone, Serialize)]
pub struct VizMeta {
    pub columns: Vec<ColumnMeta>,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub suggestions: Vec<VizSuggestion>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ColumnMeta {
    pub name: String,
    #[serde(rename = "type")]
    pub col_type: ColumnType,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub semantic: Option<ColumnSemantic>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unit: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ColumnType {
    Text,
    TextArray,
    Bool,
    Int,
    IntArray,
    Float,
    Timestamptz,
    Jsonb,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ColumnSemantic {
    Id,
    Time,
    Value,
    Label,
    Series,
}

#[derive(Debug, Clone, Serialize)]
pub struct VizSuggestion {
    pub kind: VizKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub y: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub series: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum VizKind {
    Timeseries,
    Table,
}

pub fn meta_for_plan(plan: &QueryPlan) -> Option<VizMeta> {
    if plan.downsample.is_some()
        && matches!(
            plan.entity,
            Entity::TimeseriesMetrics
                | Entity::TimeseriesMetricInterfaceHourly
                | Entity::SnmpMetrics
                | Entity::RperfMetrics
                | Entity::CpuMetrics
                | Entity::MemoryMetrics
                | Entity::DiskMetrics
                | Entity::ProcessMetrics
                | Entity::Flows
                | Entity::AttributedFlows
        )
    {
        return Some(VizMeta {
            columns: vec![
                col(
                    "timestamp",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col("series", ColumnType::Text, Some(ColumnSemantic::Series)),
                col("value", ColumnType::Float, Some(ColumnSemantic::Value)),
            ],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Timeseries,
                x: Some("timestamp".to_string()),
                y: Some("value".to_string()),
                series: Some("series".to_string()),
            }],
        });
    }

    Some(match plan.entity {
        Entity::Agents => inventory::agents(),
        Entity::AddonFleet => inventory::addon_fleet(),
        Entity::AddonStatuses => inventory::addon_statuses(),
        Entity::EndpointInventoryScans => sbom::endpoint_inventory_scans(),
        Entity::EndpointPackages => sbom::endpoint_packages(),
        Entity::EndpointPackageCatalog => sbom::endpoint_package_catalog(),
        Entity::VulnerabilityAdvisories => sbom::vulnerability_advisories(),
        Entity::AdvisoryCoordinates => sbom::advisory_coordinates(),
        Entity::EndpointVulnerabilityAssessments => sbom::endpoint_vulnerability_assessments(),
        Entity::Devices => inventory::devices(),
        Entity::CompositeResults => inventory::composite_results(),
        Entity::WifiSites => wifi::sites(),
        Entity::WifiSiteSnapshots => wifi::site_snapshots(),
        Entity::WifiAccessPoints => wifi::access_points(),
        Entity::WifiControllers => wifi::controllers(),
        Entity::WifiRadiusGroups => wifi::radius_groups(),
        Entity::WifiFleetHistory => wifi::fleet_history(),
        Entity::WifiSiteReferences => wifi::site_references(),
        Entity::VirtualizationClusters
        | Entity::VirtualizationHosts
        | Entity::VirtualizationGuests
        | Entity::VirtualizationDatastores
        | Entity::VirtualizationHostDisks
        | Entity::VirtualizationNetworkInterfaces
        | Entity::VirtualizationStorageSystems => inventory::virtualization(),
        Entity::Gateways => inventory::gateways(),
        Entity::Services => services::services(),
        Entity::ServiceAvailability => services::service_availability(),
        Entity::MonitoredServices => services::monitored_services(),
        Entity::SloEvaluations => services::slo_evaluations(),
        Entity::Dashboards => services::dashboards(),
        Entity::Interfaces => network::interfaces(),
        Entity::Events => events::events(),
        Entity::SecurityFindings => events::security_findings(),
        Entity::ScanActivity => events::scan_activity(),
        Entity::DnsActivity => events::dns_activity(),
        Entity::BmpEvents => network::bmp_events(),
        Entity::MtrTraces => observability::mtr_traces(),
        Entity::FieldSurveySessions => fieldsurvey::sessions(),
        Entity::FieldSurveyRasters => fieldsurvey::rasters(),
        Entity::FieldSurveyArtifacts => fieldsurvey::artifacts(),
        Entity::FieldSurveyRfObservations => fieldsurvey::rf_observations(),
        Entity::FieldSurveyPoseSamples => fieldsurvey::pose_samples(),
        Entity::FieldSurveyRfPoseMatches => fieldsurvey::rf_pose_matches(),
        Entity::FieldSurveySpectrumObservations => fieldsurvey::spectrum_observations(),
        Entity::Logs => observability::logs(),
        Entity::Traces => observability::traces(),
        Entity::TraceSummaries => observability::trace_summaries(),
        Entity::OtelMetrics => observability::otel_metrics(),
        Entity::OtelMetricPoints => observability::otel_metric_points(),
        Entity::CapacityForecasts => observability::capacity_forecasts(),
        Entity::TimeseriesMetrics
        | Entity::TimeseriesMetricInterfaceHourly
        | Entity::SnmpMetrics
        | Entity::RperfMetrics => metrics::timeseries_metrics(),
        Entity::TimeseriesMetricDiskHourly => metrics::timeseries_metric_disk_hourly(),
        Entity::CpuMetrics => metrics::cpu_metrics(),
        Entity::MemoryMetrics => metrics::memory_metrics(),
        Entity::DiskMetrics => metrics::disk_metrics(),
        Entity::ProcessMetrics => metrics::process_metrics(),
        Entity::Alerts => services::alerts(),
        Entity::DeviceGraph => inventory::device_graph(),
        Entity::GraphCypher => inventory::graph_cypher(),
        Entity::Flows | Entity::AttributedFlows => network::flows(),
        Entity::PublicEndpoints => network::public_endpoints(),
        Entity::ThreatIntelMatches => network::threat_intel_matches(),
        Entity::SourceFactDisagreements => inventory::source_fact_disagreements(),
        Entity::SweepGroups => inventory::sweep_groups(),
        Entity::SweepProfiles => inventory::sweep_profiles(),
        Entity::SweepExecutions => inventory::sweep_executions(),
        Entity::SweepResults => inventory::sweep_results(),
        Entity::SweepCoverage => inventory::sweep_coverage(),
        Entity::DeviceSweepOverlap => inventory::device_sweep_overlap(),
        Entity::MergeAudit => inventory::merge_audit(),
        Entity::DeviceRevivalAudit => inventory::device_revival_audit(),
        Entity::DeviceIdentifiers => inventory::device_identifiers(),
        Entity::IdentityReconciliationRuns => inventory::identity_reconciliation_runs(),
        Entity::IdentityEvidenceEdges => inventory::identity_evidence_edges(),
    })
}

fn col(name: &str, col_type: ColumnType, semantic: Option<ColumnSemantic>) -> ColumnMeta {
    ColumnMeta {
        name: name.to_string(),
        col_type,
        semantic,
        unit: None,
    }
}

impl ColumnMeta {
    fn with_unit(mut self, unit: &str) -> Self {
        self.unit = Some(unit.to_string());
        self
    }
}
