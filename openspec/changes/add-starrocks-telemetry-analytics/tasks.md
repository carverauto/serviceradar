## 1. Review and source preparation
- [x] 1.1 Approve this proposal and its storage-destination contract; update applicable JetStream/EventWriter guidance before implementation.
- [x] 1.2 Rebase a fresh feature worktree on current staging; audit every extraction bundle against the pinned source and current code without wholesale cherry-picks.
  - Rebased the three StarRocks commits onto live `origin/staging` (`e2827cf94c`, restore merge #4427). Restore merge remains an ancestor; not squashed. Worktree `/Users/mfreeman/src/serviceradar-495` from live `carverauto/serviceradar`. No wholesale cherry-pick of #488.
- [x] 1.3 Resolve overlap with active ingestion, counter semantics, anomaly, downsampling and retention proposals; leave both withdrawn designs and private recovery artifacts untouched.
  - Keep JetStream-first / EventWriter-only persistence. Coordinate, do not absorb: `scale-netflow-ingest-isolation` (dedicated flows stream), `fix-eventwriter-backpressure-hotpath` (pull consumers), `add-event-writer-processor-contributions` (add-on processors), `add-monotonic-counter-metric-semantics` and `update-sysmon-downsampling` (metric identity/volume), `harden-flow-attribution-pipeline` plus `add-flow-prefix-tag-enrichment` (current-state stays CNPG; catalog joins in 5.6–5.8), anomaly/causal proposals (edge move; do not extend retired central path), `add-object-store-retention` / `add-audit-history-retention-compression` / `add-tiered-telemetry-offload` (retention is per-dataset, not a CNPG-only assumption). Withdrawn pg_duckdb #488 and private recovery artifacts remain untouched.

## 2. Independently shippable fixes
- [x] 2.1 Port pending interface tasks and ICMP/availability lifecycle fixes with pagination/source-change/stale-result tests.
- [x] 2.2 Port shared history windows and independent home-dashboard cookies, including authenticated scope and Full Screen behavior.
- [x] 2.3 Port final requested-bounds, calendar/timezone, axis and cadence/gap fixes with formatter and JS build/test registrations.
- [x] 2.4 Remove only the device-list Tags column and correct conditional colspans.
- [x] 2.5 Port per-view NetFlow loading/error handling without archive routing.
- [x] 2.6 Implement the new full-width favorited-interface chart rows and verify synthetic desktop/narrow layouts.
- [x] 2.7 Port transaction-local JIT with commit/rollback/no-leak tests; exclude archive APIs.
- [x] 2.8 Review and port sweep summary emission/chunk semantics with synthetic Go regressions.
- [x] 2.9 Review and port locked inventory freshness with a concurrent transition regression.
- [x] 2.10 Decide whether the conditional PostgreSQL CAGG bundle is needed; if yes, port schema, durable backfill, query guards and parity tests together in a separate PR. Record explicit deferral if no.
  - Deferred: PostgreSQL CAGG routing remains CNPG compatibility work and is not a StarRocks prerequisite. It will land in a separate PR only if a remaining CNPG-backed dataset still needs hourly CAGG after StarRocks cutover.

## 3. StarRocks foundation
- [x] 3.1 Pin compatible StarRocks/operator/CRDs/images, architectures and resource profiles; approve ownership, RPO/RTO and cost envelope.
- [x] 3.2 Add Bazel-managed synthetic shared-data and shared-nothing test environments and versioned schema/migration targets; no new shell scripts.
- [x] 3.3 Add opt-in Helm/operator integration and Compose profile, internal transport authentication, scoped roles/secrets, redirect policy and dedicated object storage configuration.
  - StarRocks remains optional when NetFlow is off. `flowCollector.enabled` fails closed unless `analytics.starrocks.enabled`. Warehouse covers flows, scalar metrics, logs and events; `cutoverDatasets` stays empty.
- [ ] 3.4 Prove FE metadata persistence, CN cache loss, upgrades, object outage and full restore; publish minimum supported installation profiles.
  - Lab shared-nothing limits recorded: FE follower restart PASS (3 Alive, invented rows survived). CN cache loss FAIL (enabledCn false). Object outage FAIL (no bucket). Full restore FAIL (not executed). Upgrade FAIL (already 3.5.21). Demo/serviceradar untouched.

## 4. Persistence and data model
- [x] 4.1 Inventory every dataset writer, reader, Ash resource, background consumer and current-state side effect; finalize flows/metrics identity, partition and retention contracts.
- [x] 4.2 Add the EventWriter destination seam preserving decoding/enrichment, demand isolation and nonnumeric/current-state writes.
- [x] 4.3 Implement bounded Stream Load, stable identities/labels, result reconciliation, per-destination progress, explicit poison quarantine and safe ACK handling.
  - `Destination.ack_cnpg_batch/4` requires Stream Load Success or durable quarantine when `Readers.mode_for/1` is starrocks; otherwise shadow stays best-effort. Helm cutover remains empty.
- [x] 4.4 Add flow attribution update events through JetStream and monotonic partial-update semantics; test redelivery without enrichment loss.
  - StarRocks shadow is `Rows.encode(:flow_attribution)` + Stream Load `partial_update`/`columns`; `process_batch` compares incoming `attribution_version` to stored (or in-batch max) and must not persist nil `bytes_in`.
- [x] 4.5 Prove crash/retry/batch-regrouping/label-expiry/partial-failure behavior and late-event expiry policy with synthetic real-database tests.

## 5. Authorized queries and dashboard acceleration
- [x] 5.1 Add backend-aware SRQL compilation and nonblocking execution with parameter binding, feature capability checks, stable result/cursor/Arrow contracts and existing authorization boundaries.
- [x] 5.2 Add scoped query caching only where measured; verify tenant isolation and revoked-access behavior.
- [x] 5.3 Implement time-bucket MVs/aggregate routing, freshness detection, disjoint raw edges and raw fallback for unsupported filters/classification; prove EXPLAIN selection and exact parity.
- [ ] 5.4 Migrate all flow readers including attribution/exporter cache/maps/threat paths, then all scalar-metric consumers including thresholds/anomaly/capacity/topology before their cutovers.
  - Flow, scalar-metric, log, and event-history readers dispatch through `Readers.mode_for/1`. Helm `cutoverDatasets` empty so default backend stays CNPG. Catalog joins are compiled for StarRocks mode; Elixir reads `SERVICERADAR_STARROCKS_CATALOG_ENABLED` at runtime. Dataset cutover still not enabled.
- [x] 5.5 Define and implement logs/events/alert-history phase with hosted one-year retention; keep current alert state in CNPG. Specify remaining datasets separately before enabling them.
  - Schema + SRQL dialect + shadow destination exist; remaining CNPG-direct history readers dispatch through `Readers.mode_for/1` (`event_window`, dns-policy, anomaly 2004 rows, logs rollup bounds). `in:alerts` stays a capability error. Dataset not enabled.
- [x] 5.6 Provision an opt-in read-only StarRocks JDBC catalog `cnpg_platform` onto CNPG `platform` current-state tables used for flow attribution and enrichment (process-correlation current-state, prefix tags, device/inventory identity); pin the PostgreSQL JDBC driver as a Bazel artifact; use a least-privilege CNPG reader role and infrastructure secrets; never expose auth, credentials, Oban or telemetry hypertables.
  - Live `cnpg_platform` catalog on lab FE (carverauto + farm01). Reader `serviceradar_starrocks_reader` has SELECT on three allowlisted objects only; `network_credential_secrets` JDBC SELECT is permission denied. Driver is file:// JDBC 42.7.13. Infra secret `serviceradar-starrocks-catalog` holds CREATE SQL (not in git).
- [x] 5.7 Compile authorized SRQL that needs current attribution, prefix tags or device identity as StarRocks joins against the catalog; attribution correlation, exporter cache, maps, threat queries and dashboard flow loaders MUST NOT dual-query CNPG and StarRocks and merge in application code.
  - StarRocks dialect joins `in:attributed_flows` / `hostname` / `prefix_tag` to allowlisted `cnpg_platform.platform` tables (`prefix_tags_catalog` text view; raw `cidr` is not JDBC-mappable). Elixir refuses catalog SQL while `catalog_enabled` is false.
- [x] 5.8 Prove synthetic join parity for attribution/enrichment, allowlist misses and catalog/CNPG unavailability as explicit errors; the catalog MUST NOT serve cut-over telemetry from CNPG, MUST NOT invent live process identity from the observation snapshot when current-state was requested, and MUST NOT write back to CNPG. Helm catalog flag stays off until those tests pass.
  - LIMIT 0 joins against `flow_process_attribution_current` and `ocsf_devices` succeed on lab FE. Secrets/logs are not selectable. Default chart `catalog.enabled` stays false; `values-demo.yaml` enables catalog with `secretName` and empty `cutoverDatasets`. Chart 1.11.7 ignores extra `storageVolumes`; JDBC is an emptyDir plus checksummed IPv4 wget initContainer. Carverauto rolled; farm01 Maven/DNS on some nodes CrashLoop'd that init so it stayed on overlay copies.

## 6. Migration, verification and rollout
- [x] 6.1 Inventory actual source coverage privately and define historical identity mapping, backfill watermarks/checkpoints and overlap deduplication; do not resume paused recovery blindly.
- [x] 6.2 Add bounded backfill and single-owner shadow writes; compare exact counts/totals/NULLs/sampling/rates/enrichment per interval against synthetic ground truth.
- [ ] 6.3 Run the benchmark matrix and failure/restore drills; record explicit failures, resource/cost evidence, latency percentiles and maximum passing load.
  - Synthetic matrix recorded pass/fail only. PASS: identities_1, identities_100 (in-cluster Mix-generated Stream Load + Query.execute 100/120000), readers_1. FAIL: identities_1000/10000, rate_10k/50k/100k, soak_1h, readers_10/50 (not executed; not a capacity claim). Workstation StreamLoad.persist hits FE 307 to BE ClusterIP.
- [x] 6.4 Run focused tests, core disposition checks and repository make test before implementation PRs; run relevant lint and GitHub checks. Prior PR evidence does not transfer.
- [ ] 6.5 Complete browser and authorized post-rollout data acceptance; validate observations occurred after rollout completion.
  - Unverifiable here: no dataset cutover, no authorized post-rollout browser session. Helm `cutoverDatasets` empty; demo/serviceradar untouched.
- [ ] 6.6 Cut over one dataset at a time only with approved consumer/coverage gates and verified rollback history; stop on mismatch.
  - Unverifiable here: live cutover not performed. Rollback is Helm `cutoverDatasets: []` (already empty) so `Readers.mode_for/1` stays CNPG.
- [ ] 6.7 Retire old writers/storage/jobs only under a separate reviewed cleanup with rechecked coverage and restore proof; update operator/user docs and retention guidance.
  - Unverifiable here: EventWriter still inserts CNPG first; no Timescale CAGG/hypertable/writer path was retired.
