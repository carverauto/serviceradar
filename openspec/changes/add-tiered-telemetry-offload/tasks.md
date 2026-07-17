# Tasks — add-tiered-telemetry-offload

## 0. Decision-gate spikes (complete before implementation starts; results recorded in design.md)
- [x] 0.1 Spike: pg_duckdb view wrapping `postgres_scan ∪ read_parquet` — verify predicate pushdown into BOTH branches, that SRQL-shaped SQL (unqualified names, `set_config` statement_timeout/plan_cache_mode) executes against such views, AND that the primary connection works via a postgres-type SECRET/ATTACH (no DSN literals in view DDL — the D8 rotation story depends on this)
- [x] 0.2 Spike: DuckDB postgres scanner against a TimescaleDB hypertable parent — measure pushdown/scan behavior; validate the `_timescaledb_internal` chunk-relation fallback; pin `pg_connection_limit`
- [x] 0.3 Spike: PG `statement_timeout` cancellation of in-flight DuckDB executions on the head; define client-side cancellation fallback if needed
- [x] 0.4 Spike: `COPY (SELECT … FROM postgres_scan(…)) TO 's3://…' (FORMAT parquet)` stability at chunk scale (pg_duckdb #1056 family); document crash/retry envelope
- [x] 0.5 Spike: object-store compatibility matrix (Linode Object Storage; MinIO as the reference path-style store, doubling as the local-dev/CI target) — multipart, ListObjectsV2 paging, `url_style`, checksum env quirks; `AbortIncompleteMultipartUpload` lifecycle support
- [x] 0.6 Spike: ordering parity — DuckDB `default_null_order`/collation vs PG on tenant cluster locale; confirm explicit NULLS + tiebreaker strategy closes the gap
- [x] 0.7 Record go/no-go + fallbacks in design.md; re-validate proposal if any spike forces a design change

## 1. M1 — Cold schema registry + analytics head (infrastructure)
- [x] 1.1 Implement the cold schema registry in core-elx (v1 tables: logs, otel_traces, otel_metrics, otel_metric_points, timeseries_metrics, ocsf_events, ocsf_network_activity): export column lists + canonical casts, partition layout, per-table hot/cold windows, update-prone flags
- [x] 1.2 CI drift check: migration altering a registry table's columns fails unless the registry entry is updated in the same change
- [x] 1.3 Build `serviceradar-cnpg-analytics` Bazel image (CNPG PG18 base + pg_duckdb + libstdc++6; no TimescaleDB/AGE/PostGIS); publish via existing push targets
- [x] 1.4 CI boot-smoke test for the analytics image (start PG, CREATE EXTENSION pg_duckdb, read_parquet round-trip) gating digest pin bumps
- [x] 1.5 Helm: analytics-head component (CNPG Cluster CRD, default disabled) — GUC posture (duckdb.postgres_role, max_memory, threads, disabled_filesystems, temp on dedicated ephemeral volume with max_temp_directory_size), resource requests derived from pool_size × max_memory formula; chart-owned posture defaults with named values keys for externally projected facts (cold-tier credentials secret name, sizing profile)
- [x] 1.6 Helm: NetworkPolicies (head→primary :5432; head→object-store egress; core/web-ng→head); dedicated read-only export role on the primary with role-level timeouts + keepalives (migration)
- [ ] 1.7 core-elx secrets reconciler: idempotently (re)assert DuckDB S3 SECRET and postgres-type SECRET on the head from mounted K8s secrets; rotation integration test + runbook
- [x] 1.8 Local dev: opt-in docker-compose profile with MinIO + a local analytics-head container (analytics image) + cold-tier env wiring, so the full export→verify→drop→query-back loop runs against the compose CNPG without any cloud object storage

## 2. M1 — Export pipeline + gated retention
- [x] 2.1 Manifest table `platform.cold_chunk_exports` on the primary (migration) + Ash resource (migrate? false)
- [x] 2.2 ColdTierExporter (Oban): chunk enumeration (older than now − export_lag), COPY-through-head export, count+checksum verification, manifest commit, deterministic object keys (idempotent re-export), paced backfill mode (one chunk at a time, off-peak, xmin-age abort)
- [x] 2.3 Frontier bookkeeping: contiguous-verification advance; head boundary `B` write + ack ordering (drop point ≤ B ≤ F invariant); overlap-zone daily refresh (count/aggregate drift re-export); update-prone tables re-export at drop time
- [x] 2.4 Shared retention-policy fence helper consumed by DataRetentionWorker AND all retention-policy migrations; cold-enabled ⇒ remove in-DB policies for registry tables; exporter asserts no policy reappears (alert); CI check that registry-table retention DDL goes through the helper
- [x] 2.5 Drop gate in DataRetentionWorker: chunk entirely below B + manifest verified + drop-time re-verification (re-export on mismatch) before drop_chunks
- [x] 2.6 Pressure relief: headroom budget computation + escalating alerts; poison-chunk quarantine (N failures ⇒ skip + alert, blocks frontier); operator-acknowledged emergency drop at hard disk watermark; two-phase disable (drain-or-waive, then re-arm policies)
- [x] 2.7 Cold pruning: per-table cold windows; objects-before-manifest delete order; manifest↔bucket reconciliation sweep; S3 client dependency in core-elx
- [x] 2.8 CAGG window alignment migration (ocsf_events_hourly_stats, traces_stats_5m, flow 5m/proto/talkers/ports) to match plan-facing lookback ambitions
- [x] 2.10 Introduce `SERVICERADAR_TIMESERIES_METRICS_RETENTION_DAYS` consumed by the retention path, decoupled from the shared `:raw_metrics_retention_days` key (which sysmon split tables keep) — `timeseries_metrics` currently has NO per-table env var and projecting one would otherwise be silently ignored
- [x] 2.11 CAGG refresh-window clamp: migration clamping every shipped refresh policy inside its raw source's retention (fixes the pre-existing 32d-over-7d wipe bug, verified on TS 2.24); data-driven `cagg_refresh_hazards` alert in DataRetentionWorker; `stale_invalidations` loaded-gun alert in the exporter
- [x] 2.9 Break-glass export runbook (poison chunks; head-down manual export path)

## 3. M1 — Storage/retention telemetry
- [x] 3.1 Always-on gauges: per-registry-table hot bytes, ingest-bytes/day EMA, non-telemetry baseline bytes (web-ng /metrics + authenticated JSON admin endpoint)
- [x] 3.2 Cold-tier gauges: cold bytes, frontier lag, held/quarantined chunk counts, headroom consumption, measured oldest-available per table
- [ ] 3.3 Alert wiring for headroom/quarantine/frontier-stall into the existing notification path

## 4. M2 — Transparent cold queries (SRQL)
- [ ] 4.1 Extend NIF translate contract: cold-tier config input (enabled entities, per-table B/hot windows, cold caps), route metadata output; Elixir callers source config from runtime env; background SRQLRunner pinned hot-only via mode
- [ ] 4.2 rust/srql cold routing: raw-shape eligibility, resolved-window vs hot-window comparison, lookback cap lift for cold-eligible raw queries, no-time-filter ⇒ hot-only unless absolute hint provided
- [ ] 4.3 Cold SQL dialect: partition predicates from resolved window; unique tiebreaker + explicit NULLS on every ORDER BY; registry-driven construct translations; fail-closed typed error for untranslatable shapes
- [ ] 4.4 Cursor v3 embedding resolved absolute window; lower cold max-offset cap
- [ ] 4.5 web-ng ColdRepo (pool 2–4, 60s timeout) + route-based execution in srql.ex; fail-soft to hot-only with truncation notice component (generalize :spans_expired pattern)
- [ ] 4.6 Analytics-head view generation from the registry (platform.<table> stitched views; same-name postgres-scanner views for dimension tables); regeneration on schema migration + drift check
- [ ] 4.7 Trace detail absolute-time hint from trace summaries; :spans_expired path reads cold
- [ ] 4.8 Golden hot/cold parity suite: same SRQL both paths, row-level + Arrow-layer assertions (query_arrow frames), type-fidelity cases (json text, timestamptz UTC, numeric bounds, NULL ordering, ILIKE/regex); runs in CI against fixture data on a MinIO-backed bucket (same compose profile as task 1.8)
- [ ] 4.9 Per-entity-family rollout flags (logs → traces → flows → events → metric points)

## 5. Supersession + validation
- [x] 5.1 Withdraw `add-delta-metrics-lakehouse` and `add-rust-tdengine-analytics` change dirs; remove `rust/metrics-delta-writer` skeleton; carry the write-throughput decision-gate forward as the documented trigger for a future ingest-side writer committing through the manifest contract
- [ ] 5.2 `openspec validate add-tiered-telemetry-offload --strict` passes
- [ ] 5.3 Canary deployment: M1 enabled on one cold-configured environment; observe one full export→verify→drop cycle + one simulated stall (pressure-relief drill) before fleet rollout
- [ ] 5.4 Docs: consistency contract (overlap-zone eventual consistency, staleness bounds), operator runbooks (rotation, drain/disable, emergency drop)
