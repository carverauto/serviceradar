## Context
The platform has several adjacent signals but no durable endpoint package inventory:
- Bumblebee reports bounded exposure findings and scan metadata, not full installed package inventory.
- Sysmon reports host/process metrics, not package manager or SBOM state.
- Flow attribution records process context for network activity, not installed software inventory.
- Release/build SBOM documentation covers ServiceRadar artifacts, not customer endpoints.

This proposal implements the full, scale-correct endpoint inventory architecture (100k–1M hosts) now, rather than a small-fleet design upgraded later. It complements the CTI observable matcher work in `add-cti-signal-coverage`, which remains a separate change; the endpoint inventory architecture is complete as specified here.

## Goals
- Collect installed software inventory from agents in a way that is explicit, bounded, and operationally explainable.
- Preserve a raw CycloneDX JSON artifact for auditability and later reprocessing when the inventory changes or a guarded force-refresh occurs.
- Normalize common package fields for fast asset/package lookups while never rewriting unchanged inventories centrally.
- Keep the current-state relational footprint small and point-lookup shaped; push history and analytics into TimescaleDB hypertables and continuous aggregates.
- Keep detailed collection, package matching, and point-in-time questions close to the endpoint whenever a live query can answer the operator's question more cheaply than database ingest.
- Support cohort and fleet queries through bounded gateway-routed on-demand commands and through incremental fleet aggregates.
- Keep privacy-sensitive paths and file metadata opt-in.
- Make the collector safe to roll out gradually by profile, tag, or direct agent assignment, and safe to run on every host without correlated load spikes.

## Non-Goals
- Vulnerability feed ingestion, CVE scoring, and CTI matcher implementation (this slice only guarantees a canonical indexed PURL/CPE).
- Unbounded file crawling or whole-disk hash inventories.
- Mandatory deployment in the base agent profile.
- Peer-to-peer or linear endpoint chaining or endpoint-to-endpoint transport.
- Treating historical full-package snapshots as the default data plane.
- Fleet-aggregate `GROUP BY` over the live current-state package tables.
- A separate columnar engine (e.g. ClickHouse); TimescaleDB serves history and analytics, with DuckDB considered later.
- Fleet-wide force-fresh-scan.
- SBOM artifact bytes over the command/result stream.

## Architecture Decision
Endpoint inventory is a hybrid of persisted current state, compressed time-series history, incremental fleet aggregates, and live endpoint query:
- The endpoint collector builds a normalized package manifest locally.
- The agent computes deterministic, versioned hashes for the normalized package set (`package_set_hash`) and the raw CycloneDX artifact (`artifact_hash`).
- The agent reports scan status, counts, source summaries, and hashes on every scheduled scan, and uploads the full artifact and normalized package rows only when a hash changes or a guarded force-refresh occurs.
- The control plane stores current changed inventory in regular CNPG tables for common SRQL/device-detail point lookups, writes historical changed scans and package add/remove events into TimescaleDB hypertables, and maintains continuous aggregates for fleet rollups.
- The on-demand query path asks connected agents or bounded cohorts to evaluate package predicates against their local cache and returns compact answers through agent-gateway.

This gives operators durable latest-known inventory, bounded history, O(1)-shaped fleet rollups, and live fleet answers without turning every scan on every endpoint into a full central write or a fleet scan over the current-state (OLTP) tables. Reusing the gateway/partition unicast control stream — rather than a Tanium-style peer/linear chain — is the correct fit for WAN-attached agents and avoids the patent-encumbered, subnet-bound chain model.

## Collector Model
Endpoint inventory runs as a signed native add-on or tightly scoped agent subcommand rather than expanding the always-on agent hot path. The collector writes a sanitized spool artifact and normalized manifest to the local ServiceRadar state directory. The agent reads only the latest valid output, validates size and schema, attaches agent identity/provenance, and updates a local last-known-good cache.

The collector gates work on source-database modification time. Before parsing, it stats the relevant package databases (dpkg `status`, apk `installed`, rpm `Packages`/`rpmdb.sqlite`) and compares against the last-seen mtimes recorded in the local cache. If none changed since the last successful scan, the collector skips parsing entirely and emits a lightweight unchanged status, with a forced full re-parse every Nth cycle to catch mtime-preserving edge cases. This makes an unchanged scan O(1) rather than O(packages) and avoids forking `rpm -qa` on every cycle.

The local cache stores:
- Latest normalized package manifest.
- Deterministic `package_set_hash` computed from sorted normalized package identity fields.
- Raw `artifact_hash` and optional local artifact path.
- Source summaries, package counts, and last-seen source-database mtimes.
- Scan status, timestamps, collector version, and redaction policy.
- Last successfully uploaded `package_set_hash` and `artifact_hash`.

If a scan succeeds but `package_set_hash` is unchanged, the agent reports a lightweight unchanged scan status and skips full artifact/package upload. If a scan fails, the previous successful cache remains eligible for on-demand queries and remains the current persisted state.

The first Linux implementation covers:
- OS release and kernel metadata.
- dpkg/apt, rpm/dnf/yum, and apk package databases where present.
- Optional language manifest discovery for bounded paths configured by policy.
- Optional listening-service and executable metadata only when enabled by policy.

## Deterministic Hashing
`package_set_hash` is the load-bearing scale mechanism, so its inputs are pinned, not left to the implementer:
- It is SHA-256 over a newline-joined, lexicographically-sorted encoding of the normalized package identity fields ingestion already dedups on: `package_manager`, `name`, `version`, `architecture`, and canonical PURL. Agent and server share the same canonicalization contract; until the shared helper is available on both sides, server-side canonicalization is authoritative and can return a corrected hash/reconcile directive.
- Volatile CycloneDX metadata (BOM `serialNumber`, BOM timestamp, JSON key ordering) and fields prone to drift (CPE enrichment) are explicitly excluded so that re-running the collector on an unchanged host yields the same hash.
- The hash is prefixed with a 1-byte algorithm version so that any future change to canonicalization is detectable and does not silently make every host report "changed" at once. A version bump is rolled out behind the reconcile-floor cadence rather than all at once.
- `artifact_hash` is a separate SHA-256 over canonicalized CycloneDX component payload bytes with scan-specific provenance fields excluded. It is used for content-addressed object storage and cross-host dedup; scan ID, agent ID, device UID, timestamps, and upload provenance live in scan/artifact metadata rows.

Server-side backstops:
- On every changed upload, ingestion recomputes `package_set_hash` from the normalized rows and flags (logs plus operator-visible metric, not a hard reject on first occurrence) any mismatch with the agent-reported hash, catching collector bugs and tampering.
- Ingestion forces a full changed-path upload every Nth scan / M days per agent regardless of hash, so a stuck or poisoned hash cannot suppress vuln-relevant inventory indefinitely.

## SBOM Format
CycloneDX JSON is the endpoint SBOM format. It has a compact component model, Package URL support, and broad parser/tooling support. SPDX is out of scope; a format adapter can be added separately if an operator requires it.

Each uploaded artifact records format and spec version; agent ID, canonical device ID when resolved, scan ID, collector version, and scan timestamps; SHA-256 digest and byte size; `package_set_hash`; object key and storage bucket; redaction policy and enabled collection sources.

## Storage Model
Storage is split by access pattern, all within Postgres + TimescaleDB:

Current state (OLTP, regular CNPG tables in the `platform` schema):
- Current inventory scan run and current normalized package/component rows per agent/device, marked current.
- Point-lookup shaped: "is package X on device Y", device detail, current SRQL predicates.
- Replaced only for changed inventories. A successful unchanged scan updates freshness/source-summary metadata on the existing current rows and does not delete/reinsert. Ingestion checks the stored current `package_set_hash` first and returns early on a match.

History and analytics (TimescaleDB hypertables in the `platform` schema):
- Historical changed scans and package add/remove events become time-partitioned hypertables (partitioned by scan time) created via the existing `maybe_create_hypertable` convention, with native compression and `add_retention_policy` so repetitive package history is cheap to retain and bounded independently of current state.
- Package diffs (added/removed/changed components between consecutive changed scans) are computed server-side at ingest and written as events, answering "when did this package appear or disappear?" without keeping every unchanged scan or recomputing diffs on the agent.

Fleet rollups:
- Exact current counts are served from maintained current-count tables updated from server-computed package diffs, not from ad hoc `GROUP BY` scans over current package rows.
- TimescaleDB continuous aggregates serve counts-over-time and trend questions from changed-scan/package-event history.
- Operator-defined standing-question result counts can feed their own aggregates once the standing-query evaluator lands.
- Current membership and cohort resolution ("which devices run coordinate X") are served by bounded GIN-indexed current-state `SELECT`s (the roaring inverted index is deferred — see Fleet Membership And The Deferred Inverted Index).

Object storage (datasvc):
- The raw SBOM component payload is stored through datasvc only when content changes or a guarded force-refresh occurs. Objects are content-addressed by `artifact_hash` so identical component payloads across a homogeneous/golden-image fleet are stored once and referenced by many scans. Per-scan provenance stays outside the content-addressed bytes.

DuckDB is a possible later addition for ad-hoc analytical queries over exported columnar snapshots; the OLTP/time-series boundary above is what keeps that option open without committing to it now.

## On-Demand Query Model
The existing agent-gateway command bus is the transport for live inventory questions, and queries are cache-first.

Device-scoped queries:
- A single-agent command is dispatched over the existing unicast control stream; the agent evaluates the predicate against its local last-known-good cache and returns a compact answer. No rescan is required.

Cohort/fleet queries:
- A dedicated bounded scatter-gather resolves targets once (online agents filtered by capability and authorized partition), dispatches with bounded concurrency, batches queued-result writes, and enforces a hard cohort cap. Above the cap the request is rejected with guidance to use SRQL/persisted state or fleet aggregates. This avoids serial 1-by-1 fan-out turning a large cohort into hours of calls and a quadratic result firehose.
- This change introduces a per-command result topic (`agent:commands:{query_id}`) that the requesting aggregator subscribes to before dispatch. The command bus today broadcasts on a single shared `agent:commands` topic; cohort inventory results MUST move to the per-command topic so subscribers receive only their command's results and one operator cannot observe another's (potentially sensitive) package matches.

Response modes:
- `COUNT`/`EXISTS` (default for fleet questions) returns only `{agent_id, device_uid, matched, package_set_hash, scan_ts}`; the control plane sums.
- `DETAIL` returns capped matched package identities.

Every answer carries a typed freshness verdict (`fresh`/`stale`/`unknown` plus `age_seconds` and `stale_threshold_seconds`) and, for cohorts, a coverage envelope (`targeted`/`answered`/`offline`/`expired`/`pending`). Answer time is bounded by command TTL, never by waiting for full completeness, and "no match in fresh data" is always distinguishable from "no match in stale data" and "agent offline".

This path favors "answer the question" over "upload the database." It is used for live fleet questions; SRQL over current CNPG remains the path for latest persisted state, device detail, and dashboards; continuous aggregates serve fleet rollups including offline hosts.

## Standing Questions And Fleet Rollups
Borrowing the most valuable idea from query-first endpoint platforms, operator-defined standing-question predicates are evaluated continuously at the edge against the local cache. The agent status heartbeat is designed up front to carry standing-question result counts, so standing results can feed the continuous aggregates and make "how many hosts have nginx?" an indexed read that includes offline/last-known hosts. The standing-result table and UI can land after the core path; this is an intentional sequencing decision, not architecture debt — the table and UI depend on a standing-query evaluator that is not part of this change, whereas fixing the heartbeat shape now avoids a future breaking protocol change.

## Automation, Findings, And Risk State
Endpoint inventory is an automation/signals subsystem first. The value path is: inventory + CVE coordinate-match → vulnerability findings → events/alerts → device risk-state enrichment → causal prediction. The topology/god_view graph is one optional renderer of verdicts, not the consumer this is modeled for.

Findings and events:
- Package-change events (`added`/`removed`/`version_changed`; canonical PURL/CPE; prev/new version; `package_set_hash`; canonical device UID; observed-at) are emitted server-side after the ingest transaction commits, via the bounded admission queue, to `signals.causal.inventory.*` (`signal_type='inventory'`), routed by the existing `bmp_causal_subject?` path into `CausalSignals`. These are inventory deltas, not findings.
- CVE-match vulnerability findings are emitted as OCSF Vulnerability Findings (`class_uid=2004`, `category_uid=2`, `type_uid=200401`, `activity_id=1`), CVSS→`severity_id`, `device={"uid": device_uid}` populated directly (the existing `normalize_device` does not read `device_uid`), `primary_domain='security'`. A finding is suppressed when `device_uid` is nil (pre-reconciliation) so it is never emitted with `device={}` and uncorrelatable. The change-event/finding schema is frozen with a deterministic `event_id` so redelivery does not duplicate `ocsf_events` rows, and `inventory` is a first-class `CausalSignals` domain.
- Findings are written via the Ash `OcsfEvent.record` path so `EventHandlerRunner` northbound automations (ticket/quarantine/webhook) fire, and alerting is wired by an explicit `evaluate_events` call from `CausalSignals` gated on `signal_type=='inventory'`, dispatched async/bounded (it is a synchronous ~15s `GenServer.call`; inline on fleet-patch volume would back-pressure Broadway). A seeded `StatefulAlertRule` (`group_by: device`) fires per-device vulnerability alerts with the full fired/recovered/renotify/cooldown lifecycle.
- The `OcsfEvent.record` path is only for alert/automation-worthy inventory vulnerability findings. Generic inventory package-change causal rows remain bulk persisted. Alert evaluation stays explicitly wired from `CausalSignals`, and device risk enrichment stays ingestor-driven rather than depending on the event write side effect.

Device risk-state enrichment:
- On a vuln match the ingestor calls `DeviceRiskReducer.upsert_contribution(source: "endpoint_inventory", source_ref: device_uid, score: CVSS*10 clamped 0–100)`. The reducer's ON-CONFLICT upsert + MAX-wins recompute gives correct multi-source arbitration and converges on package removal, writing `risk_score`/`risk_level_id`/`risk_level` on `ocsf_devices` via `Repo.update_all` (bypassing the Ash layer so `suppress_operational_event?` never blocks risk on inactive/decommissioned devices). `is_compliant` is handled by a separate write or deferred to `add-cti-signal-coverage` (KEV requires the advisory feed). This is the primary near-term signal the causal engine reads via `EmbeddedSrql`.

Ontology, relationally:
- A normalized endpoint-side `Package` entity carries the canonical PURL/CPE coordinate. `Device HAS_PACKAGE` is a CNPG current-state relation + SRQL projection — not a graph edge. The feed-agnostic match input contract exposes endpoint package canonical PURL/CPE, with the `{package_manager, name, version, architecture}` tuple as the deterministic fallback for feeds that omit PURL (Trivy's `trivy_findings` carries `(CVE, package_name)` and is image-scoped; AlienVault OTX is IP/CIDR-only today). This change owns the endpoint-side `Package` entity, device/package relation, and match input contract; `add-cti-signal-coverage` owns advisory-side `Package AFFECTED_BY CVE` population, matcher policy, advisory feed, and CVSS scoring. They meet at the canonical coordinate. Host-scope endpoint findings are kept distinct from image-scope scanner findings.

CPE is a co-equal match coordinate, not a PURL substitute. The endpoint side derives candidate CPE(s) per package (CycloneDX `cpe` is often sparse for OS packages) so CPE-indexed feeds — notably VulnCheck's free NVD++ — can match. But CPE matching differs from PURL: it is `vendor:product` membership plus version-range evaluation (`versionStartIncluding`/`versionEndExcluding`), not coordinate equality, and the `vendor:product` rarely equals the package name (`libssl3` → `openssl`). So the PURL↔CPE normalization, version-range evaluation, and distro-backport false-positive handling (NVD/CPE says the upstream version is vulnerable while the distro backported the fix) live in the matcher (`add-cti-signal-coverage`). PURL/ecosystem feeds (OSV/GHSA/distro security trackers) remain the higher-precision, backport-aware path for OS packages; CPE feeds add broad coverage and KEV enrichment (VulnCheck KEV feeds `pkg_kev_count`).

## Causal Prediction Without A Package Graph
The causal engine consumes inventory through `EmbeddedSrql` over CNPG (current-state package rows + the bounded Device risk attributes) plus the change-event/finding stream, reasons over `ultragraph`, and reuses `ocsf_devices.uid`. It does NOT traverse a package graph and does NOT ingest roaring bitmaps. Inventory risk composes INTO existing causaloids as numeric observations over the EXISTING device/service nodes, adding no new causaloid and no graph traversal:
- C5/C5b (articulation-point / bridge device) elevated in severity when `risk_score` exceeds a threshold or `pkg_has_unpatched_rce`.
- C7 (service-stack-collapse) urgency scaled by the hosting device's `risk_score`.
- C10 (blast-radius) severity elevated for a critical-CVE host.
- C11 (package version-churn flap) — only once version-change transitions are written as device `health_events`, deferred to the health-vocabulary change.

Reads: `risk_score` via `EmbeddedSrql(entity: devices)`; the bounded `pkg_*` summary via `graph_cypher` on the Device vertex. Until `rust/causal-engine` ships (it does not exist yet), enrichment still reaches god_view via `ocsf_devices.risk_score`. CVSS bands and the risk-score thresholds are owned by `add-cti-signal-coverage`; only the interface is built here.

## AGE Graph Boundary
The AGE topology graph (`platform_graph`) is network-scale (devices + interfaces + topology edges) and is frozen/unfrozen per causal reasoning tick. Endpoint inventory touches it in exactly one way: at hash-gated ingest, when a device's risk summary changes, a single `MERGE (d:Device {id: $uid}) SET` of ≤5 bounded scalars (`pkg_worst_severity`, `pkg_critical_count`, `pkg_kev_count`, `pkg_has_unpatched_rce`, `pkg_risk_summary_at`) on the EXISTING `Device` vertex — the established property-only-SET-on-existing-vertex precedent. No new vertex labels, no `Package` vertex, no `HAS_PACKAGE`/`AFFECTED_BY` edges. Per-package edges would be ~150M at 100k hosts × ~1,500 packages and would wreck the graph and the freeze/unfreeze cycle. The summary is conditional on advisory scoring (set `none`/`unknown` when absent, never stale) and marked topology-structure-invariant so the causal hydrator's unfreeze excludes it. Package membership lives only in the relational current-state tables + the GIN index.

## Fleet Membership And The Deferred Inverted Index
Structural fleet membership and cohort resolution ("which devices run coordinate X", "resolve this cohort") are served by the GIN-indexed `SELECT` over `endpoint_inventory_packages` (canonical PURL + GIN `cpes`) and TimescaleDB continuous aggregates — never an AGE traversal. This is adequate at 100k hosts and degrades gracefully toward 1M.

A roaring-bitmap inverted index is the eventual accelerator for interactive multi-predicate drill-down ("nginx AND log4j AND NOT patched") and instant offline-inclusive counts, but no automation consumer and the causal engine need it, so the NIF is deferred until an interactive cohort/drill-down consumer ships. The one irreversible piece is built now: a `uid → u32` ordinal dictionary (`platform.device_fleet_ordinals`, keyed on `ocsf_devices.uid`, never reused, tombstoned/reassigned on merge), because dense, stable, merge-safe ordinals are what serialized bitmaps require and cannot be retrofitted under load. The dictionary is NOT a persisted bitmap table. When the index is built, it is in-memory and rebuildable from current state, keyed on the dictionary ordinal, reusing the `god_view_nif` roaring pattern. Note god_view's bitmap key is an ephemeral per-snapshot list index with no FK — disjoint from this persisted ordinal — so any "which affected hosts also run package X" is a uid translation (`query_and_resolve_to_uids(coordinate) → Vec<device_uid>`) off the render hot path, never a direct cross-space bitmap AND.

## Command Safety And Authorization
- Inventory commands are typed (cache-query vs force-fresh-scan) rather than a single opaque action.
- Cache-query requires the operator's normal inventory-read authorization.
- Force-fresh-scan is optional and disabled by default, device-scoped only, and requires the control plane to authorize the requesting actor (not the transport/system identity) for `endpoint_inventory.force_fresh_scan` before dispatch. The agent enforces local policy, disabled-source rejection, and a per-agent single-flight semaphore (cap 1). The command bus enforces per-partition rate limits and dispatch capacity for inventory command types; today it returns success for unlisted command types (only `mtr.run`/`mtr.bulk_run` have capacity clauses), so this change adds inventory clauses. Fleet-wide force-fresh-scan is out of scope; a fleet-wide force would otherwise mean up to one privileged `rpm -qa`/`dpkg`/`apk` scan per host simultaneously.
- `CommandResult.payload_json` has an explicit byte cap (mirroring the existing results-stream bound). SBOM artifact bytes never traverse the command/result stream.

## Artifact Upload Routing (Resolved)
The agent has no inbound connectivity and the collector runs with `PrivateNetwork=true`, so artifact bytes upload over the agent's existing outbound path: an agent→gateway relay to datasvc (or a direct datasvc gRPC call), content-addressed by `artifact_hash`. Artifact bytes are never sent as a `CommandResult` payload; on-demand query answers reference an artifact by hash and an operator can request a relayed upload separately.

## Burst Backpressure And Backfill
- Agents apply jittered upload scheduling (a runtime-profile upload jitter, separate from the existing randomized scan-timer delay) so a fleet-wide patch flip spreads simultaneous changed uploads over a window.
- Endpoint-inventory ingest routes through a bounded admission queue (modeled on the existing sync ingestor queue) rather than running inline-synchronously, so a correlated mass change degrades gracefully instead of collapsing the hash-gate win into a synchronized upload storm.

## Device Identity Reconciliation
- Inventory rows written before identity reconciliation resolves a canonical UID get `device_uid = NULL`; the agent's first acquisition of a `device_uid` triggers a narrow backfill of its NULL inventory rows.
- Device merge reassigns endpoint inventory scan/package rows to the surviving canonical UID (the inventory tables are added to the merge reassign chain).
- The device-detail view still resolves rows through the reporting agent as a safety net.

## Observability
Operators and the team get cost/volume visibility: per-agent upload-reason counters, changed-vs-unchanged scan ratio (hash-flapping detection for build-timestamped versions), object-store bytes, current-row counts, and autovacuum/compression lag for the inventory tables, surfaced through the existing telemetry stack.

## Privacy And Safety
Collection is disabled by default. Profiles must opt in to sources such as OS packages, language manifests, listening services, and executable metadata separately; OS packages ship first and the rest stay behind their own policy flags. File paths and command-line-derived values are redacted unless a policy explicitly enables them.

Agents reject artifacts that exceed configured bounds, fail schema validation, or come from an unexpected collector version/signature. The previous successful inventory remains current if a scan fails.

On-demand queries enforce the same source and redaction policy as scheduled collection. A command cannot cause collection of a disabled source unless the assigned endpoint inventory policy allows that source and the command requester is authorized to force a scan.

## Scale And Retention
Expected large-fleet behavior:
- Routine scans send lightweight status/hash summaries; unchanged hosts skip both parse and upload.
- Full artifact uploads occur only on first scan, changed package set, changed artifact, the periodic reconcile floor, or a guarded force-refresh.
- Current package rows are replaced only for changed inventories; unchanged scans update freshness only.
- Historical scans/package events live in compressed TimescaleDB hypertables with independent retention; raw artifacts are content-addressed and deduped.
- Fleet rollups come from continuous aggregates; fleet-wide live questions use compact COUNT responses, a bounded cohort cap, and per-command TTL/result limits.

This keeps the current-state relational footprint small and point-lookup shaped, makes history cheap and bounded, makes fleet questions indexed reads, and prevents scan cadence multiplied by endpoint count from becoming the primary database write load or a fleet scan over the current-state (OLTP) tables.

## Resolved Decisions
- Artifact upload routes agent→gateway relay→datasvc, content-addressed; never over `CommandResult` (see Artifact Upload Routing).
- Package diffs are computed server-side at ingest (and materialized into the history hypertable), not on the agent, to avoid requiring a consistency-guaranteed local tuple cache across cache evictions.
- The first live-query UI ships both a device-scoped "check/refresh package" action and a cohort/fleet query form, with the cohort form bound by the scatter-gather cohort cap.
- The stale-cache threshold defaults to roughly twice the scan cadence and is surfaced as the typed freshness verdict on every answer.
- Force-fresh-scan is optional, disabled by default, and device-scoped; there is no fleet-wide force-fresh.
