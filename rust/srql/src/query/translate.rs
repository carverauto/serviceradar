use super::{
    PaginationMeta, QueryRequest, TranslateResponse, addon_statuses, agents, alerts, bmp_events,
    build_query_plan, capacity_forecasts, cpu_metrics, dashboard_service_views, dashboards,
    device_graph, devices, disk_metrics, downsample, endpoint_inventory_scans,
    endpoint_package_catalog, endpoint_packages, events, field_survey, flows, gateways,
    graph_cypher, interfaces, logs, memory_metrics, otel_metric_points, otel_metrics,
    process_metrics, services, timeseries_metrics, trace_summaries, traces, virtualization, viz,
    wifi_map,
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
            Entity::AddonStatuses => addon_statuses::to_sql_and_params(&plan)?,
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
            Entity::CapacityForecasts => capacity_forecasts::to_sql_and_params(&plan)?,
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
        }
    };

    let next_offset = plan.offset.saturating_add(plan.limit);
    let next_cursor = if next_offset <= config.max_cursor_offset {
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
