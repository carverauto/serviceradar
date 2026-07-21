# Design: Ad-hoc network sweep/scan

## Context

Operators run ad-hoc reachability checks from jumpservers with
bash/PowerShell over a CSV of IPs. We want the same, self-service, from the
web console and via API, with a durable record. The build is dominated by
reuse - the two background investigations (Go agent side; web-ng/data side)
found the transport, engines, agent picker, RBAC, inventory add/bulk-add,
hypertable helpers, and CSV export already present. This document records
the two load-bearing decisions (both taken) and the concrete shapes.

## Decisions (taken)

### D1: Durable results via JetStream, live progress via the command channel
Ad-hoc ICMP/TCP results are telemetry (availability, RTT, port state), so
per the AGENTS.md hard rule they MUST traverse JetStream before landing in
CNPG. The agent emits canonical `SweepObservationBatchV1` events carrying
`source=ad_hoc` and `scan_run_id` through the durable gRPC-to-gateway-to-
JetStream result lane defined by `unify-sweep-results-proto`; full MTR uses
correlated `MtrTraceBatchV1`. The canonical EventWriter projectors write
`adhoc_scan_results` and trace rows. The
`CommandResult`/`CommandProgress` channel carries only rate-limited counters,
watermarks, and bounded control summaries; it never carries a second copy of
per-target/per-hop results and never republishes or persists authoritative
results. Persisted projection notifications plus paged reads drive the live
result table. This keeps results subscribable and rule-compliant without a
duplicate hot path.

### D2: `ScanRun` aggregate; bounded assignments; MTR is a first-class sweep mode
One `ScanRun` models a user's logical scan and owns an immutable target/check
plan. A small admitted run may dispatch one `scan.run_adhoc` assignment; a large
uploaded list is page/range-sharded into multiple independently fenced bounded
assignments to the chosen agent. No ControlStream command carries an unbounded
list. The handler runs an **ephemeral** sweep supporting all requested modes and
never mutates the agent's persisted/scheduled sweep config (see D4).

The scheduler, not caller input, signs the traffic class. `interactive` requires
hard target/probe/duration/result-cost bounds; larger accepted work is `bulk` or
is rejected before probing. Class follows results into disjoint streams and
reserved downstream queues so a large ad-hoc upload cannot monopolize the
gateway, EventWriter, reconciler, graph projector, or DLQ.

Dispatch eligibility requires the agent to be online, meet the configured
minimum result-path version, advertise both `scan.run_adhoc` and
`edge-results:v1`, and have a ready gateway/stream/consumer path. The scheduler
rejects before probing if any part is missing; it never falls back to per-target
`CommandResult` data.

MTR is promoted to a first-class `SweepMode` (`ModeMTR`) rather than a
separate command:
- `models.SweepMode` gains `ModeMTR`; the sweep engine runs MTR per target
  via the existing `mtr.Tracer` engine (reuse at the engine level).
- A sweep/scan config carries `modes: [icmp, tcp, mtr]` uniformly - for
  ad-hoc runs **and** scheduled sweep profiles (D5).

MTR's richer result shape is handled by writing to two stores, keyed by
`scan_run_id`:
- a **reachability summary row** in `adhoc_scan_results` (`mode = "mtr"`,
  `available` = target reached, `response_ms` = end-to-end RTT) so it sits
  in the unified results table beside ICMP/TCP, and
- the **full per-hop trace** into the existing `mtr_traces`/`mtr_hops`
  hypertables (reusing that schema) so the UI can expand a row to the hop
  path.

Both traverse their dedicated canonical JetStream streams (D1). The join key
makes the two stores invisible to users. This supersedes the earlier "dispatch a
separate `mtr.bulk_run`" and generic metric-expansion plans.

Every completed host and trace feeds the canonical byte/row/write-cost/timer
builder and fsynced spool immediately, then releases producer-owned memory.
Execution duration may be long, but agent RSS and each transport/durability/
transaction unit remain bounded; terminal state reconciles plan ranges and
assignment watermarks instead of transport EOF.

### D4: Ephemeral runs never clobber the scheduled sweep config
`scan.run_adhoc` constructs throwaway scanner/sweeper instances scoped to the
command and returns results; it MUST NOT call the persistent
`MultiSweepService` `UpdateConfig`/`UpdateSweepGroups` path, and MUST NOT
reuse `sweep.run_group` (which operates on persisted group IDs). The agent's
configured, scheduled sweep groups are therefore never touched by an ad-hoc
run.

### D5: MTR mode in scheduled sweep profiles + Settings UI
Because `ModeMTR` is a first-class sweep mode, the scheduled sweep-profile
schema (Elixir sweep-config resource + the compiler that emits agent sweep
config) SHALL allow `mtr` in a profile's modes, and the Settings sweep-profile
editor SHALL expose an MTR option alongside ICMP/TCP. A scheduled profile with
MTR enabled runs MTR on its interval through the same engine path; its results
follow the same JetStream + `mtr_traces` persistence as ad-hoc MTR.

## Data model

- `ServiceRadar.Scans.ScanRun` (Ash, `platform`, Ash-managed table):
  `id`, authoritative `network_scope_id`, `agent_id`, `modes` (array),
  `ports` (array), `target_count`,
  immutable plan identity/digest plus normalized target pages in a child table,
  `options` (map:
  timeouts, concurrency, icmp_count, mtr protocol/max_hops), `status`,
  `requested_by`, counts (`hosts_up`, `ports_open`), `started_at`,
  `finished_at`. Ash policy: `scans.execute` on create, `scans.read` on
  read, `system_bypass()`.
- `platform.adhoc_scan_results` (raw-SQL hypertable, `migrate? false` Ash
  read resource `ServiceRadar.Scans.ScanResult`): scheduler-owned
  `identity_time TIMESTAMPTZ` (hypertable partition key), semantic
  `observed_at TIMESTAMPTZ`,
  `scan_run_id`, `agent_id`, `target_ip`, `mode`, `port` (nullable), non-null
  canonical `check_key` derived from mode/protocol/normalized port-or-sentinel,
  `available bool`, `response_ms`, `service` (nullable), + PK
  authoritative `network_scope_id`, with physical key
  `(identity_time, network_scope_id, scan_run_id, target_ip, check_key)`. Reads: `by_scan_run`,
  `by_agent`, `recent`. Hypertable + 30-day retention via
  `maybe_create_hypertable` / `add_retention_policy`.
- `ServiceRadar.Scans.ScanPolicySettings` (singleton, key `"default"`):
  `restrict_to_inventory :boolean, default: false`. Modeled on
  `DeviceCleanupSettings`. `scans.manage` to write.

## Command + subject names

- Agent command type: `scan.run_adhoc` (new) - one bounded assignment carries
  all requested modes for one immutable plan range. Payload:
  `{scan_run_id, plan_id, range_id, range_digest, targets []string, ports []int,
  modes []string ("icmp"/
  "tcp"/"mtr"), timeout_ms, concurrency, icmp_count, mtr_protocol,
  mtr_max_hops, traffic_class, assignment_epoch, capability}`. `targets` is
  hard-bounded and digest-bound. The handler runs ICMP/TCP via the sweep scanners
  and MTR via `mtr.Tracer`, all in one ephemeral assignment pass.
- Durable results: `SweepObservationBatchV1` on the canonical sweep stream and
  `MtrTraceBatchV1` on the canonical MTR stream, both correlated by
  `scan_run_id`; the sweep/MTR EventWriter projectors write
  `adhoc_scan_results` and trace tables.

## Web-ng UI

`ScanLive` under the authenticated + permitted live_session. Targets: a
textarea (paste) plus `allow_upload(:targets, accept: ~w(.csv .txt))` with a
`phx-drop-target` drop zone; parse with the existing hand-rolled CSV parser.
Options: mode checkboxes, port input (for TCP), agent `<select>` from
`AgentCommandBus.list_online_agents/0`. Results: `stream/3` table joining
`ScanResult.by_scan_run` + MTR traces; PubSub `{:command_progress}` /
`{:command_result}` drive live updates. Export buttons hit the export
controller.

## RBAC

New `scans` catalog section: `scans.execute` (operator+admin), `scans.read`
(all), `scans.export` (all), `scans.manage` (admin). Enforced in `ScanLive`
mount/handle_event (`RBAC.can?`), on the API routes, and by the `ScanRun`
Ash policy. Add-missing-device buttons reuse the existing
`devices.create`/`devices.import` gates.

## REST API

`scope "/api/v1", ...Api do pipe_through([:api_key_auth, :rate_limit_scans])`
`POST /scans`, `GET /scans/:id`, `GET /scans/:id/results`,
`GET /scans/:id/export`. `POST` additionally gated on the `scan.execute`
OAuth scope via `RequireOauthScope` (fallback permission `scans.execute`).
Controller shape follows `Api.DeviceController`; a named rate-limit pipeline
mirrors the existing buckets.

## Export

CSV: reuse the chunked `text/csv` `send_chunked` streaming controller
pattern (as in `AuthoredDashboardExportController`). XLSX: add `elixlsx` to
`web-ng/mix.exs` - the single net-new dependency - and a small workbook
builder. Both stream the joined result set for a `scan_run_id`.

## Risks / Trade-offs

- **Two relational result views (scan_results + mtr_traces).** Mitigated by the
  `scan_run_id` join; both are projected from their canonical JetStream events.
- **Large target lists.** Stored as immutable bounded plan pages and dispatched
  as independently fenced assignments. Per-agent concurrency, spool/downstream
  pressure, traffic-class budgets, and progress batching bound execution; the
  system never sends or materializes one whole-run command/result payload.
- **New `elixlsx` dependency.** Isolated to the export module; CSV works
  without it, so XLSX can ship slightly behind if needed.
- **`scan.run_adhoc` is a powerful primitive.** Gated by `scans.execute` +
  the optional inventory-scoping guardrail + agent capability, and every
  run is recorded as a `ScanRun` for audit.

## Target architecture: all MTR routes through the sweep engine

The required architecture is that **every** MTR execution - ad-hoc, scheduled
sweep profile, and the existing dedicated MTR automation - runs as the `mtr`
sweep mode through the shared sweep engine, and MTR results reach CNPG via
JetStream + the event-writer pipeline (never a direct Ash write). This change
establishes that path for ad-hoc + scheduled-profile MTR.

Retiring the **standalone ingestion** paths used by `check_type: "mtr"`,
checker (`mtr_checker.go`), the `mtr.run` / `mtr.bulk_run` on-demand commands,
and the direct-write ingestion (`StatusHandler` -> `MtrMetricsIngestor`) - and
re-pointing the existing MTR automation (baseline/consensus workers) at the
sweep-engine path is coordinated with `unify-sweep-results-proto`, because that machinery has its own
baseline/trigger/consensus behavior that must be preserved. It folds in the
JetStream migration tracked as forgejo issue #4669. This ad-hoc change SHALL NOT
add a new direct or generic-metric result route while that migration proceeds.
