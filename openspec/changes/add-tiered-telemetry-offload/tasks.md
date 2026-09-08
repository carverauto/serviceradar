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
- [x] 1.7 core-elx secrets reconciler: idempotently (re)assert DuckDB S3 SECRET and postgres-type SECRET on the head from mounted K8s secrets; rotation integration test + runbook
- [x] 1.8 Local dev: opt-in docker-compose profile with MinIO + a local analytics-head container (analytics image) + cold-tier env wiring, so the full export→verify→drop→query-back loop runs against the compose CNPG without any cloud object storage

## 2. M1 — Export pipeline + gated retention
- [x] 2.1 Manifest table `platform.cold_chunk_exports` on the primary (migration) + Ash resource (migrate? false)
- [~] 2.2 ColdTierExporter (Oban) — PARTIAL: chunk enumeration, COPY-through-head export, count+checksum verification, manifest commit, deterministic object keys (idempotent re-export), and a global per-run chunk budget are done. STILL MISSING (review F12): off-peak admission, backend_xmin age monitoring, and an overrun watchdog. NOTE: the amended design forbids cancelling an in-flight COPY, so the safe form is watchdog ALERTING plus admission/pacing — never cancellation
- [x] 2.3 Frontier bookkeeping: contiguous-verification advance; head boundary `B` write + ack ordering (drop point ≤ B ≤ F invariant); overlap-zone daily refresh (count/aggregate drift re-export); update-prone tables re-export at drop time
- [x] 2.4 Shared retention-policy fence helper consumed by DataRetentionWorker AND all retention-policy migrations; cold-enabled ⇒ remove in-DB policies for registry tables; exporter asserts no policy reappears (alert); CI check that registry-table retention DDL goes through the helper
- [x] 2.5 Drop gate in DataRetentionWorker: chunk entirely below B + manifest verified + drop-time re-verification (re-export on mismatch) before drop_chunks
- [~] 2.6 Pressure relief — PARTIAL: escalating 70/85/95% alerts, poison-chunk quarantine, operator-acknowledged emergency drop, and two-phase disable are done. STILL MISSING (review F35): the specified headroom BUDGET (provisioned volume + p95 closed-chunk ingest -> headroom_days), and (review F34) neither Helm nor Compose renders the volume-capacity env the monitor reads, so usage_pct is nil and the alerts cannot fire in a shipped deployment
- [x] 2.7 Cold pruning: per-table cold windows; objects-before-manifest delete order; manifest↔bucket reconciliation sweep; S3 client dependency in core-elx
- [x] 2.8 CAGG window alignment (ocsf_events_hourly_stats, traces_stats_5m, flow proto/talkers/ports) to match plan-facing lookback ambitions — applied by `RetentionFence.reconcile_cagg_windows/1` from the retention worker while the cold tier is enabled, NOT by a migration: widening rollup retention costs storage on every deployment and only earns it once raw history moves to cold objects. Widen-only; disabling never shrinks a window back, because that would delete materialized history
- [x] 2.10 Introduce `SERVICERADAR_TIMESERIES_METRICS_RETENTION_DAYS` consumed by the retention path, decoupled from the shared `:raw_metrics_retention_days` key (which sysmon split tables keep) — `timeseries_metrics` currently has NO per-table env var and projecting one would otherwise be silently ignored
- [x] 2.11 CAGG refresh-window clamp: migration clamping every shipped refresh policy inside its raw source's retention (fixes the pre-existing 32d-over-7d wipe bug, verified on TS 2.24); data-driven `cagg_refresh_hazards` alert in DataRetentionWorker; `stale_invalidations` loaded-gun alert in the exporter
- [x] 2.9 Break-glass export runbook (poison chunks; head-down manual export path)

## 3. M1 — Storage/retention telemetry
- [~] 3.1 Always-on gauges — PARTIAL: per-table hot bytes, ingest-bytes/day (from closed-chunk sizes) and the non-telemetry baseline are on web-ng /metrics. STILL MISSING (review F36): the authenticated JSON admin endpoint
- [~] 3.2 Cold-tier gauges — PARTIAL: cold bytes/rows, frontier lag, held/quarantined counts and measured oldest-available are emitted. STILL MISSING: headroom-consumption gauge (F35); held_chunks counts manifest rows rather than chunks older than hot retention (F38)
- [x] 3.3 Alert wiring for headroom/quarantine/frontier-stall into the existing notification path

## 4. M2 — Transparent cold queries (SRQL)
- [ ] 4.1 Extend NIF translate contract: cold-tier config input (enabled entities, per-table B/hot windows, cold caps), route metadata output; Elixir callers source config from runtime env; background SRQLRunner pinned hot-only via mode
- [ ] 4.2 rust/srql cold routing: raw-shape eligibility, resolved-window vs hot-window comparison, lookback cap lift for cold-eligible raw queries, no-time-filter ⇒ hot-only unless absolute hint provided
- [ ] 4.3 Cold SQL dialect: partition predicates from resolved window; unique tiebreaker + explicit NULLS on every ORDER BY; registry-driven construct translations; fail-closed typed error for untranslatable shapes
- [ ] 4.4 Cursor v3 embedding resolved absolute window; lower cold max-offset cap
- [ ] 4.5 web-ng ColdRepo (pool 2–4, 60s timeout) + route-based execution in srql.ex; fail-soft to hot-only with truncation notice component (generalize :spans_expired pattern)
- [~] 4.6 Analytics-head view generation from the registry — PARTIAL: stitched platform.<table> views over read_parquet UNION postgres_fdw are done and proven. STILL MISSING (review F31): same-name head objects for dimension tables (ocsf_devices, device_alias_states, netflow_exporter_cache) that flow/log/event filters join, and FDW schema reconciliation (IMPORT FOREIGN SCHEMA only runs when absent, so foreign tables never gain columns after a primary migration)
- [ ] 4.7 Trace detail absolute-time hint from trace summaries; :spans_expired path reads cold
- [ ] 4.8 Golden hot/cold parity suite: same SRQL both paths, row-level + Arrow-layer assertions (query_arrow frames), type-fidelity cases (json text, timestamptz UTC, numeric bounds, NULL ordering, ILIKE/regex); runs in CI against fixture data on a MinIO-backed bucket (same compose profile as task 1.8)
- [ ] 4.9 Per-entity-family rollout flags (logs → traces → flows → events → metric points)

## 5. Supersession + validation
- [x] 5.1 Withdraw `add-delta-metrics-lakehouse` and `add-rust-tdengine-analytics` change dirs; remove `rust/metrics-delta-writer` skeleton; carry the write-throughput decision-gate forward as the documented trigger for a future ingest-side writer committing through the manifest contract
- [x] 5.2 `openspec validate add-tiered-telemetry-offload --strict` passes
- [ ] 5.3 Canary deployment: M1 enabled on one cold-configured environment; observe one full export→verify→drop cycle + one simulated stall (pressure-relief drill) before fleet rollout
- [x] 5.4 Docs: consistency contract (overlap-zone eventual consistency, staleness bounds), operator runbooks (rotation, drain/disable, emergency drop)

## 6. Review findings (PR #4595 @ 5624059ba9) — remaining

Fixed in-branch already: F01 (drop-time re-verification failed open on SQL
error), F05 (head boundary could regress while the primary's could not; one
effective monotonic B now builds the view and is acked on both sides), F06
(missing archive objects stayed `verified` and could authorize dropping the
source — now demoted to `pending` before alerting), F08 (the CAGG repair
migrations swallowed every error and could record as applied while the
hazard stayed live), F14 (absent cold windows materialized a destructive
365-day default; absent now means no expiry pruning, per D9), F27 (routing
compared the window to the stitching seam B instead of the hot cutoff,
breaking the byte-identical hot-path invariant), F28 (`rollup_stats` was
classified as a raw shape and could cold-route a CAGG-reading query), F33
(rustfmt), F37 (`cold_bytes` was never populated), F39 (telemetry test
asserted 9 gauges while 10 ship).

### 6.1 Retention/exporter correctness (P1)
- [x] 6.1.1 F02: FIXED — a per-table transaction-scoped advisory lock (`RetentionFence.with_table_lock/3`, namespace `0x0C01D`) now brackets BOTH the drop gate (`safe_drop_point` read + `drop_chunks` in one transaction) AND every exporter manifest status flip (pending on (re-)export, verified, failure, quarantine), so a chunk can never transition verified<->pending between the gate's contiguous-verified and drift queries. The lock is held only for the fast status writes, never across the non-preemptible COPY (which runs between the pending and verified flips, so a concurrent drop simply sees `pending` and holds). Proven against the live spike DB: a second session's `pg_try_advisory_xact_lock` returns false while the lock is held and true after release; an Ash write executes and persists inside the locked transaction.
- [x] 6.1.2 F03: FIXED — `drift_clamp` now adds a freshness gate for update-prone tables (`m.verified_at < now() - @update_prone_freshness_hours`, 6h): count-drift can't see in-place upserts, so any update-prone verified chunk not re-exported within the window is held. The exporter's pre-drop re-export throttle is tightened to 2h (< the 6h gate) so a legitimately-near-drop chunk stays fresh enough to pass rather than being held indefinitely. This bounds the stale-generation exposure to the re-export cadence instead of "any time since first export". Non-update-prone tables are unaffected (no freshness clause). Both paths executed against the live spike DB.
- [~] 6.1.3 F04: PARTIALLY FIXED — exports now land on a `_staging/` key, verification runs against THAT object, and only a verified object is server-side copied onto the published key (writes are atomic per key), while readers glob `date=*/` only. Proven: a bogus staging object exists on the bucket yet the stitched view is unchanged. STILL OPEN: readers use a glob rather than the verified manifest key list, so a tombstoned-but-not-yet-deleted object stays visible for the (minutes-long) window between tombstone and delete
- [x] 6.1.4 F07: FIXED — the exporter now actively re-asserts the fence at the START of every run (`enforce_fence`): it removes any in-DB retention policy on every fenced table via `reconcile_policy`, shrinking the post-activation / post-migration window during which the TimescaleDB background worker could drop un-exported chunks from ~24h (nightly worker) to at most one export interval (hourly). Error handling no longer lies: `run_policy_sql` propagates `{:error, {:policy_ddl_failed, ...}}` instead of swallowing to `:ok` (a failed removal leaves the worker armed), and `policy_violations/1` returns `{:ok, list} | {:error, reason}` so a failed check reads as "unconfirmed", not "clean" — both the exporter and the fence health check treat that as a violation. Proven on the live spike DB: an armed policy is removed (1->0, returns :ok) and re-armed policies are cleared by the sweep.
- [ ] 6.1.5 F11: run a daily refresh across the FULL overlap [B, hot-drop horizon) — the current 26h pre-drop window means a late row in a 3-day-old chunk stays absent from cold until ~day 29 for 30-day logs, contradicting the documented <=24h bound
- [ ] 6.1.6 F13: round-robin the run budget across tables; a backlog in the first registry table currently starves every later table

### 6.2 Activation/config integrity (P1)
- [x] 6.2.1 F09: FIXED — one activation state (Config.state/0: disabled|misconfigured|enabled); the fence, exporter and pruner all key off Config.enabled?/0. Misconfigured does NOT fence (normal retention proceeds so the primary can't fill behind a dead exporter) and the retention worker alerts. Unit + live verified
- [x] 6.2.2 F10: FIXED — the exporter's head-setup failure branch now records an unhealthy export check (Health.record_head_failure/3) and computes primary pressure, instead of returning healthy
- [ ] 6.2.3 F15: build the Oban crontab from the validated state so an unconfigured install schedules no cold jobs at all

### 6.3 Deployment/security (P1 unless noted)
- [x] 6.3.1 F16: FIXED via CNPG's supported postgresUID/postgresGID (the reviewer's sanctioned alternative to rebasing the image). Reproduced the failure (`initdb: could not look up effective user ID 26`) and verified UID 999 boots; chart now sets postgresUID/postgresGID: 999 and the smoke test runs under the production UID, so this class fails in CI rather than in a canary. FOLLOW-UP (optional): rebasing pg_duckdb onto the CNPG base would let the head run at UID 26 like every other cluster — worth doing if fleet policy requires a uniform UID
- [x] 6.3.2 F17: FIXED — the head renders image.registryPullSecret (overridable per-head)
- [ ] 6.3.3 F18: TLS on both hops — core->head has no TLS/CA/SNI and defaults ssl:false with no TLS-only pg_hba; head->primary carries no sslmode/CA/cert/key while compose's primary requires hostssl+clientcert=verify-full
- [x] 6.3.4 F19: FIXED — the chart renders `cold_reader` into CNPG `managed.roles` (login + password Secret + connection limit) behind `coldTier.exportRole.enabled`, which now owns the credential in Kubernetes; the migration creates the role NOLOGIN with its grants and only grants LOGIN in the compose/dev path where it also sets the password, so the role is never connectable without a credential
- [ ] 6.3.5 F21: the head NetworkPolicy blocks CNPG's Kubernetes API egress, so the instance manager can fail before the DB is managed
- [ ] 6.3.6 F20 (P2): a complete named cold-tier Helm values contract (bucket/credentials/head/primary/pressure), rendered into core and migrations — today enabling the head creates an idle head with the runtime still disabled
- [ ] 6.3.7 F22 (P2): tighten the "least privilege" policy — pod-selector ingress and kube-system DNS instead of `podSelector: {}` / `namespaceSelector: {}`
- [ ] 6.3.8 F23 (P2): dedicated ephemeral spill volume with coherent request/limit/cap (today spill shares the 20Gi database PVC)
- [ ] 6.3.9 F24 (P2): set cold_reader CONNECTION LIMIT and narrow the blanket `_timescaledb_internal` grant to registry hypertables
- [ ] 6.3.10 F25 (P2): revoke the default-privilege dependency in `down/0` so DROP ROLE succeeds; test migration up/down
- [x] 6.3.11 F26: FIXED — the smoke now waits for the entrypoint's 'init process complete' banner and requires readiness to hold across several consecutive probes, so it cannot certify the temporary init server

### 6.4 SRQL routing (P1 unless noted)
- [ ] 6.4.1 F30: carry entity aliases in the registry projection — Events/SecurityFindings/ScanActivity/DnsActivity (ocsf_events) and AttributedFlows (ocsf_network_activity) are hand-omitted from the Rust match, violating the registry single-source rule
- [ ] 6.4.2 F32: design the NIF ABI before 4.1 — translate/5's 5th arg is already `mode`; reusing it for cold config would break the existing contract, and QueryPlan drops mode so background hot-only cannot be enforced. Use versioned translate/6 (or a structured options request) with a compatible /5 wrapper
- [ ] 6.4.3 F29 (P2): preserve explicit-filter/absolute-hint provenance — the plan builder synthesizes a 24h range for `in:logs`, so the routing helper cannot distinguish a default from an explicit bound; add an end-to-end no-time routing test

### 6.5 Telemetry/contract (P1 unless noted)
- [x] 6.5.1 F34: FIXED — chart renders SERVICERADAR_CNPG_STORAGE_SIZE from cnpg.storageSize (compose documents the explicit-bytes override); database_bytes now sums all DBs + WAL. Live: usage_pct=51.7 where it was nil. held_chunks also rewritten to one query driven off existing hypertables (no per-table erroring regclass casts)
- [ ] 6.5.2 F35 (P2): implement the specified headroom budget (volume + p95 ingest -> headroom_days) and emit it
- [ ] 6.5.3 F36 (P2): add the authenticated JSON admin endpoint required by task 3.1/D10
- [ ] 6.5.4 F38 (P2): base held_chunks on Timescale chunks older than each table's hot retention (LEFT JOIN manifest for state), as PressureMonitor already does — the current gauge misses old chunks with no manifest row and counts new pending ones
