# ServiceRadar Data Flow & Database Schema

> High-level architecture notes covering the end-to-end data flow (edge collectors → NATS
> JetStream / ERTS cluster → core → CNPG → UI) and the CNPG (`platform` schema) database model.
> Derived from a code/docs sweep; file references point at the authoritative source.

## TL;DR

ServiceRadar has **two parallel planes** that both feed the UI:

1. **Bulk telemetry plane** — metrics/logs/events/flows ride **NATS JetStream** into
   `serviceradar_core`, which is the *sole* bulk writer to CNPG.
2. **Control / coordination plane** — `agent-gateway`, `core`, and `web-ng` form one
   **Erlang (ERTS) mTLS cluster** and coordinate live status/config over RPC + Phoenix PubSub,
   *not* NATS. The UI gets history from CNPG and live changes from PubSub.

**Hard rule (AGENTS.md:37-49):** all metrics MUST publish to a JetStream subject first and be
persisted by the `event_writer` consumer — never write metrics straight to CNPG. Reason: a metric
that lands straight in a hypertable is invisible to real-time consumers (anomaly detection, causal
engine) until queried back out. The one legacy exception is the agent→gateway→core `StreamStatus`
gRPC path that writes sysmon metrics directly to the DB; it is being migrated to JetStream
(`openspec/changes/add-causal-anomaly-detection`, `move-anomaly-detection-to-edge`). Do not add new
direct-to-DB metric writes.

---

## 1. High-level data flow

```
                          EDGE                          │        CONTROL PLANE (ERTS mTLS cluster)      │   STORAGE
                                                        │                                              │
┌────────────────────────────────────────┐             │                                              │
│ serviceradar-agent (Go)                 │             │                                              │
│  ├ sysmon (cpu/mem/disk/process)        │  mTLS gRPC  │  ┌───────────────────────┐                   │
│  ├ snmp checker                         │─StreamStatus──▶│ agent-gateway (Elixir)│                   │
│  ├ sweep / netprobe / icmp / rperf      │  (chunks)   │  │  StatusProcessor       │                  │
│  └ wazero Wasm plugins                  │             │  │  → publishes to NATS   │──┐               │
└────────────────────────────────────────┘             │  └───────────────────────┘  │               │
                                                        │            ▲ ERTS RPC/PubSub │               │
┌──────────────────────────────────────┐               │            │                 │               │
│ Rust collectors (publish direct)     │               │  ┌─────────┴──────────┐      │ metrics.*     │
│  flow-collector → flows stream       │───────────────────│ core (Elixir)      │     │ logs.*        │
│    subjects flows.raw.{netflow,sflow}│                   │  EventWriter       │     │               │
│  trapd          → logs.snmp          │   NATS         │  │  event_writer      │◀────┤ events.*      │
│  otel           → otel.traces/metrics│   JetStream    │  │  (Broadway pull    │     │ otel.*        │
│  log-collector/flowgger → logs.*     │──────┐         │  │   consumers)       │     │ flows.raw.*   │
└──────────────────────────────────────┘      │         │  │  → BulkInsert      │──── insert_all ────▶ CNPG
                                               └─────────────▶└────────────────────┘    (Ecto/Repo)    │  Postgres
                                            JetStream streams:                          │              │  + Timescale
                                            EVENTS/METRICS/LOGS/OTEL_*/                  │              │  + Apache AGE
                                            FLOWS/*_CAUSAL                               │              │
                                                        │  ┌────────────────────┐       │              │
   User ──HTTPS──▶ Caddy/ingress ─────────────────────────▶│ web-ng (Phoenix    │       │              │
                                                        │  │ LiveView)          │───SRQL→SQL──reads────▶ CNPG
                                                        │  │  embeds SRQL NIF   │◀──PubSub live status──┘
                                                        │  └────────────────────┘       │
```

---

## 2. Component inventory

| Component | Language | Role |
|---|---|---|
| `serviceradar-agent` | Go (`go/cmd/agent`) | Single edge runtime. Built-in collectors/checkers (SNMP `go/pkg/agent/snmp`, sysmon `go/pkg/sysmon`, sweeper `go/pkg/sweeper`) + sandboxed wazero Wasm plugins. Streams results outbound over mTLS gRPC. |
| `agent-gateway` | Elixir (`elixir/serviceradar_agent_gateway`) | Edge ingress. gRPC server terminating agent connections (`AgentGatewayService`); `StatusProcessor` turns agent status into NATS JetStream publishes. Part of the ERTS cluster. |
| `core` / `serviceradar_core` | Elixir (`elixir/serviceradar_core`, run via `serviceradar_core_elx`) | Control plane + bulk ingestion. Hosts the `event_writer` Broadway pipeline (JetStream pull consumers), Zen normalization, `log-promotion` consumer, and all telemetry DB writes. |
| `web-ng` | Elixir/Phoenix LiveView (`elixir/web-ng`) | UI + HTTP API. Embeds SRQL via Rustler NIF. Reads CNPG for display; gets live status via PubSub. |
| `serviceradar_srql` | Elixir + Rust NIF (`elixir/serviceradar_srql`, `rust/srql`) | SRQL query engine (parse/translate only), Rustler-loaded. |
| `datasvc` | Elixir/Go (`elixir/datasvc`, `go/pkg/datasvc`) | gRPC service (port 50057) fronting NATS KV + object store. Not on the telemetry hot path. |
| `flow-collector` | Rust (`rust/flow-collector`) | NetFlow/sFlow collector → publishes to NATS. |
| `trapd` | Rust (`rust/trapd`) | SNMP trap receiver → publishes `logs.snmp`. |
| `otel` | Rust (`rust/otel`) | OTLP receiver → publishes traces/metrics/logs to NATS. |
| `log-collector` / `flowgger` | Rust | Syslog/log ingestion. |
| `netprobe`, `rperf-client/server`, `bmp-collector`, `powerdns`, anomaly/correlation addons | Rust | Additional probes/collectors and analytics addons. |
| CNPG | Postgres + TimescaleDB + Apache AGE | System of record for inventory, telemetry, analytics. |
| NATS JetStream | — | Bulk telemetry bus between collectors and core. |

---

## 3. Ordered transport hops

| # | From → To | Protocol | Detail |
|---|-----------|----------|--------|
| 1 | collectors/checkers → agent | in-process | Go agent runs built-in checkers + sandboxed wazero Wasm plugins |
| 2 | agent → agent-gateway | **mTLS gRPC** | `AgentGatewayService.StreamStatus(stream GatewayStatusChunk)` — `proto/monitoring.proto:43`; handler `agent_gateway_server.ex:369`. Other RPCs: `PushStatus`, `StreamConfig`, `ControlStream` (`monitoring.proto:39-45`) |
| 3 | agent-gateway → NATS | **JetStream publish** | `StatusProcessor` fans status into `metrics.{icmp,snmp,sysmon,rperf,sweep,mtr,timeseries}` + OTLP relay subjects. Config `serviceradar_agent_gateway/config/config.exs:22-68`, `config/runtime.exs:355-399` |
| 3′ | Rust collectors → NATS | **JetStream publish** | flow-collector, trapd, otel publish *directly*, bypassing the gateway |
| 4 | gateway ↔ core ↔ web-ng | **mTLS Erlang distribution (ERTS)** | RPC + Phoenix PubSub. No gRPC between control-plane nodes (`docs/docs/architecture.md:39-40,49-60`). This is how live status reaches LiveView without a DB round-trip |
| 5 | NATS → core | **JetStream pull consumers** | `event_writer` Broadway pipeline; durable consumer `serviceradar-event-writer` (`runtime.exs:1525`). Modules `lib/serviceradar/event_writer/{producer,pipeline,processor}.ex`, `lib/serviceradar/nats/jetstream_consumer.ex` |
| 6 | core → CNPG | **Ecto `insert_all`** | `EventWriter.BulkInsert.insert_all/3` (`bulk_insert.ex:26-50`), chunked under the 65,535 bind-param limit (`:13-15`). Acks after successful write (`event_writer/jetstream_ack.ex`) |
| 7 | web-ng → CNPG | **SRQL → SQL via Ecto** | reads for the UI (`data-pipeline.md:59`, `architecture.md:46`) |

**Only `serviceradar_core` writes bulk telemetry to the DB.** Collectors and gateways never touch CNPG.

### JetStream streams & subjects

Consumer stream config in `elixir/serviceradar_core/config/runtime.exs:1537-1656`:

| Stream / consumer | Subject | Processor | Ref (runtime.exs) |
|---|---|---|---|
| `EVENTS` (stream `events`) | `events.>` | Events | 1539-1550 |
| `PDNS_OCSF` (`events`) | `pdns.ocsf` | PowerDNS | 1552-1558 |
| `FALCO` (`events`) | `falco.logs` | FalcoEvents | 1560-1567 |
| `TRIVY` (`trivy_reports`) | `trivy.report.>` | TrivyReports | 1568-1575 |
| `OTEL_METRICS` | `otel.metrics.>` | OtelMetrics | 1576-1582 |
| `OTEL_TRACES` | `otel.traces.>` | OtelTraces | 1583-1589 |
| `LOGS` (`events`) | `logs.>` | Logs | 1590-1597 |
| `METRICS` (`metrics`) | `metrics.>` | Metrics | 1598-1612 |
| `BMP_CAUSAL` | `bmp.events.>` | AnalyticsSignals | 1613-1619 |
| `ARANCINI_CAUSAL` | `arancini.updates.>` | AnalyticsSignals | 1620-1626 |
| `SIEM_CAUSAL` | `siem.events.>` | AnalyticsSignals | 1627-1633 |
| `ANALYTICS_PREDICTIONS` (`events`) | `signals.analytics.predictions.>` | AnalyticsSignals | 1634-1641 |
| `SFLOW_RAW` | `flows.raw.sflow` | Flows | 1642-1648 |
| `NETFLOW_RAW` | `flows.raw.netflow` | Flows | 1649-1655 |

Producer-side subjects:
- Gateway metrics: `metrics.{icmp,mtr,rperf,snmp,sweep,sysmon,timeseries}`, OTLP relay `otel.traces.raw`, `logs.otel`, `otel.metrics.raw`, `otel.metrics.derived` (`otlp_relay_publisher.ex:138-141`, `plugin_metrics_publisher.ex:17`).
- flow-collector: `flows.raw.{sflow,netflow,extra}` (`rust/flow-collector/src/config.rs:529-531`, `metrics.rs:219`).
- trapd: `logs.snmp` (`rust/trapd/src/config.rs:200`, `main.rs:557`).
- Edge provisioning wildcards: `logs.syslog.>`, `logs.snmp.>`, `events.netflow.>`, `otel.traces.>`, `otel.metrics.>`, `logs.otel`, `events.falco.>` (`provision_collector_worker.ex:188-216`).
- Camera pipeline: `events.ocsf.processed` (`camera/event_ingestor.ex:242`).

Retention: `events` stream file storage, discard=old, 8 GiB / 24h (`runtime.exs:1546-1550`); `metrics` stream 1 GiB / 30 min (`:1605-1609`). Consumer tunables `EVENT_WRITER_*` (batch 100, pull batch 16, max_ack_pending 256, max_deliver 5) at `runtime.exs:1523-1536`.

---

## 4. SRQL (query layer)

SRQL (ServiceRadar Query Language) is a faceted query language
(`in:<entity> field:value stats:count() by field bucket:1h time:24h`) that the Rust crate `rust/srql`
parses → AST → query plan → per-entity SQL builder → **parameterized Postgres SQL** (and Cypher for the
graph entity). Pipeline: `parser.rs:30` → `parser/ast.rs` → `query/plan.rs:11` → `query/engine.rs:35`.

**Single physical backend: CNPG Postgres** (Diesel + diesel-async + bb8 pool, `db.rs:23`). Inside it,
SRQL routes to multiple logical backends:
- **Apache AGE** — `graph_cypher` entity runs read-only Cypher via `ag_catalog.cypher('<graph>', ...)`; graph defaults to `platform_graph`/`serviceradar` (`query/graph_cypher.rs:60-65`, guard `:114`).
- **Timescale continuous aggregates** — metric/stats/downsample queries route to hourly CAGGs (`cpu_metrics_hourly`, `memory_metrics_hourly`, `timeseries_metrics_hourly`, …) via `query/cagg.rs:26,112,141`.
- OCSF / relational tables queried as normal SQL.

**~55 entity types** — canonical enum `parser/ast.rs:8-68`, name/alias map `parser/entity.rs:6-138`
(inventory/graph, security events, field survey/RF, WiFi site map, virtualization, observability/OTel,
metrics/timeseries, services/dashboards, flows, endpoint SBOM).

Exposed two ways:
- **In-process Erlang NIF (UI hot path)** — `parse_ast` / `translate` NIFs (`native/srql_nif/src/lib.rs:28,38`).
  web-ng's `ServiceRadarWebNG.SRQL` calls the NIF to get `{sql, params}`, then executes it directly through
  its own Ecto `ServiceRadar.Repo` (`srql.ex:132,148,182`) — no network hop. `elixir/serviceradar_srql`
  is the thin Elixir wrapper over the Rust crate; web-ng depends on it via `mix.exs:63` and adds read-only
  enforcement, statement timeouts, Arrow encoding, telemetry.
- **Standalone axum HTTP service** — `POST /api/query` (execute), `POST /translate` (SQL+params only),
  `GET /healthz`, `x-api-key` auth, default port **8480** (`server.rs:48-59,101`; `config.rs:228`). Used by
  the **Go core** (`SRQLConfig`/`srql.base_url`, `go/pkg/models/config.go:127,214`) and other clients — not
  the UI.

---

## 5. Database schema (CNPG, `platform` schema)

One Postgres cluster; three engines layered in: relational tables + TimescaleDB
hypertables/continuous-aggregates + one Apache AGE graph. **Schema is managed exclusively through
Elixir/Ecto migrations** in `elixir/serviceradar_core/priv/repo/migrations/` (~325 files, ~200 tables).
web-ng has no migrations of its own. Ingestion services never run DDL.

Foundational migrations:
- `20260117080000_bootstrap_extensions.exs` — extensions
- `20260117090000_rebuild_schema.exs` — ~60 base config/inventory tables + SQL helpers (`uuid_generate_v7`, …) + Oban tables
- `20260117100000_create_timeseries_tables.exs` — core TimescaleDB hypertables
- `20260119090000_add_age_graph_serviceradar.exs` — AGE graph

### 5.1 Device / entity inventory (regular tables)

| Table | PK | Stores |
|---|---|---|
| `ocsf_devices` (`rebuild_schema.exs:962`) | `uid` text | Canonical device inventory (OCSF Device): type/name/hostname/ip/mac/vendor/model, first/last/created/modified times, risk_level/score, `is_managed/compliant/trusted/active/available`, `os`/`hw_info` maps, `network_interfaces[]`, `owner`/`org`/`groups[]`, `agent_list[]`, `gateway_id`, `agent_id`, `discovery_sources[]`, `tags`/`metadata`, `group_id`. Unique on `uid`. |
| `ocsf_agents` (`:1230`) | `uid` text | Monitoring agents: name/type/version, `policies[]`, `gateway_id`, `device_uid`, `capabilities[]`, host/ip/port, `spiffe_identity`, `status` (default connecting), `is_healthy`, seen/created/modified, `config_source`. |
| `gateways` (`:944`) | `gateway_id` text | Gateway registrations: component_id, registration_source, status, spiffe_identity, first/last seen, is_healthy, agent_count, checker_count, `partition_id`. |
| `partitions` (`:1164`) | `id` uuid | Network partitions: name, `slug` (unique), `cidr_ranges[]`, default_gateway, dns_servers, site/region/environment, connectivity_type, proxy_endpoint. |
| `device_groups` (`:533`) | `id` uuid | Self-referential device grouping tree: name (unique), type, `parent_id`, device_count. |
| `device_identifiers` (`:806`) | `id` bigserial | Identity map: `device_id`→`ocsf_devices.uid`, identifier_type/value, partition, confidence, source, first/last seen, verified. Unique `(identifier_type, identifier_value, partition)`. |
| `device_alias_states` (`:1324`) | — | Alias lifecycle: device_id, partition, alias_type/value, `state` (default detected), first/last_seen_at, sighting_count. Unique `(device_id, alias_type, alias_value)`. |
| `merge_audit` (`:331`) | `event_id` uuid | Device merge audit: from/to device, reason, confidence_score, source, details, created_at. |
| `source_identity_conflicts` (`20260706193000`) | — | Armis/integration reconciliation conflicts. |
| `discovered_interfaces` (`:1026`) | `(timestamp, device_id, if_index)` | **Hypertable** — SNMP interface inventory over time: if_name/descr/alias, if_speed, if_phys_address, `ip_addresses[]`, admin/oper status, metadata (GIN). |
| `interface_classification_rules` (`20260121013000`) | — | Interface classification. |
| `mapper_topology_links` (`20260119051352`) | `id` uuid | LLDP/CDP neighbor links (local/neighbor chassis/port/system/mgmt). |
| `runtime_topology_links` + `runtime_topology_projection_meta` (`20260620224500`) | — | Projected topology (plane, local/neighbor device, relation_type, evidence_class) + projection refresh metadata. |

### 5.2 Metrics / time-series (TimescaleDB hypertables — `create_timeseries_tables.exs` unless noted)

| Table | Time / PK | Stores |
|---|---|---|
| `cpu_metrics` | `(timestamp, gateway_id, core_id)` | per-core CPU % / freq / label / cluster / device_id / partition |
| `memory_metrics` | `(timestamp, gateway_id)` | total/used/available bytes, usage % |
| `disk_metrics` | `(timestamp, gateway_id, mount_point)` | per-mount total/used/avail bytes, usage % |
| `process_metrics` | `(timestamp, gateway_id, pid)` | per-process cpu/mem/status |
| `timeseries_metrics` | `(timestamp, gateway_id, metric_name)` | **generic sink** — SNMP counters, interface counters: `metric_type`, `device_id`, `value` float8, `unit`, `tags` jsonb, `partition`, `scale`, `is_delta`, `target_device_ip`, `if_index`, `counter_width` |
| `otel_traces` | `(timestamp, trace_id, span_id)` | OTel spans |
| `otel_metrics` | `(timestamp, span_name, service_name, span_id)` | span-derived RED metrics (duration_ms, http/grpc dims, is_slow) |
| `otel_metric_points` (`20260611060000`) | `(timestamp, metric_name, service_name, attributes_hash)` | real OTLP datapoints (sum/gauge/histogram); 30-day retention, 6h chunks |
| `cpu_cluster_metrics` (`20260613030000`) | — | aggregated cluster CPU |
| `capacity_forecasts` (`20260612080000`) | `(forecasted_at, resource_key, metric_name, horizon_seconds)` | linear-model capacity projections: slope, projected_value/exhaustion_at, confidence, status |

`netflow_metrics` was **dropped** (`20260403191500`); flow telemetry now lives in `ocsf_network_activity`.

### 5.3 Flow / NetFlow

- `ocsf_network_activity` (`20260201072922`) — **hypertable** on `time`, OCSF 4001 Network Activity:
  class/category/activity/type_uid, src/dst endpoint+port+ASN, protocol_num/name, tcp_flags,
  bytes/packets total+in/out, sampler_address, `sampling_rate`, full `ocsf_payload` jsonb, partition.
  Many indexes (src/dst ip+time, proto+time, ports+time, GIN on payload, top-talkers/ports).
- Config/enrichment: `netflow_{local_cidrs,provider_cidrs,oui_prefixes,settings,exporter_cache,interface_cache,app_classification_rules,port_anomaly_flags,port_scan_flags}`, dataset snapshots.
- BGP: `bgp_routing_info`, `bmp_settings`, hypertable `bmp_routing_events` (`20260218235900`).
- Flow→process attribution: `flow_process_attribution_current`, `workload_identity_current`.
- MTR/traceroute: `mtr_traces` + `mtr_hops` hypertables (`20260228090000`), `mtr_{settings,policies,dispatch_windows,bulk_job_targets}`.

### 5.4 Service status / monitoring

- `service_status` (`create_timeseries_tables.exs`) — **hypertable** `(timestamp, gateway_id, service_name)`, `available` bool, message/details, partition. Core availability time-series.
- `service_checks` (`:1359`) — check definitions: check_type, target, port, intervals/timeouts/retries, config, thresholds, last_check_at/result, consecutive_failures, `agent_uid`, `device_uid`, `schedule_id`.
- `checkers` (`:652`) — checker instances (type, config, status, target_filter, agent_uid).
- `poll_jobs` (`:250`) / `polling_schedules` (`:674`) — polling scheduler.
- `service_state`, `device_agent_availability`, `availability_source_profiles` — current state / availability sourcing.

### 5.5 Events / anomalies / alerts

- `events` (`create_timeseries_tables.exs`) — **hypertable** on `event_timestamp`, CloudEvents-style: specversion, id, source, type, subject, host, level, severity, short_message, raw_data. PK `(event_timestamp, id)`.
- `ocsf_events` (`20260203120000`) — **hypertable** on `time`, 14-day retention. Primary security/log-derived event store (from log promotion): class/category/type_uid, activity, severity, message, status, metadata/observables jsonb, trace/span ids, actor/device/src/dst endpoint jsonb, raw_data.
- `event_rules`, `health_events` (`:231`, state-transition history).
- `alerts` (`:190`) — stateful alerting: title/description/severity/status, source_type/id, `service_check_id`, `device_uid`/`agent_uid`, event_id, metric_name/value, threshold, comparison, triggered/ack/resolved/escalated timestamps, escalation_level, suppressed_until, tags.
- `stateful_alert_rules` (`:1553`) + `stateful_alert_rule_templates` (`:602`) + `_states` (`:1280`) + `_histories` (`20260406133000`).
- `log_promotion_rules` / `zen_rules` (+ templates) — JDM/ZEN decision rules that generate events.
- Anomaly: `anomaly_detection_configs`, `anomaly_episodes` (`20260704053000` — episode_uid PK, finding/device/series keys, detector, status open/cleared/stale, severity 0-5, effect_size, peak_score, opened/last_seen/cleared_at, occurrence/reopen counts), `seasonal_disposition_states` (`20260619113000`), `capacity_forecast_configs`.

### 5.6 Logs

- `logs` (`create_timeseries_tables.exs`) — **hypertable** on `timestamp`, OTel logs: id uuid, trace/span_id, severity_text/number, body, service_name/version/instance, scope, attributes, resource_attributes. PK `(timestamp, id)`.

### 5.7 Users / auth / config

- `ng_users` (`:632`) — email citext (unique), hashed_password, display_name, role (default viewer), confirmed_at, local_login_enabled.
- `user_tokens` (`:843`), `api_tokens` (`:1052`), `token_revocations`, `cli_sessions`, `oauth_clients`, `device_authorizations`, `user_auth_events`, `user_groups`/memberships, `role_profiles`, `auth_settings`/`authorization_settings`, `security_event`/`auth_lockout`.
- Agent config: `agent_config_{templates,instances,versions}`, `agent_commands`, `agent_releases`/`_targets`/`_rollouts`.
- Credentials/secrets (with `*_versions` audit): `network_credential_secrets`/`_rules`, `credential_secret_providers`, `credential_broker_grants`, `device_snmp_credentials`, `mapper_snmp_credentials`, `nats_credentials`, `collector_packages`, `edge_onboarding_packages`/`_events`, `nats_leaf_servers`, `edge_sites`.
- SNMP: `snmp_profiles`, `snmp_targets`, `snmp_oid_configs`, `snmp_oid_templates`.
- Sweep: `sweep_profiles`, `sweep_groups`, `sweep_group_executions` (+`_versions`), `sweep_host_results` (`:403`).
- Sysmon: `sysmon_profiles` (`:160`), `dusk_profiles`.
- Integrations/plugins/dashboards/infra: `integration_sources`, `plugins`/`plugin_*`, `addon_*`, `dashboard_*`/`authored_dashboards`, `ansible_*`, `proxmox_*`, `virtualization_*`, `camera_*`, `wifi_*`, `fieldsurvey_*` (RF spatial survey), `endpoint_inventory_*` (SBOM), `trivy_reports`/`trivy_findings`, `threat_intel_*`, `vulnerability_*`, `ip_*_cache` (geo/rdns enrichment).
- Jobs: Oban tables (`ensure_oban_platform_tables.exs`, upgraded v14 `20260710203000`), `ng_job_schedules`, `producer_schedules`, `observability_watermarks`.

### 5.8 Materialized views & continuous aggregates

**Plain MV → table:** `otel_trace_summaries` — created as MV (`20260120150000`), converted to a regular table (`20260210120000`) because full-rescan REFRESH timed out. 7-day rolling trace summaries.

**TimescaleDB continuous aggregates** (`WITH (timescaledb.continuous)` + refresh policy):

| Continuous aggregate | Source | Rolls up |
|---|---|---|
| `ocsf_events_hourly_stats` | `ocsf_events` | hourly event counts by class/severity |
| `ocsf_network_activity_5m_traffic` | `ocsf_network_activity` | 5-min flow traffic (sampling-adjusted) |
| `ocsf_network_activity_hourly_{proto,talkers,ports,listeners,conversations}` | ″ | hourly protocol/talkers/ports/listeners/conversations |
| `flow_traffic_1h` / `flow_traffic_1d` | ″ (hierarchical) | 1-hour / 1-day flow rollups |
| `cpu_metrics_hourly` / `memory_metrics_hourly` / `disk_metrics_hourly` / `process_metrics_hourly` / `timeseries_metrics_hourly` | respective hypertables | hourly avg/max |
| `timeseries_metrics_interface_hourly` | `timeseries_metrics` | hourly interface counters → rates (delta/duration) |
| `traces_stats_5m` | `otel_traces` | 5-min RED span stats |
| `spans_red_1h` | `otel_traces` | hourly RED per span/service |
| `otel_metrics_hourly_stats` | `otel_metrics` | hourly service RED stats (replaced old plain table) |
| `logs_severity_stats_5m` | `logs` | 5-min log counts by severity |
| `endpoint_inventory_*_counts_hourly` | endpoint inventory history | hourly SBOM/CVE counts |

These are the rollups SRQL routes metric/stats queries to.

### 5.9 Graph (Apache AGE)

Single AGE graph **`platform_graph`** (migration `20260204090000_use_platform_age_graph`, superseding
the original `serviceradar` graph from `20260119090000`), search_path `ag_catalog,platform,...`,
property indexes (`20260622210000`, targeting `platform_graph`). The SRQL default and all causal-engine
Cypher queries must use `platform_graph`. Vertex labels **Device / Collector / Service / Interface**; edges express
device↔collector membership, neighbor/peer interface adjacency, and service relations. It is a
**projection** over the relational topology tables (`mapper_topology_links`, `runtime_topology_links`),
not a primary store — `runtime_topology_projection_meta` tracks freshness. SRQL's `graph_cypher` entity
queries it read-only.

---

## 6. Three things to internalize

1. **NATS is the telemetry bus; ERTS is the coordination bus.** Bulk data (metrics/logs/events/flows)
   rides JetStream into core→CNPG. Live status/config coordination rides the Erlang mTLS cluster
   (gateway↔core↔web-ng) via PubSub/RPC. The UI gets history from CNPG and live changes from PubSub.
2. **Core is the sole DB writer for telemetry; web-ng is a reader.** Everything funnels through
   `event_writer`'s Broadway pipeline.
3. **SRQL is embedded, not a service, on the UI path.** The Rust translator runs as an in-process NIF
   inside web-ng; the port-8480 HTTP service exists mainly for the Go core.

---

## Notes / conventions

- Most app tables use `uuid` PKs (`gen_random_uuid()`); SNMP/target tables use time-ordered
  `uuid_generate_v7()`; a few `bigserial` (`device_identifiers`) or natural-key text PKs
  (`ocsf_devices.uid`, `ocsf_agents.uid`, `gateways.gateway_id`).
- Hypertable creation is defensive: `maybe_create_hypertable` no-ops if TimescaleDB is absent, so the
  same schema runs on plain Postgres (tables stay regular).
- Timestamps are `utc_datetime_usec` in Ecto-defined tables, `TIMESTAMPTZ` in raw-SQL time-series tables.
