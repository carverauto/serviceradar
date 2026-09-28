# CNPG telemetry reader inventory (task 5.1)

Every code path that reads a CNPG telemetry table or one of its continuous aggregates, found
by searching for each table and aggregate name rather than for known modules. Taken from
`staging` at `337792bccffd4577e66bc42402c5cc6f99feecf2` (2026-09-27); `file:line` references
are exact at that commit.

Path prefixes: `W` = `elixir/web-ng/lib/serviceradar_web_ng_web`,
`WN` = `elixir/web-ng/lib/serviceradar_web_ng`, `C` = `elixir/serviceradar_core/lib/serviceradar`,
`S` = `rust/srql/src/query`.

Routing column:

- **Readers**: branches through `ServiceRadar.Analytics.StarRocks.Readers` (directly or through
  `LogEventConsumers`, `MetricConsumers`, `FlowConsumers` or `MtrWarehouse`).
- **SRQL routed**: an SRQL entity that `Readers.dataset_for_entity/1` maps to a dataset, so it is
  served by StarRocks once that dataset is cut over (MTR keys on `enabled?/0` instead).
- **SRQL CNPG**: an SRQL entity with no dataset mapping; it always runs on CNPG.
- **direct**: raw SQL, Ecto or Ash read against CNPG.

Both SRQL entry points route through `Readers`: web-ng `WN/srql.ex:33` / `:72` (mode at `:146`)
and core `C/observability/srql_runner.ex:24` / `:31` (mode at `:74`). The StarRocks SRQL dialect
(`S/starrocks.rs:90`) covers flows, attributed flows, timeseries, SNMP and rperf metrics, logs,
and events with its sub-entities, including `rollup_stats:severity` and
`rollup_stats:anomaly_findings`; MTR has its own dialect (`S/starrocks/mtr.rs:36`).

## Telemetry objects

| Object | Type |
|---|---|
| ocsf_events; ocsf_events_hourly_stats | hypertable; cagg |
| logs; logs_severity_stats_5m | hypertable; cagg |
| timeseries_metrics; *_hourly, *_interface_hourly, *_disk_hourly | hypertable; caggs |
| ocsf_network_activity; 5m_traffic, flow_traffic_1h/1d, hourly talkers/listeners/ports/proto/conversations | hypertable; caggs |
| bgp_routing_info | hypertable (derived from flows) |
| otel_traces; traces_stats_5m, spans_red_1h; otel_trace_summaries | hypertable; caggs; worker-derived table |
| otel_metrics; otel_metrics_hourly_stats; otel_metric_points | hypertable; cagg; hypertable |
| mtr_traces, mtr_hops | hypertables |
| cpu/memory/disk/process_metrics and *_hourly; cpu_cluster_metrics | hypertables; caggs (no writer, see findings) |
| bmp_routing_events | hypertable |
| service_status | hypertable |

Excluded as control plane: `stateful_alert_rule_histories`, `otel_service_catalog`,
`service_state`. The legacy `events` CloudEvents hypertable has no readers.

## Readers that bypass `Readers` (the 5.3 / 5.4 work)

### Events

| Reader | Reads | Surface |
|---|---|---|
| `AnalyticsLive.get_hourly_event_stats` `W/live/analytics_live/index.ex:85` | ocsf_events_hourly_stats | Analytics page |
| `GodViewStream.fetch_recent_ocsf_causal_events` `WN/topology/god_view_stream.ex:5366` | ocsf_events | God View causal overlay |
| `SecurityLive.selected_detection` `W/live/security_live/index.ex:543` | ocsf_events (Ash) | Security detection detail |
| `CameraRelayHealth.overview` `WN/camera_relay_health.ex:17` (read `:42`) | ocsf_events (Ash) | Camera relay page |
| `EndpointVulnerabilityFindingEmitter` `ocsf_event_recorded?` `:253`, `ocsf_event_open?` `:266` | ocsf_events | non-UI dedupe / open check |
| `Processors.AnalyticsSignals` `existing_inventory_vulnerability_lifecycle` `:369`, `existing_ocsf_event_times` `:540` | ocsf_events | EventWriter write path (reads before writing) |

### Logs

| Reader | Reads | Surface |
|---|---|---|
| `RefreshLogsSeverityStatsWorker` `C/jobs/refresh_logs_severity_stats_worker.ex:146`, `:215` | logs, logs_severity_stats_5m | Oban (web-ng shim) |
| `OtelServiceCatalogBackfillWorker` `C/observability/otel_service_catalog_backfill_worker.ex:85` | logs_severity_stats_5m, spans_red_1h, otel_metrics_hourly_stats | one-shot Oban |
| JSON:API `/api/v2/logs` (`C/observability/log.ex:48`) | logs | API |

### Metrics

| Reader | Reads | Surface |
|---|---|---|
| SRQL `timeseries_metric_interface_hourly`, `timeseries_metric_disk_hourly` (`S/cagg.rs:66-69`) | interface/disk hourly caggs | not in `dataset_for_entity`: always CNPG |
| SRQL `interfaces` (`S/interfaces/sql.rs:42`) | timeseries_metrics | Interfaces page, device tab |
| `DeviceCorrelation` `C/event_writer/device_correlation.ex:173`, `:191`, `:208` | raw + interface_hourly | EventWriter enrichment |
| `InterfaceThresholdWorker.get_latest_metric_value` `C/inventory/interface_threshold_worker.ex:409` | timeseries_metrics | Oban |
| `CapacityForecasting.Source` `:109`, `:123`; `SeasonalDisposition.Source` `:201` | disk/interface hourly caggs | non-UI (via the unmapped SRQL entities) |
| JSON:API RawMetricResource / HourlyMetricResource | raw + caggs | API |

### OTel traces and metrics (metrics SRQL routed by 3.1; traces by 3.2)

| Reader | Reads | Surface |
|---|---|---|
| SRQL `traces`, `trace_summaries`, `otel_metrics`, `otel_metric_points` | all trace and OTel metric objects | routed by 3.1 (metrics) and 3.2 (traces) |
| `Stats.traces_summary` `W/stats.ex:339`, `metrics_summary` `:371`, `trace_summary_counts` `:414` | traces_stats_5m, spans_red_1h, otel_trace_summaries | dashboard trace card, Analytics, logs page (SRQL; routed by 3.2) |
| `Stats.trace_rollup_status` `W/stats.ex:522` | raw, summaries, traces_stats_5m | Analytics, logs page (reads the warehouse when enabled, 3.2) |
| LogLive traces/metrics tabs, `TraceLive.Show`, `MetricLive.Show`, Analytics slow spans, onboarding | traces, summaries, otel_metrics, points | SRQL CNPG |
| LogLive `load_sparklines` `W/live/log_live/index.ex:10155` | otel_metrics | logs page OTel sparklines (direct); removed by 3.1, it queried columns `otel_metrics` does not have |
| `RefreshTraceSummariesWorker` `C/jobs/refresh_trace_summaries_worker.ex:266`; `RootSpanRatioWorker` `C/jobs/root_span_ratio_worker.ex:57` | otel_traces | Oban (read and write the warehouse when enabled, 3.2) |
| JSON:API `/otel_traces`, `/otel_trace_summaries`, `/otel_metrics`, `/otel_metric_points` | raw | API |

### Sysmon tables, BMP / BGP, service status

| Reader | Reads | Surface |
|---|---|---|
| SRQL `cpu`, `memory`, `disk`, `process` metrics; Analytics high utilization `:130-132`; device list `index_data/telemetry.ex:87`; authored dashboard `source_queries.ex:54`; JSON:API | cpu/memory/disk/process tables and caggs | SRQL CNPG / API |
| SRQL `bmp_events`; `BmpLive` `W/live/bmp_live/index.ex:29` | bmp_routing_events | BMP page |
| `GodViewStream.fetch_recent_bmp_routing_events` `WN/topology/god_view_stream.ex:5344` | bmp_routing_events | God View |
| `ServiceRadar.BGP.Stats` `C/bgp/stats.ex:29` and seven more queries | bgp_routing_info | BGP page |
| SRQL `services`, `service_availability`, `monitored_services`, `slo_evaluations` | service_status | Services pages, device health, authored dashboards |
| `Stats.services_availability` `W/stats.ex:461`; dashboard `service_sparklines.ex:30` | services_availability_5m | dashboard service card and sparkline (see findings) |
| Analytics `get_service_counts` `W/live/analytics_live/index.ex:536` | service_status | Analytics |
| `ServiceStateRegistry` history repair and queries (`history_repair.ex:20`, `queries.ex:27`, `:80`) | service_status | non-UI |
| `PluginResultIngestor` status reads (`:258`, `:328`, `:352`, `:771`, `:1047`, `:1070`) | service_status | write path (reads before writing) |
| JSON:API `/service_status`, `/cpu_cluster_metrics` | raw | API |

### Other

| Reader | Reads | Surface |
|---|---|---|
| `ColdTier.Exporter` (`C/cold_tier/`) | seven hot tables | exports CNPG chunks; exports nothing once CNPG stops receiving rows |
| `ScanResult.by_scan_run` (scan page, scan export, scan API, composite check orchestrator) | adhoc_scan_results | UI + API |
| Dashboard `survey_summary`; SRQL `field_survey` | survey tables | UI |
| SRQL `endpoint_packages` hourly counts | endpoint inventory caggs | SRQL CNPG |
| SRQL `capacity_forecasts` and its readers | capacity_forecasts (derived) | SRQL CNPG |

## Readers already routed through `Readers` or routed SRQL

Events: SRQL `events` and every page using it (event detail, logs page events tab, device
anomalies, observability health, Analytics fallback), `DashboardLive.EventWindow`,
`AnomalyIngestSilenceWorker`, `DnsPolicySource`. Logs: SRQL `logs`, `Stats.logs_severity`,
`Stats.logs_rollup_status`, the logs, device, trace, event and onboarding log views. Metrics:
SRQL timeseries, SNMP and rperf metrics, `TopologyGraph.Telemetry.Metrics`, God View and
dashboard interface sparklines, device sysmon and ICMP views, `PeakProfile`, the raw halves of
`CapacityForecasting.Source` and `SeasonalDisposition.Source`. Flows: SRQL flows and every flow
page, `FlowAttribution.Correlation`, the netflow, retrohunt, exporter cache, IP enrichment and
endpoint scan workers, the dashboard throughput sparkline
(`TrafficSparklines.warehouse_traffic_rows/2`), the device Flows-tab presence probes
(`DeviceLive.FlowData`), and `DeviceRiskIocExposure` (warehouse flow page when
`Readers.backend(:flows) == :starrocks`, CNPG kept otherwise). MTR: SRQL MTR, `MtrData`,
dashboard MTR card and sparkline, `MtrTrace`,
`MtrCompare`. OTel metrics (3.1): SRQL `otel_metrics`/`otel_metric_points` and every page using
them (logs page metrics tab and OTLP view, `MetricLive.Show`, Analytics slowest spans,
onboarding), routed on `enabled?/0` like MTR.

Go, `serviceradar_core_elx`, `serviceradar_agent_gateway`, `datasvc`, `palisade` and
`serviceradar_srql` read no telemetry.

## Findings

1. **`services_availability_5m` did not exist.** No migration or baseline created it (its
   original definition used `COUNT(DISTINCT ...)`, which a continuous aggregate refuses), so the
   dashboard service card (`Stats.services_availability`), the service health sparkline and SRQL
   `rollup_stats:availability` returned nothing. Resolved for CNPG by migration
   `20260927120000_ensure_services_availability_5m_cagg`; it still needs a warehouse
   counterpart when service status moves in 5.4.
2. **The dedicated sysmon tables have no writer.** `cpu_metrics`, `memory_metrics`,
   `disk_metrics`, `process_metrics` and `cpu_cluster_metrics` have Ash resources, retention and
   readers but no insert anywhere; device sysmon data lives in `timeseries_metrics` as
   `sysmon.*`. Their readers are legacy; retire them rather than building warehouse versions.
3. **`Readers.mode_for/1` routes events, logs and metrics on `cutover_datasets`, not
   `enabled?/0`.** Every reader marked routed above still reads CNPG until the cutover list
   names its dataset; 5.2 collapses this to `enabled?/0`.
4. **Two metrics SRQL entities are unmapped** (`timeseries_metric_interface_hourly`,
   `timeseries_metric_disk_hourly`), so capacity forecasting and seasonal disposition read CNPG
   unconditionally.
5. **Flows keep CNPG fallbacks** in the dashboard throughput sparkline and the device Flows tab
   probes although flows are warehouse-only, and `DeviceRiskIocExposure` always reads CNPG flows.
   Resolved by issue #4869: the dashboard sparkline and the device Flows-tab presence probes
   route through `Readers` and render empty/unavailable on `{:error, :starrocks_required}` rather
   than reading CNPG flows, and `DeviceRiskIocExposure` gained a warehouse flow page selected by
   `Readers.backend(:flows) == :starrocks` (the CNPG query remains for installations without the
   warehouse). The risk reader cuts over with the flows dataset, hard and by
   default: flows ships in the default cutover set of a warehouse-enabled
   installation, and flow warehouse writes are required before the JetStream
   ACK (`Destination.warehouse_required?/1`). Rows written before the
   `agent_id` enrichment lack agent attribution (and pre-deploy shadow loads
   were best-effort), so right after the flip risk reads can miss an
   agent-only device for up to one lookback (default 3600s) -- a bounded gap
   the captain explicitly accepted; no new such row can appear. See task 2.4.
6. **`rust/srql/src/server.rs:51` (`/api/query`) runs every entity on CNPG** and bypasses
   `Readers`; no chart deploys it, so it may be dead. **Resolved (issue #4873):** the standalone
   server was dead — no Helm template, Compose service, k8s manifest or Docker image ran it, and
   `//rust/srql:srql_bin` had no reverse dependencies — so the axum server, its routes and the
   binary target were removed. The crate remains a library (`translate_request`, `QueryEngine`)
   for the `serviceradar_srql` NIF and `correlation-engine`.
7. **Write-path reads** (`AnalyticsSignals`, `EndpointVulnerabilityFindingEmitter`,
   `PluginResultIngestor` / `PluginResultStateWinner`, `MtrMetricsIngestor.stored_trace_ids`)
   read CNPG before writing; they move with the writers in 5.2, not with the readers in 5.4.
8. **`ColdTier.Exporter`** exports CNPG chunks, so it stops producing Parquet once a dataset is
   warehouse-only; it needs a warehouse source or to be scoped to installations without
   StarRocks.
