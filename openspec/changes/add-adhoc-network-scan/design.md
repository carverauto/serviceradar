# Design: Ad-hoc network sweep/scan

## Context

Operators run ad-hoc reachability checks from jumpservers with
bash/PowerShell over a CSV of IPs. We want the same, self-service, from the
web console and via API, with a durable record. The build is dominated by
reuse — the two background investigations (Go agent side; web-ng/data side)
found the transport, engines, agent picker, RBAC, inventory add/bulk-add,
hypertable helpers, and CSV export already present. This document records
the two load-bearing decisions (both taken) and the concrete shapes.

## Decisions (taken)

### D1: Durable results via JetStream, live progress via the command channel
Ad-hoc ICMP/TCP results are telemetry (availability, RTT, port state), so
per the AGENTS.md hard rule they MUST traverse JetStream before landing in
CNPG. The agent emits an `adhoc-scan-metrics` `MetricBatch` on the existing
`metrics.>` stream (reusing the `metric_envelope.go` builders that already
produce `icmp-metrics` / `sweep-metrics`); `ResultsRouter` routes the new
source to a new EventWriter processor that writes `adhoc_scan_results`. The
`CommandResult`/`CommandProgress` channel drives **live UI progress only**,
never the system of record. This keeps results subscribable and
rule-compliant while still feeling instant in the UI.

### D2: `ScanRun` aggregate; one `scan.run_adhoc` command; MTR is a first-class sweep mode
One `ScanRun` row models a user's scan and dispatches a **single** new
`scan.run_adhoc` command (inline target + port list) to the chosen agent.
The handler runs an **ephemeral** sweep supporting all requested modes and
never mutates the agent's persisted/scheduled sweep config (see D4).

MTR is promoted to a first-class `SweepMode` (`ModeMTR`) rather than a
separate command:
- `models.SweepMode` gains `ModeMTR`; the sweep engine runs MTR per target
  via the existing `mtr.Tracer` engine (reuse at the engine level).
- A sweep/scan config carries `modes: [icmp, tcp, mtr]` uniformly — for
  ad-hoc runs **and** scheduled sweep profiles (D5).

MTR's richer result shape is handled by writing to two stores, keyed by
`scan_run_id`:
- a **reachability summary row** in `adhoc_scan_results` (`mode = "mtr"`,
  `available` = target reached, `response_ms` = end-to-end RTT) so it sits
  in the unified results table beside ICMP/TCP, and
- the **full per-hop trace** into the existing `mtr_traces`/`mtr_hops`
  hypertables (reusing that schema) so the UI can expand a row to the hop
  path.

Both traverse JetStream (D1). The join key makes the two stores invisible to
users. This supersedes the earlier "dispatch a separate `mtr.bulk_run`" plan.

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
  `id`, `agent_id`, `modes` (array), `ports` (array), `target_count`,
  `targets` (or a child table for very large lists), `options` (map:
  timeouts, concurrency, icmp_count, mtr protocol/max_hops), `status`,
  `requested_by`, counts (`hosts_up`, `ports_open`), `started_at`,
  `finished_at`. Ash policy: `scans.execute` on create, `scans.read` on
  read, `system_bypass()`.
- `platform.adhoc_scan_results` (raw-SQL hypertable, `migrate? false` Ash
  read resource `ServiceRadar.Scans.ScanResult`): `time TIMESTAMPTZ`,
  `scan_run_id`, `agent_id`, `target_ip`, `mode`, `port` (nullable),
  `available bool`, `response_ms`, `service` (nullable), + PK
  `(time, scan_run_id, target_ip, mode, port)`. Reads: `by_scan_run`,
  `by_agent`, `recent`. Hypertable + 30-day retention via
  `maybe_create_hypertable` / `add_retention_policy`.
- `ServiceRadar.Scans.ScanPolicySettings` (singleton, key `"default"`):
  `restrict_to_inventory :boolean, default: false`. Modeled on
  `DeviceCleanupSettings`. `scans.manage` to write.

## Command + subject names

- Agent command type: `scan.run_adhoc` (new) — the single command for all
  requested modes. Payload:
  `{scan_run_id, targets []string, ports []int, modes []string ("icmp"/
  "tcp"/"mtr"), timeout_ms, concurrency, icmp_count, mtr_protocol,
  mtr_max_hops}`. The handler runs ICMP/TCP via the sweep scanners and MTR
  via `mtr.Tracer`, all in one ephemeral pass.
- JetStream: reuse the `metrics.>` stream; new `MetricBatch` `Source =
  "adhoc-scan-metrics"`. New `ResultsRouter` clause + EventWriter processor
  `event_writer/processors/adhoc_scan.ex` -> `adhoc_scan_results`.

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
`web-ng/mix.exs` — the single net-new dependency — and a small workbook
builder. Both stream the joined result set for a `scan_run_id`.

## Risks / Trade-offs

- **Two result stores (scan_results + mtr_traces).** Mitigated by the
  `scan_run_id` join; revisited by the follow-up that unifies MTR onto
  JetStream.
- **Large target lists.** Bounded by per-agent concurrency caps (as
  `mtr.bulk_run` does) and progress batching; the ScanRun may store targets
  in a child table rather than a single array column if lists get large.
- **New `elixlsx` dependency.** Isolated to the export module; CSV works
  without it, so XLSX can ship slightly behind if needed.
- **`scan.run_adhoc` is a powerful primitive.** Gated by `scans.execute` +
  the optional inventory-scoping guardrail + agent capability, and every
  run is recorded as a `ScanRun` for audit.

## Target architecture: all MTR routes through the sweep engine

The intended end state is that **every** MTR execution — ad-hoc, scheduled
sweep profile, and the existing dedicated MTR automation — runs as the `mtr`
sweep mode through the shared sweep engine, and MTR results reach CNPG via
JetStream + the event-writer pipeline (never a direct Ash write). This change
establishes that path for ad-hoc + scheduled-profile MTR.

Retiring the **standalone** MTR paths — the `check_type: "mtr"` scheduled
checker (`mtr_checker.go`), the `mtr.run` / `mtr.bulk_run` on-demand commands,
and the direct-write ingestion (`StatusHandler` -> `MtrMetricsIngestor`) — and
re-pointing the existing MTR automation (baseline/consensus workers) at the
sweep-engine path is a **phased follow-on**, because that machinery has its own
baseline/trigger/consensus behavior that must be preserved. It folds in the
JetStream migration tracked as forgejo issue #4669. Until then, the legacy MTR
checker/automation continues on its current path unchanged; this change does
not remove it.
