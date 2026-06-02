## 1. Proposal
- [x] 1.1 Review existing agent, device inventory, datasvc object storage, Bumblebee, and CTI OpenSpec surfaces.
- [x] 1.2 Draft focused endpoint SBOM inventory proposal, design, tasks, and spec deltas.
- [x] 1.3 Validate with `openspec validate add-endpoint-sbom-inventory --strict`.
- [x] 1.4 Get proposal approval before implementation.
- [x] 1.5 Revise architecture for large-fleet scale: local cache, deterministic hashes, upload-on-change, and on-demand query path.
- [x] 1.6 Adopt the full golden-path architecture (TimescaleDB history + continuous-aggregate rollups, bounded cohort scatter-gather, freshness/coverage contract, command-bus safety, backpressure, observability, identity reconciliation) as in-scope now.

## 2. Agent And Collector
- [x] 2.1 Add endpoint inventory configuration structs, validation, profile delivery, and local override handling.
- [x] 2.2 Add a signed native add-on or scoped agent subcommand that collects Linux OS package inventory.
- [x] 2.3 Generate CycloneDX JSON with OS package components, OS metadata, collector provenance, and redaction metadata.
- [x] 2.4 Add bounded local spool handling, schema validation, size checks, and last-good artifact behavior.
- [x] 2.5 Add focused Go tests with dpkg, rpm, and apk fixture data.
- [ ] 2.6 Add deterministic `package_set_hash` over normalized sorted package identities (`package_manager`, `name`, `version`, `architecture`, `purl`), with a 1-byte algorithm-version prefix and volatile CycloneDX metadata excluded; add a separate `artifact_hash` over canonicalized CycloneDX bytes.
- [ ] 2.7 Persist the local last-known-good inventory cache (manifest, `package_set_hash`, `artifact_hash`, source summaries, last-seen package-DB mtimes, last uploaded hashes).
- [ ] 2.8 Gate scheduled scans on source-database mtime so unchanged hosts skip parsing entirely (with a forced full re-parse every Nth cycle); change reporting so unchanged inventories send lightweight status/hash summaries instead of full uploads.
- [ ] 2.9 Add typed endpoint inventory on-demand command handling that evaluates bounded predicates against the local cache and returns compact COUNT/EXISTS and DETAIL results; support an authorized device-scoped fresh scan behind a per-agent single-flight semaphore.
- [ ] 2.10 Add jittered upload scheduling (runtime-profile upload jitter, distinct from the scan-timer randomized delay) so correlated fleet changes spread over a window.
- [ ] 2.11 Add bounded retry/buffering of changed uploads when the control plane is unavailable, without losing previous uploaded-hash metadata.

## 3. Transport, Hashing, And Command Bus
(Storage/ingestion items previously numbered 3.3–3.5 were relocated to section 4 during the architecture revision.)
- [x] 3.1 Define protobuf/API contracts for endpoint inventory scan metadata, normalized package summaries, and SBOM artifact references.
- [x] 3.2 Add durable object upload flow for raw SBOM artifacts through datasvc or an agent-gateway relay.
- [ ] 3.3 Extend API/protobuf ingestion contracts with `package_set_hash`, `artifact_hash`, `upload_reason`, unchanged-scan status, source summaries, and a typed freshness verdict + cohort coverage envelope.
- [ ] 3.4 Add typed inventory command types (cache-query vs force-fresh-scan) and COUNT/EXISTS vs DETAIL response modes; route cohort results over a per-command topic (`agent:commands:{query_id}`) instead of the shared `agent:commands` topic.
- [ ] 3.5 Add a bounded cohort scatter-gather in the Elixir agent command bus (`agent_command_bus.ex`): resolve online + capable + authorized targets once, dispatch with bounded concurrency, batch result writes, and enforce a hard cohort cap with SRQL/persisted fallback above it.
- [ ] 3.6 Add command-bus safety: `ensure_dispatch_capacity` clauses for the inventory command types (per-agent single-flight for force-fresh, bounded concurrency for cache-query), an `endpoint_inventory.force_fresh_scan` RBAC catalog permission, a per-partition rate limit, a `CommandResult.payload_json` byte cap, and a guarantee that SBOM artifact bytes never traverse the command/result stream (route agent→gateway relay→datasvc).
- [ ] 3.7 Persist on-demand query command lifecycle/results using the existing agent command bus semantics.

## 4. Storage: Current State, History, And Aggregates
- [x] 4.1 Add Elixir migrations for endpoint inventory scan runs, SBOM artifacts, and normalized package/component rows in the `platform` schema.
- [x] 4.2 Add ingestion code that validates artifact hashes and replaces the current inventory view only after normalized rows commit.
- [x] 4.3 Add retention cleanup for historical scans and raw artifacts.
- [ ] 4.4 Make ingestion check the stored current `package_set_hash` first and no-op package-row replacement for unchanged hashes while still updating scan freshness metadata; recompute the hash server-side on changed uploads and flag mismatches; and, when an agent has sent no changed upload within the reconcile window (N scans or M days, whichever first), return a reconcile-floor directive in the scan acknowledgement so the agent performs its next upload as a full changed-path upload (server-directed, not agent self-counting).
- [ ] 4.5 Make raw SBOM artifact storage content-addressed by `artifact_hash` and deduplicated across hosts (golden-image dedup); record reused artifact references.
- [ ] 4.6 Move historical changed scans and server-computed package add/remove events into TimescaleDB hypertables (`maybe_create_hypertable` convention) with compression and `add_retention_policy`, independent of current-state retention.
- [ ] 4.7 Compute package diffs server-side at ingest and materialize them into the history hypertable.
- [ ] 4.8 Add TimescaleDB continuous aggregates for fleet rollups (host counts per package/version/ecosystem/CPE over time) that include offline/last-known hosts.
- [ ] 4.9 Add a GIN index on `endpoint_inventory_packages.cpes` (and ensure a canonical indexed PURL) so CPE/PURL filters are index scans, not seqscans.
- [ ] 4.10 Route endpoint-inventory ingest through a bounded admission queue instead of inline-synchronous ingestion.

## 5. Identity, Backpressure, And Observability
- [ ] 5.1 Backfill NULL `device_uid` inventory rows when an agent first acquires a canonical UID, and add the inventory tables to the device-merge reassign chain.
- [ ] 5.2 Add cost/volume observability: upload-reason counters, changed-vs-unchanged ratio (hash-flapping detection), object-store bytes, current-row counts, and autovacuum/compression lag for inventory tables.
- [ ] 5.3 Design the agent status heartbeat to carry operator-defined standing-question result counts (forward-compatible for continuous-aggregate-backed fleet answers).

## 6. Query And UI
- [x] 6.1 Add Ash resources/API reads for scan status, artifact metadata, and package rows.
- [x] 6.2 Add SRQL fields or query support for package name, version, package manager, PURL, CPE, and current-vs-historical inventory state.
- [ ] 6.3 Add a device/asset detail surface showing latest scan status and installed package inventory.
- [ ] 6.4 Add operator controls for enabling sources, cadence, retention, and redaction.
- [ ] 6.5 Add API/SRQL-visible freshness fields: `package_set_hash`, last scan time, last changed scan time, unchanged scan count, and the typed freshness verdict.
- [ ] 6.6 Add SRQL/continuous-aggregate-backed fleet rollup queries (host counts per package/version/CPE) that do not scan the live current-state tables.
- [ ] 6.7 Add an on-demand endpoint software query surface: a device-scoped check/refresh action and a bounded cohort/fleet query form that displays compact live results with freshness and the cohort coverage envelope.

## 7. Validation
- [ ] 7.1 Run focused Go tests for collector, mtime gate, spool validation, hashing determinism/version, and local cache fallback.
- [x] 7.2 Run Elixir migration/resource tests for ingestion and current inventory replacement.
- [x] 7.3 Run SRQL tests for endpoint package predicates and projections.
- [ ] 7.4 Run Go tests for hash-gated upload decisions, jittered scheduling, and typed on-demand query command handling (COUNT/EXISTS and DETAIL, device-scoped force-fresh authorization).
- [ ] 7.5 Run Elixir tests for unchanged `package_set_hash` no-op behavior, server-side hash recompute/mismatch flagging, reconcile-floor forced upload, content-addressed artifact dedupe, hypertable history + continuous aggregates, GIN index usage, and identity backfill/merge reassignment.
- [ ] 7.6 Run agent-gateway tests for bounded cohort scatter-gather (cohort cap, per-command topic isolation), dispatch capacity/rate enforcement, force-fresh RBAC + semaphore, and `CommandResult` payload cap.
- [ ] 7.7 Run web-ng tests for inventory status, freshness verdict, package UI, fleet rollup, and on-demand/cohort query UI.
- [ ] 7.8 Run OpenSpec validation and focused build/test commands before rollout (update bazel BUILD deps for any new Go/Rust imports and test files).
