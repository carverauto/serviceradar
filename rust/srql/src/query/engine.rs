use super::{
    PaginationMeta, QueryPlan, QueryRequest, QueryResponse, TranslateRequest, TranslateResponse,
    addon_fleet, addon_statuses, advisory_coordinates, agents, alerts, bmp_events,
    build_query_plan, capacity_forecasts, composite_results, cpu_metrics, dashboard_service_views,
    dashboards, device_graph, device_sweep_overlap, devices, disk_metrics, downsample,
    endpoint_inventory_scans, endpoint_package_catalog, endpoint_packages,
    endpoint_vulnerability_matches, events, field_survey, flows, gateways, graph_cypher, identity,
    interfaces, is_exhaustive_profile_query, logs, memory_metrics, mtr_traces, otel_metric_points,
    otel_metrics, process_metrics, public_endpoints, services, source_fact_disagreements,
    sweep_coverage, sweep_executions, sweep_groups, sweep_profiles, sweep_results,
    threat_intel_matches, timeseries_metrics, trace_summaries, traces, translate_request,
    virtualization, vulnerability_advisories, wifi_map,
};
use crate::{
    config::AppConfig,
    db::PgPool,
    error::{Result, ServiceError},
    pagination::encode_cursor,
    parser::{self, Entity},
};
use std::sync::Arc;
use tracing::error;

#[derive(Clone)]
pub struct QueryEngine {
    pool: PgPool,
    config: Arc<AppConfig>,
}

impl QueryEngine {
    pub fn new(pool: PgPool, config: Arc<AppConfig>) -> Self {
        Self { pool, config }
    }

    pub fn config(&self) -> &AppConfig {
        &self.config
    }

    pub async fn execute_query(&self, request: QueryRequest) -> Result<QueryResponse> {
        let ast = parser::parse(&request.query)?;
        let plan = build_query_plan(&self.config, &request, ast)?;
        let mut conn = self.pool.get().await.map_err(|err| {
            error!(error = ?err, "failed to acquire database connection");
            ServiceError::Internal(anyhow::anyhow!("{err:?}"))
        })?;

        // A `profile_hour_of_week[_peak]` stats query is a profile aggregation, never a
        // downsample — even though its `bucket:1h` clause sets `plan.downsample`. Without
        // this guard it dispatches to `downsample::execute`, which rejects the `timezone`
        // filter the profile route requires, so the query never reaches `execute_stats`
        // where the profile/peak builders live. (Discovered via a real-DB check: the
        // seasonal-disposition `profile_hour_of_week` query failed this way.)
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

        let results = if plan.downsample.is_some() && !is_profile_stats {
            downsample::execute(&mut conn, &plan).await?
        } else {
            match plan.entity {
                Entity::Agents => agents::execute(&mut conn, &plan).await?,
                Entity::AddonFleet => addon_fleet::execute(&mut conn, &plan).await?,
                Entity::AddonStatuses => addon_statuses::execute(&mut conn, &plan).await?,
                Entity::PublicEndpoints => public_endpoints::execute(&mut conn, &plan).await?,
                Entity::MergeAudit => identity::merge_audit::execute(&mut conn, &plan).await?,
                Entity::DeviceRevivalAudit => {
                    identity::device_revival_audit::execute(&mut conn, &plan).await?
                }
                Entity::DeviceIdentifiers => {
                    identity::device_identifiers::execute(&mut conn, &plan).await?
                }
                Entity::IdentityReconciliationRuns => {
                    identity::reconciliation_runs::execute(&mut conn, &plan).await?
                }
                Entity::IdentityEvidenceEdges => {
                    identity::evidence_edges::execute(&mut conn, &plan).await?
                }
                Entity::EndpointInventoryScans => {
                    endpoint_inventory_scans::execute(&mut conn, &plan).await?
                }
                Entity::EndpointPackageCatalog => {
                    endpoint_package_catalog::execute(&mut conn, &plan).await?
                }
                Entity::EndpointPackages => endpoint_packages::execute(&mut conn, &plan).await?,
                Entity::Devices => devices::execute(&mut conn, &plan).await?,
                Entity::DeviceGraph => device_graph::execute(&mut conn, &plan).await?,
                Entity::GraphCypher => {
                    graph_cypher::execute(&mut conn, &plan, &self.config.age_graph_name).await?
                }
                Entity::Events
                | Entity::SecurityFindings
                | Entity::ScanActivity
                | Entity::DnsActivity => events::execute(&mut conn, &plan).await?,
                Entity::BmpEvents => bmp_events::execute(&mut conn, &plan).await?,
                Entity::MtrTraces => mtr_traces::execute(&mut conn, &plan).await?,
                Entity::CapacityForecasts => capacity_forecasts::execute(&mut conn, &plan).await?,
                Entity::CompositeResults => composite_results::execute(&mut conn, &plan).await?,
                Entity::FieldSurveySessions
                | Entity::FieldSurveyRasters
                | Entity::FieldSurveyArtifacts
                | Entity::FieldSurveyRfObservations
                | Entity::FieldSurveyPoseSamples
                | Entity::FieldSurveyRfPoseMatches
                | Entity::FieldSurveySpectrumObservations => {
                    field_survey::execute(&mut conn, &plan).await?
                }
                Entity::WifiSites
                | Entity::WifiSiteSnapshots
                | Entity::WifiAccessPoints
                | Entity::WifiControllers
                | Entity::WifiRadiusGroups
                | Entity::WifiFleetHistory
                | Entity::WifiSiteReferences => wifi_map::execute(&mut conn, &plan).await?,
                Entity::Flows | Entity::AttributedFlows => flows::execute(&mut conn, &plan).await?,
                Entity::Interfaces => interfaces::execute(&mut conn, &plan).await?,
                Entity::Logs => logs::execute(&mut conn, &plan).await?,
                Entity::Gateways => gateways::execute(&mut conn, &plan).await?,
                Entity::OtelMetrics => otel_metrics::execute(&mut conn, &plan).await?,
                Entity::OtelMetricPoints => otel_metric_points::execute(&mut conn, &plan).await?,
                Entity::RperfMetrics
                | Entity::TimeseriesMetrics
                | Entity::TimeseriesMetricInterfaceHourly
                | Entity::SnmpMetrics => timeseries_metrics::execute(&mut conn, &plan).await?,
                Entity::CpuMetrics => cpu_metrics::execute(&mut conn, &plan).await?,
                Entity::MemoryMetrics => memory_metrics::execute(&mut conn, &plan).await?,
                Entity::DiskMetrics => disk_metrics::execute(&mut conn, &plan).await?,
                Entity::ProcessMetrics => process_metrics::execute(&mut conn, &plan).await?,
                Entity::Services => services::execute(&mut conn, &plan).await?,
                Entity::ServiceAvailability
                | Entity::MonitoredServices
                | Entity::SloEvaluations => {
                    dashboard_service_views::execute(&mut conn, &plan).await?
                }
                Entity::Dashboards => dashboards::execute(&mut conn, &plan).await?,
                Entity::TraceSummaries => trace_summaries::execute(&mut conn, &plan).await?,
                Entity::Traces => traces::execute(&mut conn, &plan).await?,
                Entity::Alerts => alerts::execute(&mut conn, &plan).await?,
                Entity::VirtualizationClusters
                | Entity::VirtualizationHosts
                | Entity::VirtualizationGuests
                | Entity::VirtualizationDatastores
                | Entity::VirtualizationHostDisks
                | Entity::VirtualizationNetworkInterfaces
                | Entity::VirtualizationStorageSystems => {
                    virtualization::execute(&mut conn, &plan).await?
                }
                Entity::ThreatIntelMatches => {
                    threat_intel_matches::execute(&mut conn, &plan).await?
                }
                Entity::SourceFactDisagreements => {
                    source_fact_disagreements::execute(&mut conn, &plan).await?
                }
                Entity::SweepGroups => sweep_groups::execute(&mut conn, &plan).await?,
                Entity::SweepProfiles => sweep_profiles::execute(&mut conn, &plan).await?,
                Entity::SweepExecutions => sweep_executions::execute(&mut conn, &plan).await?,
                Entity::SweepResults => sweep_results::execute(&mut conn, &plan).await?,
                Entity::SweepCoverage => sweep_coverage::execute(&mut conn, &plan).await?,
                Entity::DeviceSweepOverlap => {
                    device_sweep_overlap::execute(&mut conn, &plan).await?
                }
                Entity::VulnerabilityAdvisories => {
                    vulnerability_advisories::execute(&mut conn, &plan).await?
                }
                Entity::AdvisoryCoordinates => {
                    advisory_coordinates::execute(&mut conn, &plan).await?
                }
                Entity::EndpointVulnerabilityAssessments => {
                    endpoint_vulnerability_matches::execute(&mut conn, &plan).await?
                }
            }
        };

        let pagination = self.build_pagination(&plan, results.len() as i64)?;
        Ok(QueryResponse {
            results,
            pagination,
            error: None,
        })
    }

    pub async fn translate(&self, request: TranslateRequest) -> Result<TranslateResponse> {
        translate_request(self.config(), QueryRequest::from(request))
    }

    fn build_pagination(&self, plan: &QueryPlan, fetched: i64) -> Result<PaginationMeta> {
        let next_offset = plan.offset.saturating_add(plan.limit);
        let next_cursor = if fetched >= plan.limit {
            // Share the profile classification with cursor decoding and translation;
            // see is_exhaustive_profile_query for the pagination contract.
            if next_offset > self.config.max_cursor_offset && !is_exhaustive_profile_query(plan) {
                return Err(ServiceError::InvalidRequest(format!(
                    "query pagination reached the configured cursor limit of {} rows; narrow the query or raise srql_max_cursor_offset",
                    self.config.max_cursor_offset
                )));
            }

            Some(encode_cursor(next_offset, &self.config.cursor_secret)?)
        } else {
            None
        };

        let prev_cursor = if plan.offset > 0 {
            let prev = plan.offset.saturating_sub(plan.limit);
            Some(encode_cursor(prev, &self.config.cursor_secret)?)
        } else {
            None
        };

        Ok(PaginationMeta {
            next_cursor,
            prev_cursor,
            limit: Some(plan.limit),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        parser::{Entity, StatsSpec},
        query::QueryPlan,
    };

    fn plan(stats: &str) -> QueryPlan {
        QueryPlan {
            entity: Entity::TimeseriesMetrics,
            filters: Vec::new(),
            order: Vec::new(),
            limit: 50_000,
            offset: 100_000,
            time_range: None,
            stats: Some(StatsSpec::from_raw(stats)),
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        }
    }

    #[test]
    fn full_hour_of_week_profiles_are_exempt_from_the_generic_cursor_cap() {
        assert!(is_exhaustive_profile_query(&plan(
            "profile_hour_of_week_full(value)"
        )));
    }

    #[test]
    fn ordinary_queries_remain_cursor_capped() {
        assert!(!is_exhaustive_profile_query(&plan("avg(value)")));
    }
}
