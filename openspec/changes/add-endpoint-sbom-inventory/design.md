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
- It is SHA-256 over a newline-joined, lexicographically-sorted encoding of the normalized package identity fields ingestion already dedups on: `package_manager`, `name`, `version`, `architecture`, `purl`. It is computed over the normalized rows, not the CycloneDX bytes.
- Volatile CycloneDX metadata (BOM `serialNumber`, BOM timestamp, JSON key ordering) and fields prone to drift (CPE enrichment) are explicitly excluded so that re-running the collector on an unchanged host yields the same hash.
- The hash is prefixed with a 1-byte algorithm version so that any future change to canonicalization is detectable and does not silently make every host report "changed" at once. A version bump is rolled out behind the reconcile-floor cadence rather than all at once.
- `artifact_hash` is a separate SHA-256 over the canonicalized CycloneDX bytes and is used for content-addressed object storage and cross-host dedup.

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

Fleet rollups (TimescaleDB continuous aggregates):
- Incrementally-maintained TimescaleDB continuous aggregates (e.g. host counts per package/version/ecosystem/CPE over time) serve dashboard and fleet questions as indexed reads that also cover offline/last-known hosts. Fleet questions never run `GROUP BY` over the live current-state package tables.

Object storage (datasvc):
- The raw SBOM artifact is stored through datasvc only when content changes or a guarded force-refresh occurs. Objects are content-addressed by `artifact_hash` so identical SBOMs across a homogeneous/golden-image fleet are stored once and referenced by many scans.

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

## Command Safety And Authorization
- Inventory commands are typed (cache-query vs force-fresh-scan) rather than a single opaque action.
- Cache-query requires the operator's normal inventory-read authorization.
- Force-fresh-scan is optional and disabled by default, device-scoped only, and requires an explicit RBAC catalog permission (`endpoint_inventory.force_fresh_scan`) on the requesting actor (not the transport/system identity), a per-agent single-flight semaphore (cap 1), and a per-partition rate limit. Dispatch capacity MUST be enforced for the inventory command type; the command bus today returns success for unlisted command types (only `mtr.run`/`mtr.bulk_run` have capacity clauses), so this change adds inventory clauses. Fleet-wide force-fresh-scan is out of scope; a fleet-wide force would otherwise mean up to one privileged `rpm -qa`/`dpkg`/`apk` scan per host simultaneously.
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
