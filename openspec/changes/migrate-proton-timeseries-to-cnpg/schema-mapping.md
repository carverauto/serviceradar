# Proton → CNPG schema mapping

This document fulfills task **1.1** by enumerating every Proton stream/table that `pkg/db` and the registry rely on today and describing how each structure maps to the CNPG + Timescale schema introduced in `pkg/db/cnpg/migrations/00000000000001_timescale_schema.up.sql`. Each row lists the current Proton TTL window (taken directly from `pkg/db/migrations/*.sql`), the CNPG target object, its retention policy, and the implementation status so we can track any gaps that still need follow-up migrations.

## Legend

- **Existing** – implemented in `00000000000001_timescale_schema.up.sql`.
- **Planned** – needs an additional CNPG migration before we can cut over writes.
- **Merged/Dropped** – Proton table will be retired and the responsibility moves into another CNPG structure.
- **Deferred** – explicitly out of scope for this change (see proposal scope/out-of-scope); stays on Proton until the follow-on spec lands.

## Telemetry & sysmon streams (3-day TTL in Proton)

| Proton object | Proton TTL | CNPG target | CNPG retention | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| `timeseries_metrics` | 3 days (`timestamp`/`_tp_time`) | `timeseries_metrics` Timescale hypertable (`timestamp`) | Timescale retention policy: 3 days | Existing | Field-for-field port; JSON `tags` and `metadata` become JSONB, plus device/time index (`idx_timeseries_metrics_device_time`). |
| `cpu_metrics` | 3 days | `cpu_metrics` hypertable (`timestamp`) | 3 days | Existing | Includes new columns from migration `00000000000002` (label, cluster) and device/time index. |
| `cpu_cluster_metrics` | 3 days | `cpu_cluster_metrics` hypertable (`timestamp`) | 3 days | Existing | Mirrors Proton schema and keeps hourly partitioning via Timescale. |
| `disk_metrics` | 3 days | `disk_metrics` hypertable (`timestamp`) | 3 days | Existing | Same schema; JSON-less so simple Timescale table. |
| `memory_metrics` | 3 days | `memory_metrics` hypertable (`timestamp`) | 3 days | Existing | Same as Proton. |
| `process_metrics` | 3 days | `process_metrics` hypertable (`timestamp`) | 3 days | Existing | Gains `created_at` column; retains host/poller/device indexes. |
| `netflow_metrics` | 3 days | `netflow_metrics` hypertable (`timestamp`) | 3 days | Existing | Schema normalized (JSONB metadata) plus retention policy. |
| `rperf_metrics` | 3 days | `rperf_metrics` hypertable (`timestamp`) | 3 days | Existing | `00000000000002_events_rperf_users.up.sql` provisions the table + retention so the Rust rperf writers can dual-write. |
| `device_metrics_summary` (MV) | 3 days | Timescale continuous aggregate (e.g., `device_metrics_summary_cagg`) fed from CPU/disk/memory hypertables | 3 days | Existing | `00000000000003_device_metrics_summary_cagg.up.sql` implements a 5-minute continuous aggregate that mirrors the Proton MV semantics. |
| `service_status` | 3 days | `service_status` hypertable (`timestamp`) | 3 days | Existing | All service heartbeat writes/readers move here via pgx; `created_at` is populated automatically. |
| `service_statuses` | 3 days | Fold into `service_status` hypertable | 3 days | Merged/Dropped | Proton kept both `service_status` and `service_statuses`; CNPG keeps a single hypertable and the dedup logic happens in SQL instead of two streams. |
| `services` | 3 days | `services` hypertable (`timestamp`) | 30 days | Existing | We intentionally extend retention to 30 days to ease config auditing; Timescale handles TTL. |

## Discovery, sweep, and topology streams

| Proton object | Proton TTL | CNPG target | CNPG retention | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| `sweep_host_states` | 3 days (`last_sweep_time`) | `sweep_host_states` hypertable (`last_sweep_time`) | 3 days | Existing | Hypertable primary key `(host_ip, poller_id, partition)` matches Proton `versioned_kv` semantics. |
| `device_updates` | 3 days (`timestamp`) | `device_updates` hypertable (`observed_at`) | 3 days | Existing | Column rename clarifies semantics; used for deterministic merge inside `pkg/db/cnpg_unified_devices`. |
| `discovered_interfaces` | 3 days | `discovered_interfaces` hypertable (`timestamp`) | 3 days | Existing | Arrays become typed columns (`TEXT[]`), metadata becomes JSONB. |
| `topology_discovery_events` | 3 days | `topology_discovery_events` hypertable (`timestamp`) | 3 days | Existing | One-to-one port; still the backing store for topology replay APIs. |

## Device inventory & registry tables

| Proton object | Proton TTL | CNPG target | CNPG retention | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| `unified_devices` | 3 days (should have been 30) | `unified_devices` relational table (PK `device_id`) | No TTL (managed by `last_seen` pruning jobs) | Existing | CNPG stores canonical rows directly, removing Proton `versioned_kv` + MV pipeline. |
| `unified_devices_registry` | 3 days | Covered by `unified_devices` + new registry write path | N/A | Merged/Dropped | Proton dual-stream is replaced with a single table plus explicit merge logic in `pkg/registry`. |
| `pollers` | 3 days TTL around `last_seen` | `pollers` relational table | No TTL | Existing | CNPG keeps full registry metadata plus counters, matching `pkg/db/pollers.go` expectations. |
| `agents` | No TTL | `agents` relational table | No TTL | Existing | Same column set as Proton stream; indexes on `poller_id`. |
| `checkers` | No TTL | `checkers` relational table | No TTL | Existing | Same schema; we retain `poller_id` column for lookups. |
| `service_registration_events` | 90 days | `service_registration_events` hypertable (`timestamp`) | 90 days | Existing | The append-only audit log retains its TTL via Timescale retention. |
| `poller_history` | 7 days | `poller_history` hypertable (`timestamp`) | 7 days | Existing | API consumers keep the same dataset while moving to pgx. |
| `poller_statuses` | 7 days | Use `poller_history` for status deltas; add SQL view if callers need snapshots | 7 days | Merged/Dropped | No Go code queries `poller_statuses`; we stop writing it once dual-writes to CNPG begin. |
| `service_status`/`service_statuses` | 3 days | `service_status` hypertable | 3 days | Existing/Merged | Covered above; registry consumers will hit pgx. |
| `services` | 3 days | `services` hypertable | 30 days | Existing | Same as telemetry table above; tracked here for registry completeness. |
| `events` | 3 days (`event_timestamp`) | `events` hypertable (`event_timestamp`) | 3 days | Existing | Implemented in `00000000000002_events_rperf_users.up.sql`; CNPG now stores CloudEvents with 3-day retention so the db-event-writer can dual-write. |
| `users` | No TTL | `users` relational table (PK `id`, unique `email`) | No TTL | Existing | `00000000000002_events_rperf_users.up.sql` adds the auth/users table with lowercased unique indexes to match Proton behavior. |

## Edge onboarding & capabilities

| Proton object | Proton TTL | CNPG target | CNPG retention | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| `edge_onboarding_packages` | No TTL (`versioned_kv`) | `edge_onboarding_packages` relational table | No TTL | Existing | Exact schema parity; row versioning handled with `updated_at` column. |
| `edge_onboarding_events` | None (append-only MergeTree) | `edge_onboarding_events` hypertable (`event_time`) | 365 days | Existing | Timescale handles long-lived audit retention without manual TTL jobs. |
| `device_capabilities` | 90 days | `device_capabilities` hypertable (`last_checked`) | 90 days | Existing | Append-only audit table plus indexes on `(device_id, capability, service_id)`. |
| `device_capability_registry` | No TTL | `device_capability_registry` relational table | No TTL | Existing | Maintains “latest state” rows; updated through pgx upserts. |

## Observability (SRQL-dependent) streams – deferred

| Proton object | Proton TTL | CNPG target | CNPG retention | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| `logs` | 3 days | `logs` hypertable | 3 days | Existing | Added in `00000000000004_otel_observability.up.sql`; `cmd/consumers/db-event-writer` now writes OTEL logs via pgx. |
| `otel_metrics` | 3 days | `otel_metrics` hypertable | 3 days | Existing | Same migration as above; fed exclusively by the CNPG-backed db-event-writer. |
| `otel_traces` | 3 days | `otel_traces` hypertable | 3 days | Existing | Hypertable + ingestion wiring landed with the observability migration so gRPC traces bypass Proton. |
| `otel_trace_summaries` | 3 days | `otel_trace_summaries` hypertable + views | 3 days | Deferred | Dependent on SRQL translator plans. |
| `otel_spans_enriched` | 3 days | `otel_spans_enriched` hypertable + pipeline | 3 days | Deferred | Remains on Proton until SRQL is ported. |
| `ocsf_device_inventory` | 30 days | Timescale table (one row per inventory event) | 30 days | Deferred | OCSF exports are not part of the timeseries-storage capability; Proton implementation continues until the OCSF alignment roadmap item is picked up. |
| `ocsf_network_activity` | 3 days | Timescale hypertable | 3 days | Deferred | Same reasoning as above. |
| `ocsf_user_inventory` | 90 days | Timescale table | 90 days | Deferred | 90-day retention stays Proton-only until we spec Postgres views. |
| `ocsf_system_activity` | 7 days | Timescale hypertable | 7 days | Deferred | Blocked on OCSF exporter work. |
| `ocsf_devices_current` | 90 days | Relational table | 90 days | Deferred | Derived from inventory events; will move once OCSF spec exists. |
| `ocsf_users_current` | 90 days | Relational table | 90 days | Deferred | Same as devices_current. |
| `ocsf_vulnerabilities_current` | 365 days | Relational table | 365 days | Deferred | Requires dedicated retention + compliance review. |
| `ocsf_services_current` | 90 days | Relational table | 90 days | Deferred | Covered by OCSF spec later. |
| `ocsf_observable_index` | 30 days | Hypertable/table | 30 days | Deferred | Observability search indexes stay in Proton until Postgres search plan exists. |
| `ocsf_observable_statistics` | 90 days | Hypertable/table | 90 days | Deferred | Same as above. |
| `ocsf_entity_relationships` | 30 days | Hypertable/table | 30 days | Deferred | Depends on graph/AGE rollout; intentionally out of scope. |
| `ocsf_search_performance` | 7 days | Hypertable/table | 7 days | Deferred | Remains Proton-backed; will be moved with analytics observability work. |

## What’s next

- Wire the Go writers/readers (metrics, events, auth) to the new CNPG tables so we can enable dual writes and parity checks.
- Keep Proton-only observability/OCSF datasets documented here so future specs can reference their TTL expectations.
- Update `pkg/registry` implementation work to rely on the relational tables described above (Tasks 2.2–2.4).
