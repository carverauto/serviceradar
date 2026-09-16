# StarRocks analytics design

## Context and verified seams

The proposed deployment is StarRocks; this is not a database bake-off. The motivation is reported long-window latency and storage cost, not a demonstrated theorem that Timescale cannot scale. No fleet-capacity promise follows from this proposal.

At the proposal base:

- `EventWriter.Pipeline.handle_batch/4` dispatches batches and owns success/failure acknowledgement. Preserve the existing dedicated flow demand domain and JetStream retention ownership.
- `EventWriter.Processors.Metrics.process_batch/1` decodes/enriches metrics, writes nonnumeric SNMP facts to the current-state model and passes numeric rows to `Telemetry.insert_rows/1`. Preserve that split and current-state side effects.
- `EventWriter.Processors.Flows.insert_rows/1` is a persistence seam after flow processing. Keep normalization, sampling, identity/enrichment and malformed-message accounting.
- `ServiceRadarWebNG.SRQL.execute_query/6` authorizes through `EntityAccess` before translation; execution currently uses PostgreSQL transactions. `rust/srql/src/query/types.rs::QueryPlan` has no dialect. A MySQL wire client alone cannot execute the existing compiler's PostgreSQL output.
- `flow_attribution/correlation.ex` updates `ocsf_network_activity` after ingestion. Raw flows are not immutable in the current product.
- Direct historical consumers include `inventory/interface_threshold_worker.ex`, `network_discovery/topology_graph/telemetry/metrics.ex`, observability seasonal/anomaly/capacity sources, exporter cache refresh, ingest-silence detection, retrohunt and retention. They must be inventoried beyond web SRQL.

Ripwire's structural map was used for orientation; dynamic Elixir dispatch and SQL readers require explicit searches and integration tests.

## Goals and non-goals

Goals: fast, bounded dashboard queries; correct long history; reliable JetStream delivery; preserved operator workflows; reduced CNPG telemetry load; explicit operational ownership and reversible cutover.

Non-goals: implementation in this session; retiring CNPG for inventory/auth/config/credentials/Oban/AGE/current alert state; replacing NATS with Kafka; deploying pg_duckdb; changing other clusters; automatic recovery of the withdrawn deployment; adopting numeric capacity claims from the pasted discussion.

## Deployment and storage decision

Hosted: operator-managed shared-data cluster, durable FE metadata volumes, multiple FE replicas for quorum, CN compute with disposable local data cache, and a dedicated S3-compatible analytics bucket/storage volume. Start the production design with three FEs across failure domains; benchmark CN count, memory and disk sizing before pinning defaults. Object data plus FE metadata/backup form the recovery contract; the bucket alone is not a complete backup.

OSS: retain CNPG compatibility until explicit opt-in, and offer StarRocks shared-nothing with durable BE volumes for operators who want analytics without object storage. Shared-data is also available when configured. A single-node development profile is not HA. Do not make OSS install an object store implicitly. Document the resource/operational cost of each supported profile; test both StarRocks modes before claiming support.

Pin a supported StarRocks patch release, operator/chart version, CRD schema and image digests during the foundation task. Validate version-specific MV, primary-key, TLS, backup and architecture support. No `latest` images or copied unvalidated CR YAML. Install operator CRDs at cluster scope under an explicit owner, separately from tenant releases; application charts reference it. Sibling hosted provisioning changes need a separate repository handoff.

Service-to-service credentials belong in the platform infrastructure secret mechanism, with least-privilege writer/query/migrator roles. Monitored-device and integration credentials stay in the unified CNPG inventory. Internal-only services, authenticated TLS on SQL/load paths, allowed redirect destinations, network policy, object-store scope and rotation are part of the foundation. If the pinned release cannot satisfy native transport requirements, validate an internal mTLS termination design before rollout.

Cache residency is not retention. In shared-data mode remote storage holds durable table data and local disk caches it; a 30-day cache objective cannot guarantee every recent row remains local. Retention is per dataset and resolution. Default hosted flows/logs/events/alert history to 365 days, permit longer configured values, and specify scalar-metric/raw/rollup policy explicitly before enabling that dataset. Keep raw and aggregate coverage discoverable. Expiry cannot race backfill, rollback protection or approved holds. Never reuse the database backup bucket for analytics.

## Persistence contract and delivery

Keep EventWriter as the sole logical persistence owner. Add a destination boundary after existing processor decoding/enrichment. Do not introduce an independently competing Go/Rust JetStream consumer. Backend networking can use a bounded client under EventWriter supervision; no NIF-blocking network calls.

Batch by tenant, dataset and schema version with maximum encoded bytes, rows, age and in-flight requests. Limits must protect memory and guarantee progress on low traffic; benchmark them instead of hardcoding the pasted 50,000-100,000-row advice. Preserve stream sequence and per-message row ordinal through decoding so retries identify the same records even if batch boundaries change. Bound JetStream pending work and expose pending age, retention headroom, load latency, committed rows, rejected rows and oldest unpersisted event.

Proposed raw-table choice: Primary Key tables with stable ingestion identity for initial flows and scalar metrics, allowing replay-safe upserts and flow attribution updates. Include required partition columns in the key; specify stable source epoch/stream/sequence/row identity and precision before DDL. Identity must survive retries and migration overlap, not derive from delivery attempt or arbitrary batch boundaries. Preserve metric logical uniqueness/counter identity where current behavior requires it. Never hash only a flow's five-tuple: distinct observations are valid records.

This chooses correctness over assuming Duplicate Key append-only behavior. Benchmark primary-key write/index costs and asynchronous MV support. If this cannot meet the acceptance gate, revise this proposal with a proven durable batch-identity/deduplication design before selecting Duplicate Key tables; do not silently weaken delivery guarantees.

Use Stream Load with stable labels for retries of the same payload. Persist batch/load bookkeeping before an ambiguous operation when needed; CNPG Ash resources/migrations may hold bounded control metadata, not duplicate all telemetry payloads. Label retention is finite and is not the sole deduplication mechanism. Disable load modes that discard caller labels until their retry semantics are proven. Inspect response status and row counts, not just HTTP status. Reject silent filtered-row loss. `Publish Timeout` and an existing label require transaction-status reconciliation; they are not permission to submit a fresh batch. ACK only after confirmed durable visible completion, or after a defined durable quarantine disposition for poison data; extend acknowledgement deadlines while reconciling. Persist quarantine payloads securely with bounded retention and replay identity, expose operator failure state, and never commit them as fixtures.

During shadowing, the same owner tracks each required destination independently. If one succeeds and another fails, retry only the missing destination with stable identity. Do not assert cross-database atomicity. Test crash points before/after load, commit, status lookup, receipt persistence and ACK. Old replay after retention expiry must not resurrect expired data.

## Data model and mutable enrichment

Flows retain the current OCSF fields, nullable ports, IP family, UTC precision, exporter/interface identities, sampling factors, directions and enrichment provenance. Choose partition granularity, sort order and sharding from measured filters/skew; do not copy a fixed bucket count. Metrics retain series identity, temporality, units, counter resets/wraps, timestamps and metadata. Precompute additive quantities only where semantics permit; averages require sum/count and percentiles require a defined mergeable representation.

Flow process attribution is a blocking seam: retain current correlation state in CNPG and publish versioned attribution changes through JetStream to EventWriter. Apply monotonic partial updates to stable flow identities, preserving telemetry columns on redelivery and preventing older enrichment from overwriting newer state. No direct correlator-to-StarRocks writes. Backfill needs a stable mapping from historical flow identity and a pinned enrichment snapshot/version. Test late attribution, retraction, stale update and replay. Evaluate join-based enrichment only if bounded and semantically equivalent; no distributed join in the request path is assumed.

Schema manifests and upgrades are versioned Bazel-declared inputs. CNPG bookkeeping uses Ash resources/codegen; StarRocks DDL runs through a versioned, idempotent migration target with locks/version tracking and compatibility checks, not a shell script or PostgreSQL migration pretending to manage another engine. Define rollback-compatible additive changes and failed-migration recovery.

## Query, authorization and aggregates

Retain SRQL syntax and authorized Ash-facing entry points. Add an explicit backend/feature capability to translation and execution; preserve result JSON, Arrow where used, pagination/cursor ordering, NULLs, timestamp precision and errors. Parameter binding and identifier allowlists must be backend-specific. No regex conversion of PostgreSQL SQL. No new controller-level SQL escape hatch.

Route by configured dataset and migration generation, not time guessed from data presence. Keep PostgreSQL for control-plane entities and unmigrated history. Unsupported StarRocks query shapes return an explicit capability error during preview and block dataset cutover; do not silently fall back to incomplete CNPG data. Inventory and eliminate direct historical SQL assumptions before switching writers.

Authorization context must reach every loader and executor. Preserve tenant isolation, device/group access and actor permissions; cache keys include authorization scope/version, backend generation, full query, resolved bounds and timezone. A short scoped cache may reduce repeated refreshes, but cannot conceal missing coverage or errors. Include cross-tenant and revoked-access tests.

Use bounded server-side time buckets and Top-N for dashboard panels, raw indexed/partition-pruned queries for investigation. Initial rollups: 1m/5m and 1h where supported by workload, grouped by the exact dimensions the consuming query needs. Primary Key raw tables imply asynchronous MVs initially; do not promise synchronous rollups for this table type. Require EXPLAIN/profile evidence for rewrite eligibility and freshness, otherwise explicitly select a proven aggregate plan or raw fallback. Recompute invalidated buckets after mutable attribution/late data. Merge disjoint raw window edges with covered aggregates without double counting; avoid approximating totals. Label opt-in approximate cardinality/Top-N separately; exact semantics are the default.

Existing SRQL window limits become backend-aware and budgeted. A one-year retention setting is not a promise to return all raw records in one response: aggregate queries use bounded points; raw investigation uses pagination and bounded time slices, including access to older slices.

## Dataset phases and reader inventory gate

| Phase | Datasets | Blocking consumers / preserved behavior |
| --- | --- | --- |
| First | OCSF flows | NetFlow dashboards/detail/Top-N/classification, exporter cache, maps/topology, attribution, threat queries |
| Second | Generic scalar metrics and existing sysmon/interface histories | ICMP availability, device charts, thresholds, anomaly/seasonal/capacity workers, topology and nonnumeric facts |
| Third | Logs, events and alert history | Search/filters, effective timestamps, rule/retrohunt consumers, audit/history; current alert state stays CNPG |
| Explicit follow-up contracts | OTEL points/traces, MTR traces/hops, BMP history and remaining time-series tables | Entity/schema/retention/reader inventory before activation; no blanket hypertable move |

For every phase, enumerate all writers/readers/resources, SRQL operators, background jobs, current-state side effects, retention and rollup consumers. Store a coverage matrix in the implementation PR. Unknown consumers block cutover. Coordinate `scale-netflow-ingest-isolation`, `add-event-writer-processor-contributions`, `add-monotonic-counter-metric-semantics`, `update-sysmon-downsampling`, audit retention and causal/anomaly work. Independent compression remains separate. Neither withdrawn proposal is resumed or archive-applied.

## Migration and rollback

1. Provision isolated synthetic StarRocks environments with Bazel targets; verify both deployment profiles, schema migrations and transport/security.
2. Complete single-owner shadow writes and read-only parity queries; CNPG remains serving authority for ordinary installations. Existing withdrawn-architecture installations require their own actual source/coverage inventory first.
3. Inventory retained raw history, old archives, manifests and checkpoints privately. Do not infer coverage from a healthy deployment or resume a paused restore. Import legacy data through an isolated, bounded migration adapter with source checksums/identities and durable progress; it is not a runtime pg_duckdb dependency.
4. Define a watermark and disjoint ownership of historical/live ranges, including late arrivals and overlap deduplication. Validate identities when old rows lack JetStream sequence metadata; require a stable historical-key mapping before overlap import. Backfill newest-first, then older history, without stealing live ingestion capacity.
5. Compare raw counts, byte/packet totals, NULL distributions, samples, rates and relevant aggregates by dataset/time range. Validate attribution and scope. Warm selected views; confirm freshness and reader coverage.
6. Switch reads per dataset/generation after acceptance. Keep old source and shadow persistence for a bounded rollback interval. Rollback requires verified old-source coverage through the switch time, including enrichment updates; otherwise pause cutover and repair coverage, never blindly redirect reads.
7. Stop the old writer only after all consumers and rollback conditions pass. Retire old storage/objects/jobs in a separately reviewed operation after re-querying coverage and restore evidence. Never remove the old head, bucket, manifests or checkpoints merely because #488 closed.

## Acceptance and benchmark design

All fixtures are invented; do not export/scrub a live environment. Proposed gates below require review of hardware/cost envelopes before measurement, and must be recorded as passed or failed rather than inferred from job status.

- Publish a reproducible Bazel benchmark profile: pinned versions, CPU/RAM/cache/storage/network budget, synthetic generator seed, schemas, sample distribution, cardinality/skew, retention span, ingest rate, concurrency and warm/cold cache conditions.
- Sweep 1/100/1,000/10,000 synthetic exporter identities independently of rate, and total rates of 10k/50k/100k flows per second as exploratory test points. These are invented workloads, not claimed supported capacity. Soak at a preselected target for at least one hour while querying; reject sustained backlog growth and report the highest passing workload.
- Exercise 1h/24h/7d/30d/90d/365d and partial/custom windows with 1/10/50 concurrent readers. Proposed targets: warm overview end-to-end p95 <=1s, cold long-window aggregate p95 <=5s, ingest-to-query-visible p95 <=10s at the agreed reference load. Record p99, errors, scan bytes, cache misses, object requests/egress and full deployment cost too. Targets are not results; any missed gate prevents a capacity claim.
- Compare against CNPG on equivalent synthetic queries/resources, with exact raw ground truth. Fail on missing/duplicate rows, changed NULL/sampling/counter/classification behavior, unauthorized rows, stale source results or misleading chart bounds.
- Restart a CN and writer, lose a connection after commit, fail an FE, exhaust a bounded queue, simulate object-store outage and label expiry. Prove eventual recovery, explicit failure states and unchanged totals; measure cold-cache recovery rather than claiming instant rescheduling.
- Demonstrate FE metadata plus object-data restore into an isolated environment. Set and review RPO/RTO and retention/outage budgets before rollout; do not invent guarantees from replication alone.
- Browser tests use synthetic desktop/narrow fixtures for windows, independent cookies, source changes, full-width charts, axis readability, timezone and real gaps. After authorized deployment, measure queries started after rollout completion and inspect returned rows, not just pods/jobs.

## Corrections to the supplied architecture sketch and sources

Official documentation checked while drafting; pin/recheck these capabilities for the selected release:

- [Shared-data deployment](https://docs.starrocks.io/docs/deployment/deploy_shared_data_manually/): remote data and local cache are separate; FE metadata is persistent. Cache misses/restarts still have cost. Do not conflate shared-data caching with shared-nothing storage cooldown.
- [Operator examples](https://starrocks.github.io/starrocks-kubernetes-operator/examples/starrocks/): use the pinned CRD/example and complete shared-data configuration, not the pasted partial YAML.
- [Stream Load](https://docs.starrocks.io/docs/loading/StreamLoad/): FE redirects to a BE/CN coordinator; use an internal FE endpoint with validated redirect handling and suitable timeouts. A load is transactional; it is not free of transaction overhead.
- [Load statuses and labels](https://docs.starrocks.io/docs/sql-reference/sql-statements/loading_unloading/STREAM_LOAD/): success, publish timeout and duplicate label are different outcomes; labels expire. HTTP success alone does not establish accepted row parity.
- [Duplicate Key tables](https://docs.starrocks.io/docs/table_design/table_types/duplicate_key_table/): append-only storage does not replace a deduplication or mutable-enrichment contract.
- [Table capabilities](https://docs.starrocks.io/docs/table_design/table_types/table_capabilities/): Primary Key tables support asynchronous MVs, not synchronous MVs. The initial replay-safe table choice changes the rollup design.
- [Synchronous views](https://docs.starrocks.io/docs/using_starrocks/Materialized_view-single_table/) and [asynchronous rewrite](https://docs.starrocks.io/docs/using_starrocks/async_mv/use_cases/query_rewrite_with_materialized_views/): rewrite depends on eligible expressions, dimensions and freshness. Listing raw timestamp/bytes columns in an ALTER ROLLUP is not a demonstrated minute-bucket sum/count view.

No compression ratio, subsecond billion-row result, guaranteed 100k-flow/s capacity, instantaneous pod recovery, fixed sysctl, memory percentage or fixed bucket count from the supplied text is adopted as a fact/default.

## Remaining design gates

Before foundation implementation, choose exact version/profile/resource bounds, operational owner and backup/RPO/RTO envelope. Before schema implementation, finalize stable record identities, attribution update ordering and historical overlap mapping. Before each dataset activates, approve its reader coverage, raw/rollup retention, query budget and measured acceptance results. These are explicit implementation gates, not reasons to delay the independent UI ports.
