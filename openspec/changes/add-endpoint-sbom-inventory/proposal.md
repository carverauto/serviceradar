# Change: Add Endpoint SBOM Inventory

## Why
Operators need first-party endpoint software visibility to answer incident questions such as "which assets have nginx installed?" without relying on demo fixtures, ad hoc SSH checks, or external endpoint tools. ServiceRadar currently has bounded Bumblebee exposure findings and process/flow attribution, but it does not collect full installed package inventory or endpoint SBOM artifacts.

The design must be the scale-correct architecture from the start, not a small-fleet design we upgrade later. Uploading a full package/SBOM snapshot from every endpoint on every scan, and rewriting every package row on every scan, would turn routine inventory collection into hundreds of millions of row operations per day at 100k+ hosts. Endpoint software inventory keeps detailed state close to the endpoint, persists central state only when it changes, splits durable storage into queryable current-state and compressed time-series history, answers fleet questions from incremental aggregates and live edge queries, and never makes the relational current-state tables the first stop for unchanged scans or the substrate for fleet-wide scans.

## What Changes
- Add an opt-in, policy-controlled endpoint software inventory collector for managed agents (Linux dpkg/apt, rpm/dnf/yum, apk first), delivered as a signed native add-on.
- Compute deterministic, versioned `package_set_hash` and `artifact_hash` on the endpoint and gate all uploads on hash change: unchanged scans send only a lightweight status/hash heartbeat; the full CycloneDX artifact and normalized rows upload only when the hash changes or a guarded force-refresh occurs.
- Gate the collector's package-database parse on source-database modification time so unchanged hosts skip parsing entirely, not just upload.
- Pin hash canonicalization (SHA-256 over sorted normalized package-identity fields, with volatile CycloneDX metadata excluded), prefix a 1-byte algorithm-version, recompute the hash server-side on every changed upload and flag mismatches, and force a full reconcile upload every Nth scan / M days so a stuck or poisoned hash cannot suppress inventory indefinitely.
- Maintain a local last-known-good inventory cache on the endpoint that serves unchanged-scan decisions and on-demand query commands.
- Store raw SBOM artifacts in durable object storage content-addressed by `artifact_hash`, deduplicated across hosts (golden-image dedup), with size limits, retention metadata, and upload provenance.
- Split durable storage into current-state and history: normalized current package/component rows live in regular CNPG tables for point lookups and device detail (replaced only for changed inventories, never rewritten for unchanged scans); historical changed scans and package add/remove events live in TimescaleDB hypertables with compression and retention policies; package diffs are computed server-side at ingest.
- Serve fleet rollups ("how many hosts have nginx 1.24?") from TimescaleDB continuous aggregates so dashboard/fleet questions are incremental indexed reads that also cover offline/last-known hosts, never a `GROUP BY` over the live current-state tables.
- Add a bounded on-demand live query path over the existing agent-gateway command bus: device-scoped queries answered from the local cache, and cohort/fleet queries dispatched through a bounded scatter-gather (bounded concurrency, hard cohort cap with SRQL/persisted fallback above it) over a per-command result topic, with COUNT/EXISTS and DETAIL response modes.
- Put a typed freshness verdict (fresh/stale/unknown plus age) on every live answer and a cohort coverage envelope (targeted/answered/offline/expired/pending) so partial or stale answers are never read as authoritative or complete.
- Treat on-demand queries as cache-first. Force-fresh-scan is optional, disabled by default, device-scoped only, and — when enabled — requires an explicit RBAC permission, a per-agent single-flight semaphore, and a per-partition rate limit.
- Add command-bus safety: typed inventory command types, dispatch capacity and rate enforcement for inventory commands, a `CommandResult` payload byte cap, and a hard rule that SBOM artifact bytes never traverse the command/result stream.
- Add ingest backpressure for correlated mass change: jittered upload scheduling plus a bounded ingest admission queue so a fleet-wide patch flip does not collapse the hash-gate win into a synchronized upload storm.
- Add cost/volume observability: upload-reason counters, changed-vs-unchanged ratio (hash-flapping detection), object-store bytes, current-row counts, and autovacuum/compression lag.
- Fix device-identity reconciliation for inventory rows: backfill NULL `device_uid` rows when an agent first acquires a canonical UID, and reassign inventory rows on device merge.
- Design the agent status heartbeat to carry operator-defined standing-question result counts so continuously-evaluated fleet predicates can feed the continuous aggregates without a later protocol change.
- Surface current inventory, freshness, scan provenance, and live/standing query results on devices/assets via SRQL/API and a device + cohort query UI.
- Keep endpoint collection disabled by default, policy controlled, bounded, and privacy-redacted; ship OS-package sources first with language-manifest, listening-service, and executable-metadata sources behind separate policy flags.

## Impact
- Affected specs: endpoint-software-inventory, agent-configuration, data-service-storage, device-inventory
- Affected code:
  - `go/pkg/agent/**` (collector, mtime gate, hashing, local cache, on-demand inventory command handling, jittered upload)
  - `go/cmd/agent/**`
  - `go/pkg/agentgateway/**` (agent-side control-stream client receiving/answering inventory commands; payload bound on returned results)
  - `build/native_addons/**`
  - `proto/**` (hash/upload-reason/freshness/response-mode fields)
  - `elixir/serviceradar_core/priv/repo/migrations/**` (current-state columns, TimescaleDB history hypertables, continuous aggregates, GIN index, retention/compression policies)
  - `elixir/serviceradar_core/lib/serviceradar/edge/agent_command_bus.ex` and `agent_commands/pubsub.ex` (bounded cohort scatter-gather, per-command result topic, dispatch capacity/rate enforcement, result payload cap)
  - `elixir/serviceradar_core/lib/serviceradar/identity/rbac/catalog.ex` (new `endpoint_inventory.force_fresh_scan` permission)
  - `elixir/serviceradar_core/lib/**` (hash-gated ingestor, server-side diff, identity reconciler, observability, ingest admission queue)
  - `elixir/web-ng/lib/**` (device detail, freshness, cohort query UI)
  - `rust/srql/**` (current-vs-historical predicates, CPE/PURL projections, continuous-aggregate-backed fleet rollups)
  - `helm/serviceradar/**`

## Non-Goals
- Do not enable full package or filesystem inventory by default.
- Do not perform broad filesystem hashing.
- Do not implement the full CTI observable matcher from `add-cti-signal-coverage`; this slice only guarantees a canonical, indexed PURL/CPE so that matcher can match by coordinate without re-ingesting inventory.
- Do not replace Bumblebee exposure scanning; endpoint SBOM inventory complements it with durable package/component state.
- Do not implement a peer-to-peer or linear endpoint chain; use the existing agent-gateway unicast control stream and partitioning.
- Do not make Postgres the first stop for every unchanged package scan.
- Do not run fleet-aggregate `GROUP BY` over the live current-state package tables; fleet rollups come from TimescaleDB continuous aggregates or the on-demand bus.
- Do not adopt a separate columnar engine (e.g. ClickHouse). Historical and analytical needs are served by TimescaleDB hypertables and continuous aggregates; DuckDB may be added later for ad-hoc analytics.
- Do not support fleet-wide force-fresh-scan; force-fresh is optional, device-scoped, and guarded.
- Do not carry SBOM artifact bytes over the agent command/result stream.

## Dependencies
- Agent configuration delivery must assign an endpoint inventory profile to a managed agent.
- Datasvc object uploads must keep enforcing bounded object size and storage limits, and support content-addressed artifact reuse for raw SBOM artifacts.
- The existing agent-gateway control stream and command bus must route on-demand inventory queries to connected agents without inbound connectivity to endpoints, and must support a bounded cohort scatter-gather with a per-command result topic.
- TimescaleDB must be available for endpoint inventory history hypertables, retention/compression policies, and continuous aggregates, degrading to plain tables where the extension is absent (matching existing `maybe_create_hypertable` conventions).
- This change adds an `endpoint_inventory.force_fresh_scan` permission to the RBAC catalog (`elixir/serviceradar_core/lib/serviceradar/identity/rbac/catalog.ex`, which has no endpoint-inventory entry today) to authorize guarded force-fresh-scan commands.
- Database schema changes must be implemented through Elixir migrations under `elixir/serviceradar_core/priv/repo/migrations/`.
