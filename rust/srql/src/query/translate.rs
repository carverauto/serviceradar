use super::{
    PaginationMeta, QueryRequest, TranslateResponse, addon_fleet, addon_statuses,
    advisory_coordinates, agents, alerts, bmp_events, build_query_plan, capacity_forecasts,
    composite_results, cpu_metrics, dashboard_service_views, dashboards, device_graph,
    device_sweep_overlap, devices, disk_metrics, downsample, endpoint_inventory_scans,
    endpoint_package_catalog, endpoint_packages, endpoint_vulnerability_matches, events,
    field_survey, flows, gateways, graph_cypher, identity, interfaces, is_exhaustive_profile_query,
    logs, memory_metrics, mtr_traces, otel_metric_points, otel_metrics, process_metrics,
    public_endpoints, services, source_fact_disagreements, sweep_coverage, sweep_executions,
    sweep_groups, sweep_profiles, sweep_results, threat_intel_matches, timeseries_metrics,
    trace_summaries, traces, virtualization, viz, vulnerability_advisories, wifi_map,
};
use crate::{
    config::AppConfig,
    error::Result,
    pagination::encode_cursor,
    parser::{self, Entity},
};

pub fn translate_request(config: &AppConfig, request: QueryRequest) -> Result<TranslateResponse> {
    let ast = parser::parse(&request.query)?;
    let plan = build_query_plan(config, &request, ast)?;
    let viz = viz::meta_for_plan(&plan);

    // A `profile_hour_of_week[_peak]` stats query is a profile aggregation, never a
    // downsample — even though its `bucket:1h` clause sets `plan.downsample`. Without this
    // guard it dispatches to the downsample builder (which rejects the `timezone` filter
    // the profile route needs), so the query never reaches the profile/peak SQL builders.
    // (Discovered via a real-DB check: the seasonal-disposition profile query failed here.)
    let is_profile_stats = plan
        .stats
        .as_ref()
        .map(|stats| {
            stats
                .as_raw()
                .trim_start()
                .to_ascii_lowercase()
                .starts_with("profile_hour_of_week")
        })
        .unwrap_or(false);

    let (sql, params) = if plan.downsample.is_some() && !is_profile_stats {
        downsample::to_sql_and_params(&plan)?
    } else {
        match plan.entity {
            Entity::Agents => agents::to_sql_and_params(&plan)?,
            Entity::AddonFleet => addon_fleet::to_sql_and_params(&plan)?,
            Entity::AddonStatuses => addon_statuses::to_sql_and_params(&plan)?,
            Entity::PublicEndpoints => public_endpoints::to_sql_and_params(&plan)?,
            Entity::MergeAudit => identity::merge_audit::to_sql_and_params(&plan)?,
            Entity::DeviceRevivalAudit => identity::device_revival_audit::to_sql_and_params(&plan)?,
            Entity::DeviceIdentifiers => identity::device_identifiers::to_sql_and_params(&plan)?,
            Entity::IdentityReconciliationRuns => {
                identity::reconciliation_runs::to_sql_and_params(&plan)?
            }
            Entity::IdentityEvidenceEdges => identity::evidence_edges::to_sql_and_params(&plan)?,
            Entity::EndpointInventoryScans => endpoint_inventory_scans::to_sql_and_params(&plan)?,
            Entity::EndpointPackageCatalog => endpoint_package_catalog::to_sql_and_params(&plan)?,
            Entity::EndpointPackages => endpoint_packages::to_sql_and_params(&plan)?,
            Entity::Devices => devices::to_sql_and_params(&plan)?,
            Entity::DeviceGraph => device_graph::to_sql_and_params(&plan)?,
            Entity::GraphCypher => graph_cypher::to_sql_and_params(&plan, &config.age_graph_name)?,
            Entity::Events
            | Entity::SecurityFindings
            | Entity::ScanActivity
            | Entity::DnsActivity => events::to_sql_and_params(&plan)?,
            Entity::BmpEvents => bmp_events::to_sql_and_params(&plan)?,
            Entity::MtrTraces => mtr_traces::to_sql_and_params(&plan)?,
            Entity::CapacityForecasts => capacity_forecasts::to_sql_and_params(&plan)?,
            Entity::CompositeResults => composite_results::to_sql_and_params(&plan)?,
            Entity::FieldSurveySessions
            | Entity::FieldSurveyRasters
            | Entity::FieldSurveyArtifacts
            | Entity::FieldSurveyRfObservations
            | Entity::FieldSurveyPoseSamples
            | Entity::FieldSurveyRfPoseMatches
            | Entity::FieldSurveySpectrumObservations => field_survey::to_sql_and_params(&plan)?,
            Entity::WifiSites
            | Entity::WifiSiteSnapshots
            | Entity::WifiAccessPoints
            | Entity::WifiControllers
            | Entity::WifiRadiusGroups
            | Entity::WifiFleetHistory
            | Entity::WifiSiteReferences => wifi_map::to_sql_and_params(&plan)?,
            Entity::Flows | Entity::AttributedFlows => flows::to_sql_and_params(&plan)?,
            Entity::Interfaces => interfaces::to_sql_and_params(&plan)?,
            Entity::Logs => logs::to_sql_and_params(&plan)?,
            Entity::Gateways => gateways::to_sql_and_params(&plan)?,
            Entity::OtelMetrics => otel_metrics::to_sql_and_params(&plan)?,
            Entity::OtelMetricPoints => otel_metric_points::to_sql_and_params(&plan)?,
            Entity::RperfMetrics
            | Entity::TimeseriesMetrics
            | Entity::TimeseriesMetricInterfaceHourly
            | Entity::SnmpMetrics => timeseries_metrics::to_sql_and_params(&plan)?,
            Entity::CpuMetrics => cpu_metrics::to_sql_and_params(&plan)?,
            Entity::MemoryMetrics => memory_metrics::to_sql_and_params(&plan)?,
            Entity::DiskMetrics => disk_metrics::to_sql_and_params(&plan)?,
            Entity::ProcessMetrics => process_metrics::to_sql_and_params(&plan)?,
            Entity::Services => services::to_sql_and_params(&plan)?,
            Entity::ServiceAvailability | Entity::MonitoredServices | Entity::SloEvaluations => {
                dashboard_service_views::to_sql_and_params(&plan)?
            }
            Entity::Dashboards => dashboards::to_sql_and_params(&plan)?,
            Entity::TraceSummaries => trace_summaries::to_sql_and_params(&plan)?,
            Entity::Traces => traces::to_sql_and_params(&plan)?,
            Entity::Alerts => alerts::to_sql_and_params(&plan)?,
            Entity::VirtualizationClusters
            | Entity::VirtualizationHosts
            | Entity::VirtualizationGuests
            | Entity::VirtualizationDatastores
            | Entity::VirtualizationHostDisks
            | Entity::VirtualizationNetworkInterfaces
            | Entity::VirtualizationStorageSystems => virtualization::to_sql_and_params(&plan)?,
            Entity::ThreatIntelMatches => threat_intel_matches::to_sql_and_params(&plan)?,
            Entity::SourceFactDisagreements => source_fact_disagreements::to_sql_and_params(&plan)?,
            Entity::SweepGroups => sweep_groups::to_sql_and_params(&plan)?,
            Entity::SweepProfiles => sweep_profiles::to_sql_and_params(&plan)?,
            Entity::SweepExecutions => sweep_executions::to_sql_and_params(&plan)?,
            Entity::SweepResults => sweep_results::to_sql_and_params(&plan)?,
            Entity::SweepCoverage => sweep_coverage::to_sql_and_params(&plan)?,
            Entity::DeviceSweepOverlap => device_sweep_overlap::to_sql_and_params(&plan)?,
            Entity::VulnerabilityAdvisories => vulnerability_advisories::to_sql_and_params(&plan)?,
            Entity::AdvisoryCoordinates => advisory_coordinates::to_sql_and_params(&plan)?,
            Entity::EndpointVulnerabilityAssessments => {
                endpoint_vulnerability_matches::to_sql_and_params(&plan)?
            }
        }
    };

    let next_offset = plan.offset.saturating_add(plan.limit);
    let next_cursor =
        if next_offset <= config.max_cursor_offset || is_exhaustive_profile_query(&plan) {
            Some(encode_cursor(next_offset, &config.cursor_secret)?)
        } else {
            None
        };
    let prev_cursor = if plan.offset > 0 {
        Some(encode_cursor(
            plan.offset.saturating_sub(plan.limit),
            &config.cursor_secret,
        )?)
    } else {
        None
    };

    Ok(TranslateResponse {
        sql,
        params,
        pagination: PaginationMeta {
            next_cursor,
            prev_cursor,
            limit: Some(plan.limit),
        },
        viz,
    })
}
